[CmdletBinding()]
param(
  # Routing method under test. Each method owns an independent Terraform root
  # and state under infra/<mode>.
  [Parameter(Mandatory = $true)]
  [ValidateSet("vxlan", "host", "static", "dynamic")]
  [string]$Mode,

  # 4 = initial build (1 control plane + 1 benchmark + 2 workers) from an empty
  #     Terraform state; T0 is the moment all four VMs start being created.
  # 8 = expansion of that cluster to 6 workers, reusing the same state; T0 is the
  #     moment the worker-adding apply starts. It never builds from scratch.
  [ValidateSet(4, 8)]
  [int]$NodeCount = 4,

  # Optional overrides. Empty means infra/<mode> and
  # results/<mode>/provisioning-<n>node.
  [string]$TfDir = "",
  [string]$VarFile = "",
  [string]$OutDir = "",

  # Empty means "use the single source of truth in the Terraform outputs". A
  # value is passed to terraform plan as -var and read back from the outputs.
  [string]$KubernetesVersion = "",
  [string]$CiliumVersion = "",

  [string]$ExperimentLabel = "exp1",

  [switch]$SkipApply,
  [switch]$SkipQuotaPreflight
)

# Experiment 1 - provisioning time for VXLAN / Host / N-Static / N-Dynamic.
#
#   T0  terraform apply started            T3  Cilium ready
#   T1  VM creation finished               T4  method-specific VPC task finished
#   T2  every node registered and Ready    T5  cross-node connectivity verified
#
# T5 remains a required post-measurement validation point. Experiment 1 records
# duration intervals only through T4 and uses T0~T4 as its measured total.
#
# -NodeCount forces worker_count with -var, so an edited worker_count in tfvars
# never change the measured scale, and it pins the exact node count the state
# must hold before apply (4 nodes -> 0, expansion -> 4). The plan guard refuses
# any node deletion, so an expansion apply can only add workers; existing nodes
# skip kubeadm init/join because /etc/kubernetes/kubelet.conf already exists.
#
# GKE (N-Cloud on GKE Standard) is provisioned by provision-gke.ps1 instead.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$NetworkMode = $Mode.ToLowerInvariant()
$networkModeLabel = $NetworkMode.ToUpperInvariant()
$WorkerCount = $NodeCount - 2
$RequiredExistingNodes = if ($NodeCount -eq 4) { 0 } else { 4 }
if ([string]::IsNullOrWhiteSpace($TfDir))   { $TfDir = Join-Path $PSScriptRoot "infra\$NetworkMode" }
if ([string]::IsNullOrWhiteSpace($VarFile)) { $VarFile = Join-Path $TfDir "terraform.tfvars" }
if ([string]::IsNullOrWhiteSpace($OutDir))  { $OutDir = ".\results\$NetworkMode\provisioning-${NodeCount}node" }

. (Join-Path $PSScriptRoot "provision-common.ps1")

$script:IsMethodSpecificNative = $NetworkMode -in @("static", "dynamic")
$script:TerraformWorkspace = "default"
$script:ProvisioningStartedAt = Get-Date
$script:MonotonicClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:CurrentStep = "initialize"
$script:LastNativeTiming = $null
$script:ExperimentName = $NetworkMode
$script:ResultMethodLabel = $NetworkMode
$script:ExperimentLabel = $ExperimentLabel
$script:ExpectedNodeCount = 0
$script:RunIteration = $null
$script:RunOutputClaimed = $false
$script:RunResultCsvPath = $null
$script:RunResultClaimPath = $null
$script:RunStatus = "RUNNING"
$script:DurationRows = @()
$script:ApplyAttempted = $false
# Whether the terraform apply process was even started. A Ctrl+C during apply
# can lose the exit-code capture and leave ApplyAttempted false, so the destroy
# decision on an interrupt uses this flag instead.
$script:ApplyStarted = $false
# Set once the run completed normally (success/PLAN_ONLY) or the catch block
# finished handling a failure. Still false in finally means an abnormal abort.
$script:RunCompleted = $false
# Experiment 2 measurement image (ubuntu:22.04 + iperf3 3.21 built from source,
# exp2/image/Dockerfile). Built locally before T0 and loaded into the
# benchmark/worker-0 containerd after T5. The tag and version must match the
# TOOL_IMAGE default and EXP2_IPERF3_VERSION of exp2_benchmark.sh.
$script:Exp2ToolImageTag = "localhost/exp2-tools:iperf3-3.21"
$script:Exp2ToolImageIperf3Version = "3.21"
function Assert-CompleteTimeline {
  $expectedNames = @("T0", "T1", "T2", "T3", "T4", "T5")
  $points = @($script:Timeline | Where-Object { $expectedNames -contains $_.name })
  if ($points.Count -ne $expectedNames.Count) {
    throw "Timeline is incomplete: expected T0-T5 (6 points), found $($points.Count)."
  }
  if (@($script:Timeline | Where-Object { $_.name -eq "FAILURE" }).Count -gt 0) {
    throw "A successful timeline must not contain FAILURE."
  }

  for ($index = 0; $index -lt $expectedNames.Count; $index++) {
    $point = $points[$index]
    if ($point.name -ne $expectedNames[$index]) {
      throw "Timeline order mismatch at index ${index}: expected $($expectedNames[$index]), found $($point.name)."
    }
    if ([double]::IsNaN([double]$point.elapsed_ms) -or [double]::IsInfinity([double]$point.elapsed_ms)) {
      throw "$($point.name) elapsed_ms must be finite."
    }

    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$point.timestamp, [ref]$parsedTimestamp)) {
      throw "$($point.name) timestamp is not a valid ISO timestamp: $($point.timestamp)"
    }
    if ($parsedTimestamp.ToUnixTimeMilliseconds() -ne [long]$point.timestamp_unix_ms) {
      throw "$($point.name) timestamp_unix_ms does not match timestamp."
    }
    if ($index -gt 0) {
      $previous = $points[$index - 1]
      if ([double]$point.elapsed_ms -lt [double]$previous.elapsed_ms) {
        throw "Timeline elapsed_ms decreased between $($previous.name) and $($point.name)."
      }
    }
  }

  $applyTimings = @($script:CommandTimings | Where-Object { $_.name -eq "terraform apply" })
  if ($applyTimings.Count -eq 0) {
    throw "Timeline has T0/T1 but command-timings has no terraform apply record."
  }
  $applyTiming = $applyTimings[-1]
  $t0 = $points[0]
  $t1 = $points[1]
  if ([math]::Abs([double]$t0.elapsed_ms - [double]$applyTiming.started_elapsed_ms) -gt 0.0005) {
    throw "T0 elapsed_ms does not match the terraform apply start boundary."
  }
  if ([math]::Abs([double]$t1.elapsed_ms - [double]$applyTiming.ended_elapsed_ms) -gt 0.0005) {
    throw "T1 elapsed_ms does not match the terraform apply end boundary."
  }
  if ([DateTimeOffset]::Parse([string]$t0.timestamp).ToUniversalTime() -ne [DateTimeOffset]::Parse([string]$applyTiming.started_at).ToUniversalTime()) {
    throw "T0 timestamp does not match the terraform apply start boundary."
  }
  if ([DateTimeOffset]::Parse([string]$t1.timestamp).ToUniversalTime() -ne [DateTimeOffset]::Parse([string]$applyTiming.ended_at).ToUniversalTime()) {
    throw "T1 timestamp does not match the terraform apply end boundary."
  }

  if ($NetworkMode -in @("vxlan", "host")) {
    # VXLAN/Host have no VPC task between T3 and T4, so both boundaries are
    # recorded at exactly the same instant, without instrumentation overhead.
    if ([double]$points[3].elapsed_ms -ne [double]$points[4].elapsed_ms -or
        [long]$points[3].timestamp_unix_ms -ne [long]$points[4].timestamp_unix_ms) {
      throw "T3 and T4 must share the same no-op boundary for $NetworkMode."
    }
  }
  elseif ([double]$points[4].elapsed_ms -le [double]$points[3].elapsed_ms) {
    throw "$NetworkMode T4 must be later than T3 because it performs method-specific routing work."
  }
}

function Write-ProvisioningSummary {
  param(
    [string]$Status,
    [object]$Failure = $null
  )

  if ($Status -eq "SUCCESS") {
    Assert-CompleteTimeline
  }

  $endedAt = Get-Date
  $scriptDurationMs = $script:MonotonicClock.Elapsed.TotalMilliseconds
  $rows = @()
  $rows += New-ProvisioningDurationRow `
    -Name "script_total" `
    -Description "provision-$($script:ExperimentName).ps1 start to completion, including preflight, Terraform, Kubernetes, endpoint connectivity, and control variable checks" `
    -StartedAt $script:ProvisioningStartedAt `
    -EndedAt $endedAt `
    -DurationMilliseconds $scriptDurationMs `
    -Status $Status

  # Experiment 1 records every interval (T0~T1 ... T3~T4) plus the total
  # (T0~T4). After a failure only the intervals that exist are written.
  $segments = @(
    [pscustomobject]@{ Name = "T0_to_T1"; From = "T0"; To = "T1"; Description = "terraform apply: VM creation" },
    [pscustomobject]@{ Name = "T1_to_T2"; From = "T1"; To = "T2"; Description = "bootstrap wait, kubeadm init/join, Cilium install, all nodes Ready" },
    [pscustomobject]@{ Name = "T2_to_T3"; From = "T2"; To = "T3"; Description = "cilium status --wait" },
    [pscustomobject]@{ Name = "T3_to_T4"; From = "T3"; To = "T4"; Description = if ($NetworkMode -in @("vxlan", "host")) { "method-specific VPC task (none, recorded as immediate no-op)" } else { "$NetworkMode method-specific routing task" } },
    [pscustomobject]@{ Name = "T0_to_T4"; From = "T0"; To = "T4"; Description = "total provisioning time (experiment 1 metric)" }
  )
  foreach ($segment in $segments) {
    $from = Get-TimelineEntry -Name $segment.From
    $to = Get-TimelineEntry -Name $segment.To
    if ($null -ne $from -and $null -ne $to) {
      $rows += New-ProvisioningDurationRow `
        -Name $segment.Name `
        -Description $segment.Description `
        -StartedAt ([datetime]::Parse($from.timestamp)) `
        -EndedAt ([datetime]::Parse($to.timestamp)) `
        -DurationMilliseconds ([double]$to.elapsed_ms - [double]$from.elapsed_ms) `
        -Status $Status
    }
  }

  if ($Status -eq "SUCCESS") {
    $intervalRows = @($rows | Where-Object { $_.name -in @("T0_to_T1", "T1_to_T2", "T2_to_T3", "T3_to_T4") })
    $totalRows = @($rows | Where-Object { $_.name -eq "T0_to_T4" })
    if ($intervalRows.Count -ne 4 -or $totalRows.Count -ne 1) {
      throw "Successful timeline did not produce all four intervals and T0_to_T4."
    }
    $intervalSum = ($intervalRows | Measure-Object -Property duration_milliseconds -Sum).Sum
    if ([math]::Abs([double]$intervalSum - [double]$totalRows[0].duration_milliseconds) -gt 0.005) {
      throw "Timeline duration arithmetic mismatch: interval sum does not equal T0_to_T4."
    }
  }

  $hasT0 = $null -ne (Get-TimelineEntry -Name "T0")
  $summary = [pscustomobject]@{
    status               = $Status
    experiment_name      = $script:ExperimentName
    experiment_label     = $script:ExperimentLabel
    node_count           = $script:ExpectedNodeCount
    experiment_iteration = $script:RunIteration
    result_csv           = if ($script:RunOutputClaimed -and $hasT0) { $script:RunResultCsvPath } else { $null }
    generated_at         = $endedAt.ToUniversalTime().ToString("o")
    failure              = $Failure
    durations            = $rows
  }
  $script:DurationRows = @($rows)
  $script:RunStatus = $Status
  ConvertTo-Json -InputObject $summary -Depth 8 |
    Set-Content -Encoding UTF8 -Path $script:ProvisioningSummaryJsonPath

  if ($script:RunOutputClaimed -and $hasT0) {
    Write-RunResultCsv
  }
  elseif ($Status -eq "FAILED") {
    # A preparation step that failed before apply (T0) does not consume a
    # measurement iteration: no new iteration CSV, only the latest failure
    # summary in the fixed file.
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:ProvisioningSummaryCsvPath
  }
}

function Resolve-TerraformInputPath {
  param(
    [string]$Path,
    [string]$TfDirectory
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return (Resolve-Path -LiteralPath $Path).Path
  }
  # Terraform file() resolves relative paths against the module directory.
  return (Resolve-Path -LiteralPath (Join-Path $TfDirectory $Path)).Path
}

function Assert-SshKeyPair {
  param(
    [string]$PublicKeyPath,
    [string]$PrivateKeyPath
  )

  if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
    throw "SSH public key not found: $PublicKeyPath"
  }
  if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
    throw "SSH private key not found: $PrivateKeyPath. Set ssh_private_key_path or use a '<private>.pub' public-key path."
  }

  # Do not pass an empty passphrase as -P "". Windows PowerShell 5.1 drops an
  # empty string argument entirely (-P swallows the following -f), so even a
  # valid key fails with "Too many arguments". A dummy value behaves exactly as
  # intended: a passphrase-less key ignores it and succeeds, an encrypted key
  # fails immediately with "incorrect passphrase" instead of prompting.
  $keygenArgs = @("-y", "-P", "experiment-key-must-be-passphraseless", "-f", $PrivateKeyPath)
  try {
    $ErrorActionPreference = "Continue"
    $derivedOutput = @(& ssh-keygen @keygenArgs 2>&1 | ForEach-Object { $_.ToString() })
    $keygenExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($keygenExitCode -ne 0) {
    # Include what ssh-keygen actually said: the cause is often file permissions
    # ("UNPROTECTED PRIVATE KEY FILE"), not a passphrase.
    throw "The SSH private key at '$PrivateKeyPath' could not be read non-interactively: $(($derivedOutput -join ' ').Trim())`nUse an unencrypted key that matches ssh_public_key_path, and make sure only your account can read the file."
  }

  $derivedParts = ((($derivedOutput | Select-Object -Last 1) -as [string]).Trim() -split '\s+')
  $publicParts = ((Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split '\s+')
  if ($derivedParts.Count -lt 2 -or $publicParts.Count -lt 2 -or
      $derivedParts[0] -ne $publicParts[0] -or $derivedParts[1] -ne $publicParts[1]) {
    throw "ssh_private_key_path does not match ssh_public_key_path."
  }
}

function Convert-InventoryToNodes {
  param([object]$Inventory)
  return @(
    $Inventory.PSObject.Properties | ForEach-Object {
      $value = $_.Value
      [pscustomobject]@{
        key         = $_.Name
        name        = $value.name
        role        = $value.role
        role_index  = $value.role_index
        project_id  = $value.project_id
        zone        = $value.zone
        private_ip  = $value.private_ip
        external_ip = $value.external_ip
      }
    }
  )
}

function Get-CiliumEndpointPair {
  param([object[]]$Workers)

  $orderedWorkers = @($Workers | Sort-Object { [int]$_.role_index })
  if ($orderedWorkers.Count -lt 2) {
    throw "Pair-scoped Cilium connectivity tests require at least two worker nodes, found $($orderedWorkers.Count)."
  }

  $seenNames = @{}
  $seenRoleIndexes = @{}
  for ($i = 0; $i -lt $orderedWorkers.Count; $i++) {
    $worker = $orderedWorkers[$i]
    $nodeName = [string]$worker.name
    $roleIndex = [int]$worker.role_index
    if ($roleIndex -ne $i) {
      throw "Worker role_index must be contiguous from 0; expected $i, found $roleIndex on '$nodeName'."
    }
    if ([string]::IsNullOrWhiteSpace($nodeName) -or $nodeName -notmatch '^[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?$') {
      throw "Worker node name cannot be safely embedded in the connectivity script: '$nodeName'."
    }
    if ($seenNames.ContainsKey($nodeName)) {
      throw "Duplicate worker node name in connectivity pair plan: '$nodeName'."
    }
    if ($seenRoleIndexes.ContainsKey($roleIndex)) {
      throw "Duplicate worker role_index in connectivity pair plan: $roleIndex."
    }
    $seenNames[$nodeName] = $true
    $seenRoleIndexes[$roleIndex] = $true
  }

  $anchorNode = [string]$orderedWorkers[0].name
  $targetNode = [string]$orderedWorkers[-1].name
  if ($anchorNode -eq $targetNode) {
    throw "Cilium connectivity endpoints must be different worker nodes."
  }
  return [pscustomobject]@{
    anchor = $anchorNode
    target = $targetNode
  }
}

function Get-ExistingNodeCountFromState {
  param([string]$TfDirFull)

  $stateLines = @()
  $stateExitCode = -1
  try {
    $ErrorActionPreference = "Continue"
    $stateLines = @(& terraform -chdir="$TfDirFull" state list 2>&1 | ForEach-Object { $_.ToString() })
    $stateExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($stateExitCode -ne 0) {
    $stateError = ($stateLines -join [Environment]::NewLine)
    # A freshly initialized working directory has no state file at all and
    # Terraform answers with exit 1 and the fixed message below. Any other
    # backend/lock/auth error must abort instead of being read as "0 nodes",
    # which would re-measure an existing environment.
    if ($stateError -match "No state file was found") {
      return 0
    }
    throw "Failed to inspect Terraform state (exit $stateExitCode): $stateError"
  }
  return @($stateLines | Where-Object { $_ -match '^google_compute_instance\.node\[' }).Count
}

# -- Node SSH/SCP transport ------------------------------------------------
# gcloud compute ssh uses PuTTY (plink) on Windows: with an OpenSSH-format
# private key it prompts to overwrite the key file with a .ppk, and --quiet
# auto-declines it, so every call fails with "ERROR: Aborted by user".
# Terraform already injects the public key into the instance metadata and the
# inventory carries external_ip, so the built-in Windows OpenSSH (ssh.exe /
# scp.exe) connects directly. As a side effect the gcloud CLI (Python) startup
# cost disappears from the T1~T4 measurement window.

function Get-NodeSshTarget {
  param(
    [object]$Node,
    [string]$SshUser
  )
  if ([string]::IsNullOrWhiteSpace($SshUser)) {
    throw "ssh_user must not be empty: direct OpenSSH cannot derive a username the way gcloud does."
  }
  $address = [string]$Node.external_ip
  if ([string]::IsNullOrWhiteSpace($address)) {
    throw "Node $($Node.name) has no external IP. Direct OpenSSH access requires allow_external_ip = true."
  }
  return "$SshUser@$address"
}

function Get-OpenSshCommonArguments {
  param([string]$SshKeyFile)
  $arguments = @(
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    # Experiment VMs are recreated every iteration and ephemeral external IPs
    # can be reused, so host key verification would only block or prompt. Same
    # policy as gcloud --quiet, and known_hosts is discarded to NUL.
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "LogLevel=ERROR"
  )
  if (-not [string]::IsNullOrWhiteSpace($SshKeyFile)) {
    $arguments += @("-i", $SshKeyFile)
  }
  return $arguments
}

function Get-RemoteBashInvocation {
  # Remote commands with multi-line or nested quoting are wrapped in base64 so
  # Windows PowerShell 5.1 native argument quoting cannot corrupt them. CRLF
  # from a Windows checkout would make remote Bash miss keywords such as fi\r,
  # so every CRLF and lone CR is normalized to LF first. The overall exit code
  # is the exit code of bash.
  param([string]$Command)
  $normalized = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
  return "echo $encoded | base64 -d | bash"
}

function Invoke-NodeSsh {
  param(
    [object]$Node,
    [string]$Command,
    [string]$SshUser,
    [string]$SshKeyFile,
    [string]$LogPath,
    [int]$MaxAttempts = 1,
    [int]$RetryDelaySeconds = 15,
    # Greater than 0 retries on elapsed time instead of an attempt count
    # (unlimited attempts). Used for "will connect eventually" waits such as
    # right after boot. The time cap stays so a host that never accepts SSH
    # still reaches the failure/auto-destroy path instead of burning VM cost.
    [int]$MaxWaitSeconds = 0
  )

  # $args is a PowerShell automatic variable, so it is avoided. -n: no stdin.
  $sshArgs = @("-n") + (Get-OpenSshCommonArguments -SshKeyFile $SshKeyFile)
  $sshArgs += @((Get-NodeSshTarget -Node $Node -SshUser $SshUser), (Get-RemoteBashInvocation -Command $Command))

  $retryClock = [System.Diagnostics.Stopwatch]::StartNew()
  $attempt = 0
  while ($true) {
    $attempt++
    try {
      # Lowered for the same PS 5.1 stderr redirection reason as Invoke-Native.
      $ErrorActionPreference = "Continue"
      if ([string]::IsNullOrWhiteSpace($LogPath)) {
        & ssh @sshArgs 2>&1 | ForEach-Object { $_.ToString() } | Write-Host
      }
      else {
        & ssh @sshArgs 2>&1 | ForEach-Object { $_.ToString() } |
          Out-File -FilePath $LogPath -Encoding utf8
      }
    }
    finally {
      $ErrorActionPreference = "Stop"
    }

    if ($LASTEXITCODE -eq 0) {
      return
    }

    $canRetry = if ($MaxWaitSeconds -gt 0) {
      $retryClock.Elapsed.TotalSeconds -lt $MaxWaitSeconds
    }
    else {
      $attempt -lt $MaxAttempts
    }
    if (-not $canRetry) {
      break
    }

    # At a 1s retry interval, printing every attempt floods the console.
    if ($MaxWaitSeconds -le 0 -or $attempt -eq 1 -or ($attempt % 15) -eq 0) {
      Write-Host "ssh to $($Node.name) not ready (attempt $attempt, $([int]$retryClock.Elapsed.TotalSeconds)s elapsed). Retrying in $RetryDelaySeconds s..."
    }
    Start-Sleep -Seconds $RetryDelaySeconds
  }

  if (-not [string]::IsNullOrWhiteSpace($LogPath) -and (Test-Path -LiteralPath $LogPath)) {
    Get-Content -LiteralPath $LogPath -Tail 80 | Write-Host
  }
  throw "ssh failed on $($Node.name) after $attempt attempt(s) in $([int]$retryClock.Elapsed.TotalSeconds)s: $Command"
}

function Invoke-NodeSshCapture {
  param(
    [object]$Node,
    [string]$Command,
    [string]$SshUser,
    [string]$SshKeyFile
  )
  $sshArgs = @("-n") + (Get-OpenSshCommonArguments -SshKeyFile $SshKeyFile)
  $sshArgs += @((Get-NodeSshTarget -Node $Node -SshUser $SshUser), (Get-RemoteBashInvocation -Command $Command))
  # stdout only: stderr is not redirected, so the PS 5.1 problem cannot occur.
  $output = & ssh @sshArgs
  if ($LASTEXITCODE -ne 0) {
    throw "ssh failed on $($Node.name): $Command"
  }
  return ($output | Out-String)
}

function Invoke-ScpToNode {
  param(
    [object]$Node,
    [string]$LocalPath,
    [string]$RemotePath,
    [string]$SshUser,
    [string]$SshKeyFile,
    [ValidateRange(1, 30)]
    [int]$MaxAttempts = 6,
    [ValidateRange(0, 60)]
    # Each scp is paced by its own ConnectTimeout=10. Only the Guest Agent
    # restart window, where connections close instantly, needs a fast retry.
    [int]$RetryDelaySeconds = 1
  )
  $target = Get-NodeSshTarget -Node $Node -SshUser $SshUser
  $scpArgs = (Get-OpenSshCommonArguments -SshKeyFile $SshKeyFile) + @("-q", $LocalPath, "${target}:$RemotePath")
  $retryClock = [System.Diagnostics.Stopwatch]::StartNew()
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $ErrorActionPreference = "Continue"
      & scp @scpArgs 2>&1 |
        ForEach-Object { $_.ToString() } | Write-Host
    }
    finally {
      $ErrorActionPreference = "Stop"
    }
    if ($LASTEXITCODE -eq 0) {
      return
    }
    if ($attempt -lt $MaxAttempts) {
      Write-Host "scp to $($Node.name) failed (attempt $attempt, $([int]$retryClock.Elapsed.TotalSeconds)s elapsed). Retrying in $RetryDelaySeconds s..."
      if ($RetryDelaySeconds -gt 0) {
        Start-Sleep -Seconds $RetryDelaySeconds
      }
    }
  }
  throw "scp failed to $($Node.name) after $MaxAttempts attempt(s) in $([int]$retryClock.Elapsed.TotalSeconds)s: $LocalPath -> $RemotePath"
}

function Invoke-ScpFromNode {
  param(
    [object]$Node,
    [string]$RemotePath,
    [string]$LocalPath,
    [string]$SshUser,
    [string]$SshKeyFile
  )
  $target = Get-NodeSshTarget -Node $Node -SshUser $SshUser
  $scpArgs = (Get-OpenSshCommonArguments -SshKeyFile $SshKeyFile) + @("-q", "${target}:$RemotePath", $LocalPath)
  try {
    $ErrorActionPreference = "Continue"
    & scp @scpArgs 2>&1 | ForEach-Object { $_.ToString() } | Write-Host
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($LASTEXITCODE -ne 0) {
    throw "scp failed from $($Node.name): $RemotePath -> $LocalPath"
  }
}

function Invoke-RemoteScript {
  param(
    [object]$Node,
    [string]$ScriptContent,
    [string]$SshUser,
    [string]$SshKeyFile,
    [string]$Name,
    [string]$LogPath
  )

  $localScript = Join-Path $script:OutDirFull "$Name.sh"
  $remoteScript = "/tmp/$Name.sh"
  # A script written on Windows with CRLF fails on Linux with
  # "/usr/bin/env: 'bash\r': No such file or directory", so it is always
  # normalized to LF before upload, whatever this file's checkout endings are.
  $normalized = $ScriptContent.Replace("`r`n", "`n").Replace("`r", "`n")
  [System.IO.File]::WriteAllText($localScript, $normalized, [System.Text.UTF8Encoding]::new($false))
  Invoke-ScpToNode -Node $Node -LocalPath $localScript -RemotePath $remoteScript -SshUser $SshUser -SshKeyFile $SshKeyFile
  Invoke-NodeSsh -Node $Node -SshUser $SshUser -SshKeyFile $SshKeyFile -LogPath $LogPath -Command "chmod +x $remoteScript && $remoteScript"
}

function Install-Exp2ScriptsOnControlPlane {
  param(
    [object]$ControlPlane,
    [string]$SshUser,
    [string]$SshKeyFile,
    [string]$LocalScriptsRoot,
    [string]$StagingDirectory,
    [string]$LogDirectory
  )

  # The home of the SSH account is only an upload staging area. The executable
  # copy is installed as root:root 0755 under a shared path every local and OS
  # Login account can read and execute.
  $remoteSharedRoot = "/opt/experiment/scripts"
  $remoteSharedResultsRoot = "/var/lib/experiment/results"
  $remoteExperiment2Results = "$remoteSharedResultsRoot/exp2"
  $remoteExperiment2Raw = "$remoteExperiment2Results/raw"
  $remoteProfilePath = "/etc/profile.d/experiment-scripts.sh"

  $requiredProfileNames = @(
    "exp2_common.sh",
    "exp2_create_normal_min.sh",
    "exp2_create_normal_medium.sh",
    "exp2_create_hostnetwork_min.sh",
    "exp2_create_hostnetwork_medium.sh",
    "exp2_run_normal_min.sh",
    "exp2_run_normal_medium.sh",
    "exp2_run_hostnetwork_min.sh",
    "exp2_run_hostnetwork_medium.sh",
    "exp2_cleanup.sh"
  )
  $mainSource = Join-Path $LocalScriptsRoot "exp2_benchmark.sh"
  $profileSourceRoot = Join-Path $LocalScriptsRoot "exp2"
  if (-not (Test-Path -LiteralPath $mainSource -PathType Leaf)) {
    throw "Experiment 2 canonical script not found: $mainSource"
  }
  if (-not (Test-Path -LiteralPath $profileSourceRoot -PathType Container)) {
    throw "Experiment 2 profile directory not found: $profileSourceRoot"
  }

  $profileSources = @(Get-ChildItem -LiteralPath $profileSourceRoot -File -Filter "*.sh" | Sort-Object Name)
  $profileNames = @($profileSources | ForEach-Object { $_.Name })
  foreach ($requiredName in $requiredProfileNames) {
    if ($profileNames -notcontains $requiredName) {
      throw "Required Experiment 2 profile script not found: $requiredName"
    }
  }
  foreach ($profileSource in $profileSources) {
    if ($profileSource.Name -notmatch '^[a-z0-9][a-z0-9_-]*[.]sh$') {
      throw "Unsafe Experiment 2 profile filename: $($profileSource.Name)"
    }
  }

  $stageRoot = Join-Path $StagingDirectory "exp2-cp-upload"
  $stageProfileRoot = Join-Path $stageRoot "exp2"
  New-Item -ItemType Directory -Force -Path $stageRoot, $stageProfileRoot | Out-Null

  $sourceItems = @(
    [pscustomobject]@{
      SourcePath = $mainSource
      StagedPath = (Join-Path $stageRoot "exp2_benchmark.sh")
      RemotePath = "scripts/exp2_benchmark.sh"
      InstallRelativePath = "exp2_benchmark.sh"
    }
  )
  foreach ($profileSource in $profileSources) {
    $sourceItems += [pscustomobject]@{
      SourcePath = $profileSource.FullName
      StagedPath = (Join-Path $stageProfileRoot $profileSource.Name)
      RemotePath = "scripts/exp2/$($profileSource.Name)"
      InstallRelativePath = "exp2/$($profileSource.Name)"
    }
  }

  $uploadItems = @()
  foreach ($sourceItem in $sourceItems) {
    $content = [System.IO.File]::ReadAllText($sourceItem.SourcePath, [System.Text.Encoding]::UTF8)
    if ($content.IndexOf([char]0) -ge 0) {
      throw "Experiment 2 script contains a NUL byte: $($sourceItem.SourcePath)"
    }
    $crlf = ([string][char]13) + ([string][char]10)
    $lf = [string][char]10
    $normalized = $content.Replace($crlf, $lf).Replace([string][char]13, $lf)
    [System.IO.File]::WriteAllText($sourceItem.StagedPath, $normalized, [System.Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash -LiteralPath $sourceItem.StagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $uploadItems += [pscustomobject]@{
      LocalPath = $sourceItem.StagedPath
      RemotePath = $sourceItem.RemotePath
      InstallPath = "$remoteSharedRoot/$($sourceItem.InstallRelativePath)"
      Sha256 = $hash
    }
  }

  # The manifest and the remote checksum cover the shared installation other
  # accounts actually run, not the staging copy.
  $checksumLines = @($uploadItems | ForEach-Object { "$($_.Sha256)  $($_.InstallPath)" })
  [System.IO.File]::WriteAllLines(
    (Join-Path $StagingDirectory "exp2-cp-upload-manifest.sha256"),
    $checksumLines,
    [System.Text.UTF8Encoding]::new($false)
  )

  $prepareCommand = @(
    'set -euo pipefail',
    'install -d -m 0755 "$HOME/scripts" "$HOME/scripts/exp2"',
    "sudo -n install -d -o root -g root -m 0755 '/opt/experiment' '$remoteSharedRoot' '$remoteSharedRoot/exp2'",
    "sudo -n install -d -o root -g root -m 0755 '/var/lib/experiment' '$remoteSharedResultsRoot'",
    "sudo -n install -d -o root -g root -m 1777 '$remoteExperiment2Results' '$remoteExperiment2Raw'",
    "sudo -n chmod 1777 '$remoteExperiment2Results' '$remoteExperiment2Raw'"
  ) -join ([string][char]10)
  Invoke-NodeSsh -Node $ControlPlane -SshUser $SshUser -SshKeyFile $SshKeyFile -LogPath (Join-Path $LogDirectory "exp2-script-install-prepare.log") -Command $prepareCommand
  foreach ($uploadItem in $uploadItems) {
    Invoke-ScpToNode -Node $ControlPlane -LocalPath $uploadItem.LocalPath -RemotePath $uploadItem.RemotePath -SshUser $SshUser -SshKeyFile $SshKeyFile
  }

  $profileScript = @'
# Managed by provision.ps1. This file is intentionally POSIX-shell compatible.
EXPERIMENT_SCRIPTS_ROOT=__EXPERIMENT_SCRIPTS_ROOT__
EXPERIMENT_RESULTS_ROOT=__EXPERIMENT_RESULTS_ROOT__
export EXPERIMENT_SCRIPTS_ROOT EXPERIMENT_RESULTS_ROOT

case ":${PATH:-}:" in
  *":${EXPERIMENT_SCRIPTS_ROOT}:"*) ;;
  *) PATH="${EXPERIMENT_SCRIPTS_ROOT}:${PATH:-}" ;;
esac
case ":${PATH:-}:" in
  *":${EXPERIMENT_SCRIPTS_ROOT}/exp2:"*) ;;
  *) PATH="${EXPERIMENT_SCRIPTS_ROOT}/exp2:${PATH:-}" ;;
esac
export PATH

# OS Login can create a home directory after provisioning. Give every newly
# logged-in account the same familiar ~/scripts path without replacing an
# existing file or directory owned by that user.
if [ "$(id -u)" -ge 1000 ] && [ -n "${HOME:-}" ] && [ -d "$HOME" ] && \
   [ ! -e "$HOME/scripts" ] && [ ! -L "$HOME/scripts" ]; then
  ln -s "$EXPERIMENT_SCRIPTS_ROOT" "$HOME/scripts" 2>/dev/null || true
fi
'@
  $profileScript = $profileScript.Replace("__EXPERIMENT_SCRIPTS_ROOT__", $remoteSharedRoot).Replace("__EXPERIMENT_RESULTS_ROOT__", $remoteSharedResultsRoot).Replace("`r`n", "`n").Replace("`r", "`n")
  $profileScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($profileScript))

  # Accounts that have logged in over SSH at least once already have a home at
  # install time. A root helper gives them ~/scripts before their next login
  # without overwriting anything; later OS Login accounts get it from profile.
  $linkExistingHomesScript = @'
set -euo pipefail
shared_root=__EXPERIMENT_SCRIPTS_ROOT__
for home_dir in /home/*; do
  [ -d "$home_dir" ] || continue
  link_path="$home_dir/scripts"
  if [ ! -e "$link_path" ] && [ ! -L "$link_path" ]; then
    ln -s "$shared_root" "$link_path"
    chown -h "$(stat -c '%u:%g' "$home_dir")" "$link_path"
  fi
done
'@
  $linkExistingHomesScript = $linkExistingHomesScript.Replace("__EXPERIMENT_SCRIPTS_ROOT__", $remoteSharedRoot).Replace("`r`n", "`n").Replace("`r", "`n")
  $linkExistingHomesBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($linkExistingHomesScript))

  $uploadedFileArguments = ($uploadItems | ForEach-Object { "'$($_.RemotePath)'" }) -join " "
  $installedFileArguments = ($uploadItems | ForEach-Object { "'$($_.InstallPath)'" }) -join " "
  $installCommands = @($uploadItems | ForEach-Object {
    "sudo -n install -o root -g root -m 0755 '$($_.RemotePath)' '$($_.InstallPath)'"
  })
  $verifyLines = @(
    'set -euo pipefail',
    'cd "$HOME"',
    "chmod 0755 $uploadedFileArguments"
  ) + $installCommands + @(
    "printf '%s' '$profileScriptBase64' | base64 -d | sudo -n tee '$remoteProfilePath' >/dev/null",
    "sudo -n chown root:root '$remoteProfilePath'",
    "sudo -n chmod 0644 '$remoteProfilePath'",
    "printf '%s' '$linkExistingHomesBase64' | base64 -d | sudo -n bash",
    "cat <<'EOF_EXP2_SHA256' | sha256sum --check --strict -",
    ($checksumLines -join ([string][char]10)),
    'EOF_EXP2_SHA256',
    "for file in $installedFileArguments; do",
    '  test -r "$file"',
    '  test -x "$file"',
    '  bash -n "$file"',
    'done',
    "stat -c '%U:%G:%a' '$remoteSharedRoot' | grep -qx 'root:root:755'",
    "stat -c '%U:%G:%a' '$remoteSharedRoot/exp2' | grep -qx 'root:root:755'",
    "stat -c '%U:%G:%a' '$remoteSharedResultsRoot' | grep -qx 'root:root:755'",
    "stat -c '%U:%G:%a' '$remoteExperiment2Results' | grep -qx 'root:root:1777'",
    "stat -c '%U:%G:%a' '$remoteExperiment2Raw' | grep -qx 'root:root:1777'",
    "stat -c '%U:%G:%a' '$remoteProfilePath' | grep -qx 'root:root:644'",
    "bash -n '$remoteProfilePath'"
  )
  $verifyCommand = $verifyLines -join ([string][char]10)
  Invoke-NodeSsh -Node $ControlPlane -SshUser $SshUser -SshKeyFile $SshKeyFile -LogPath (Join-Path $LogDirectory "exp2-script-install-verify.log") -Command $verifyCommand
  Write-Host ("Experiment 2 scripts and shared results installed on {0}: {1}, {2} (available to every SSH account)" -f $ControlPlane.name, $remoteSharedRoot, $remoteExperiment2Results)
}

function Build-Exp2ToolImageArchive {
  param(
    [string]$ContextDirectory,
    [string]$Tag,
    [string]$ExpectedIperf3Version,
    [string]$ArchivePath,
    [string]$LogDirectory
  )

  if (-not (Test-Path -LiteralPath (Join-Path $ContextDirectory "Dockerfile") -PathType Leaf)) {
    throw "Experiment 2 tool image Dockerfile not found in: $ContextDirectory"
  }
  Assert-Command -Name "docker"

  # --provenance/--sbom false + type=docker: a buildx attestation manifest
  # would turn docker save into a manifest list and break platform resolution
  # during ctr import on the node. The local layer cache keeps rebuilds short.
  Invoke-Native -File "docker" -Arguments @(
    "build", "--platform", "linux/amd64", "--provenance=false", "--sbom=false",
    "--output", "type=docker", "-t", $Tag, $ContextDirectory
  ) -WorkingDirectory $ContextDirectory -LogPath (Join-Path $LogDirectory "exp2-tool-image-build.log") -TimingName "exp2 tool image build"

  # The Dockerfile already runs '/usr/local/bin/iperf3 --version' at build
  # time, so a broken binary fails docker build above. Here only the version
  # label of the freshly built image is compared with the 3.21 pin of the
  # engine and exp2_benchmark.sh, to catch a Dockerfile bumped without the
  # pins before T0.
  $labelsJson = ""
  try {
    $ErrorActionPreference = "Continue"
    $labelsJson = [string](& docker image inspect --format "{{json .Config.Labels}}" $Tag 2>&1 |
      ForEach-Object { $_.ToString() } | Out-String)
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($LASTEXITCODE -ne 0) {
    throw "docker image inspect failed for '$Tag': $($labelsJson.Trim())"
  }
  $imageLabels = $labelsJson.Trim() | ConvertFrom-Json
  $labelVersion = [string]$imageLabels.'exp2.iperf3.version'
  if ($labelVersion -ne $ExpectedIperf3Version) {
    throw "Experiment 2 tool image version drift: image label exp2.iperf3.version='$labelVersion' but the engine/exp2_benchmark.sh pin expects '$ExpectedIperf3Version'. Align exp2/image/Dockerfile ARG IPERF_VERSION with the pins."
  }

  Invoke-Native -File "docker" -Arguments @("save", $Tag, "-o", $ArchivePath) -WorkingDirectory $LogDirectory -LogPath (Join-Path $LogDirectory "exp2-tool-image-save.log") -TimingName "exp2 tool image save"
  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "docker save did not produce the image archive: $ArchivePath"
  }
  Write-Host ("Experiment 2 tool image archive ready: {0} ({1:N1} MB, iperf3 {2})" -f $ArchivePath, ((Get-Item -LiteralPath $ArchivePath).Length / 1MB), $labelVersion)
}

function Install-Exp2ToolImageOnNodes {
  param(
    [object[]]$Nodes,
    [string]$SshUser,
    [string]$SshKeyFile,
    [string]$ArchivePath,
    [string]$Tag,
    [string]$LogDirectory
  )

  $remoteArchive = "/tmp/exp2-tools-image.tar"
  foreach ($node in $Nodes) {
    Invoke-ScpToNode -Node $node -LocalPath $ArchivePath -RemotePath $remoteArchive -SshUser $SshUser -SshKeyFile $SshKeyFile
    $importCommand = @(
      'set -euo pipefail',
      "trap 'rm -f $remoteArchive' EXIT",
      "sudo -n ctr -n k8s.io images import '$remoteArchive' >/dev/null",
      "sudo -n ctr -n k8s.io images ls -q | grep -Fx '$Tag' >/dev/null",
      # Also confirm the tag is visible in the CRI image store kubelet queries.
      # cri-tools ships as a kubeadm dependency, but if it is missing the ctr
      # check already passed, so only warn.
      "if command -v crictl >/dev/null 2>&1; then sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock inspecti '$Tag' >/dev/null; else echo 'crictl not found; skipped CRI-level image check' >&2; fi"
    ) -join ([string][char]10)
    Invoke-NodeSsh -Node $node -SshUser $SshUser -SshKeyFile $SshKeyFile -LogPath (Join-Path $LogDirectory "exp2-tool-image-import-$($node.name).log") -Command $importCommand
    Write-Host ("Experiment 2 tool image loaded into containerd (k8s.io) on {0}: {1}" -f $node.name, $Tag)
  }
}

. (Join-Path $PSScriptRoot "native-routing-t4.ps1")

Assert-Command "terraform"
Assert-Command "gcloud"
Assert-Command "ssh-keygen"
# Node access uses the built-in Windows OpenSSH, not gcloud compute ssh.
Assert-Command "ssh"
Assert-Command "scp"

$script:Timeline = @()
$script:CommandTimings = @()
# Every relative path (infra/, results/) is resolved against this directory, so
# the tree can be copied anywhere and still runs.
$WorkspaceRoot = $PSScriptRoot
$TfDirFull = Resolve-WorkspacePath -Path $TfDir -BasePath $WorkspaceRoot
$VarFileFull = Resolve-TfvarsPath -Path $VarFile -BasePath $WorkspaceRoot
$script:OutDirFull = Join-WorkspacePath -Path $OutDir -BasePath $WorkspaceRoot
New-Item -ItemType Directory -Force -Path $script:OutDirFull | Out-Null
$script:CommandTimingsJsonPath = Join-Path $script:OutDirFull "command-timings.json"
$script:CommandTimingsCsvPath = Join-Path $script:OutDirFull "command-timings.csv"
$script:ProvisioningSummaryJsonPath = Join-Path $script:OutDirFull "provisioning-summary.json"
$script:ProvisioningSummaryCsvPath = Join-Path $script:OutDirFull "provisioning-summary-failed.csv"
$failureReportPath = Join-Path $script:OutDirFull "failure-report.json"

$planFile = Join-Path $script:OutDirFull "terraform.tfplan"
$planJson = Join-Path $script:OutDirFull "terraform-plan.json"
$applyLog = Join-Path $script:OutDirFull "terraform-apply.jsonl"
$inventoryPath = Join-Path $script:OutDirFull "inventory.json"

try {
  Set-Step "parse tfvars"
  $projectId = Get-TfVarString -Path $VarFileFull -Name "project_id"
  $networkName = Get-TfVarString -Path $VarFileFull -Name "network_name"
  $subnetworkName = Get-TfVarString -Path $VarFileFull -Name "subnetwork_name"
  $experimentNameFromTfvars = Get-TfVarString -Path $VarFileFull -Name "experiment_name"
  if ([string]::IsNullOrWhiteSpace($experimentNameFromTfvars)) { $experimentNameFromTfvars = $NetworkMode }
  if ($experimentNameFromTfvars -ne $NetworkMode) {
    throw "experiment_name '$experimentNameFromTfvars' does not match NetworkMode '$NetworkMode'."
  }
  # Every routing mode owns a separate Terraform root and default state under
  # infra/<mode>. The tfvars value is therefore the source of truth as well as
  # an early guard against invoking a wrapper with the wrong directory.
  $script:ExperimentName = $experimentNameFromTfvars
  $configuredPrefix = Get-TfVarString -Path $VarFileFull -Name "prefix"
  $preflightResourcePrefix = if ([string]::IsNullOrWhiteSpace($configuredPrefix)) {
    $experimentNameFromTfvars
  }
  else {
    $configuredPrefix
  }
  $preflightPodCidr = Get-TfVarString -Path $VarFileFull -Name "pod_cidr"
  if ([string]::IsNullOrWhiteSpace($preflightPodCidr)) { $preflightPodCidr = "10.244.0.0/16" }
  $expectedMtuRaw = Get-TfVarScalar -Path $VarFileFull -Name "expected_network_mtu"
  $region = Get-TfVarScalar -Path $VarFileFull -Name "region"
  if ([string]::IsNullOrWhiteSpace($region)) { $region = "asia-northeast3" }
  $machineType = Get-TfVarScalar -Path $VarFileFull -Name "machine_type"
  if ([string]::IsNullOrWhiteSpace($machineType)) { $machineType = "c2-standard-4" }
  # Read min_cpu_platform from tfvars so the control-variable check follows a
  # temporary verification on another machine family (C2D, ...).
  $minCpuPlatform = Get-TfVarString -Path $VarFileFull -Name "min_cpu_platform"
  if ([string]::IsNullOrWhiteSpace($minCpuPlatform)) { $minCpuPlatform = "Intel Cascade Lake" }
  $diskSizeGbRaw = Get-TfVarScalar -Path $VarFileFull -Name "disk_size_gb"
  # Must match the Terraform default (disk_size_gb = 25) for a correct quota.
  $diskSizeGb = if ([string]::IsNullOrWhiteSpace($diskSizeGbRaw)) { 25 } else { [int]$diskSizeGbRaw }
  $allowExternalIpRaw = Get-TfVarScalar -Path $VarFileFull -Name "allow_external_ip"
  $allowExternalIp = if ([string]::IsNullOrWhiteSpace($allowExternalIpRaw)) { $true } else { [bool]::Parse($allowExternalIpRaw) }
  if (-not $allowExternalIp) {
    throw "This provisioning workflow requires allow_external_ip = true so its explicit SSH key can reach every VM. IAP/internal-only access is not implemented by this experiment module."
  }
  if ([string]::IsNullOrWhiteSpace($projectId) -or [string]::IsNullOrWhiteSpace($networkName) -or
      [string]::IsNullOrWhiteSpace($subnetworkName)) {
    throw "project_id, network_name, and subnetwork_name must be literal string values in $VarFileFull."
  }

  Set-Step "validate gcloud authentication and SSH key"
  $activeAccounts = @(& gcloud auth list --filter "status:ACTIVE" --format "value(account)")
  if ($LASTEXITCODE -ne 0 -or @($activeAccounts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
    throw "No active gcloud account. Run 'gcloud auth login' (and configure Application Default Credentials for Terraform if needed) before provisioning."
  }
  if ($NetworkMode -eq "dynamic") {
    Set-Step "dynamic Network Connectivity API preflight"
    if (-not (Test-NetworkConnectivityApiEnabled -ProjectId $projectId)) {
      throw "Dynamic provisioning requires networkconnectivity.googleapis.com to be enabled before terraform plan. Run 'gcloud services enable networkconnectivity.googleapis.com --project $projectId' and retry."
    }
    Write-Host "Dynamic API prerequisite passed: networkconnectivity.googleapis.com is enabled."
  }

  $sshPublicKeyRaw = Get-TfVarString -Path $VarFileFull -Name "ssh_public_key_path"
  $sshPrivateKeyRaw = Get-TfVarString -Path $VarFileFull -Name "ssh_private_key_path"
  if ([string]::IsNullOrWhiteSpace($sshPublicKeyRaw)) {
    throw "ssh_public_key_path must be set in $VarFileFull."
  }
  if ([string]::IsNullOrWhiteSpace($sshPrivateKeyRaw)) {
    if (-not $sshPublicKeyRaw.EndsWith(".pub", [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Cannot derive the private key path because ssh_public_key_path does not end in '.pub'. Set ssh_private_key_path explicitly."
    }
    $sshPrivateKeyRaw = $sshPublicKeyRaw.Substring(0, $sshPublicKeyRaw.Length - 4)
  }
  $sshPublicKeyFull = Resolve-TerraformInputPath -Path $sshPublicKeyRaw -TfDirectory $TfDirFull
  $sshPrivateKeyFull = Resolve-TerraformInputPath -Path $sshPrivateKeyRaw -TfDirectory $TfDirFull
  Assert-SshKeyPair -PublicKeyPath $sshPublicKeyFull -PrivateKeyPath $sshPrivateKeyFull

  $projectInfoJson = & gcloud compute project-info describe --project $projectId --format json
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read Compute Engine project metadata for project '$projectId'."
  }
  $projectInfo = $projectInfoJson | Out-String | ConvertFrom-Json
  $commonMetadata = if ($projectInfo.PSObject.Properties.Name -contains "commonInstanceMetadata") {
    $projectInfo.commonInstanceMetadata
  }
  else {
    $null
  }
  $metadataItems = if ($null -ne $commonMetadata -and $commonMetadata.PSObject.Properties.Name -contains "items") {
    @($commonMetadata.items)
  }
  else {
    @()
  }
  $osLoginItem = @($metadataItems | Where-Object { $_.key -eq "enable-oslogin" })
  if ($osLoginItem.Count -gt 0 -and [string]$osLoginItem[-1].value -match "^(?i:true)$") {
    Write-Host "Project metadata has enable-oslogin=TRUE; Terraform will override it with enable-oslogin=FALSE on every experiment VM so the explicit SSH key remains usable."
  }
  # Total nodes = control plane 1 + benchmark 1 + worker_count
  $expectedNodeCount = 2 + $WorkerCount
  $script:ExpectedNodeCount = $expectedNodeCount
  Set-Step "claim provisioning result iteration"
  Initialize-RunResultFile `
    -Method $experimentNameFromTfvars `
    -NodeCount $expectedNodeCount `
    -Experiment $ExperimentLabel `
    -PlanOnly ([bool]$SkipApply)

  Set-Step "vpc mtu preflight"
  # MTU 1500 is a control variable. GCP VPC supports 1300~8896 but defaults to
  # 1460, so the real VPC value is verified here: the google_compute_network
  # data source does not expose mtu, so a Terraform precondition cannot do it.
  # expected_network_mtu = null in tfvars skips the check.
  if ($projectId -and $networkName) {
    $skipMtuCheck = $false
    $expectedMtu = 1500
    if (-not [string]::IsNullOrWhiteSpace($expectedMtuRaw)) {
      if ($expectedMtuRaw -eq "null") {
        $skipMtuCheck = $true
      }
      else {
        $expectedMtu = [int]$expectedMtuRaw
      }
    }
    if ($skipMtuCheck) {
      Write-Host "expected_network_mtu = null; skipping VPC MTU preflight."
    }
    else {
      $actualMtuRaw = & gcloud compute networks describe $networkName --project $projectId --format "value(mtu)"
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to describe network '$networkName' for the MTU preflight."
      }
      $actualMtu = [int](($actualMtuRaw | Out-String).Trim())
      if ($actualMtu -ne $expectedMtu) {
        throw "VPC MTU mismatch: network '$networkName' has MTU $actualMtu, expected $expectedMtu. Run 'gcloud compute networks update $networkName --mtu $expectedMtu' before provisioning (restart running VMs to apply), or set expected_network_mtu = null in tfvars to skip this check."
      }
      Write-Host "VPC MTU preflight passed: $networkName MTU = $actualMtu"
    }
  }
  else {
    Write-Warning "Could not parse project_id/network_name from tfvars; skipping VPC MTU preflight."
  }

  Set-Step "terraform init"
  Invoke-Native -File "terraform" -Arguments @("init", "-upgrade=false") -WorkingDirectory $TfDirFull -LogPath (Join-Path $script:OutDirFull "terraform-init.log") -TimingName "terraform init"

  Set-Step "select terraform workspace $($script:TerraformWorkspace)"
  Select-ExperimentTerraformWorkspace -TfDirFull $TfDirFull -Workspace $script:TerraformWorkspace -CreateIfMissing $false

  Set-Step "inspect terraform state"
  $existingNodeCount = Get-ExistingNodeCountFromState -TfDirFull $TfDirFull
  Write-Host "Nodes already in Terraform state: $existingNodeCount (target: $expectedNodeCount)"
  if ($existingNodeCount -ne $RequiredExistingNodes) {
    throw "This experiment requires exactly $RequiredExistingNodes existing node(s) before apply, found $existingNodeCount. Destroy/restore the required starting state before measuring this iteration."
  }
  $newNodeCount = [math]::Max(0, $expectedNodeCount - $existingNodeCount)
  # Ordinary pods such as CoreDNS can land on the control plane, so the CP
  # PodCIDR is advertised/routed too: the routing target count equals the
  # total Kubernetes node count.
  $targetRoutingNodeCount = $expectedNodeCount
  $existingRoutingNodeCount = $existingNodeCount
  $additionalRoutingNodeCount = [math]::Max(0, $targetRoutingNodeCount - $existingRoutingNodeCount)
  if (-not $SkipApply -and $newNodeCount -le 0) {
    throw "No new nodes would be created (state has $existingNodeCount, target $expectedNodeCount). Refusing to record a no-op provisioning measurement."
  }

  Set-Step "lock source image"
  $sourceImageRaw = Get-TfVarString -Path $VarFileFull -Name "source_image"
  $sourceImageProject = Get-TfVarString -Path $VarFileFull -Name "source_image_project"
  if ([string]::IsNullOrWhiteSpace($sourceImageProject)) { $sourceImageProject = "ubuntu-os-cloud" }
  $sourceImageFamily = Get-TfVarString -Path $VarFileFull -Name "source_image_family"
  if ([string]::IsNullOrWhiteSpace($sourceImageFamily)) { $sourceImageFamily = "ubuntu-2204-lts" }

  if ($existingNodeCount -gt 0) {
    # Reuse the exact image stored in the 4-node state for the new workers.
    $resolvedSourceImage = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "resolved_source_image"
    if (-not [string]::IsNullOrWhiteSpace($sourceImageRaw) -and $sourceImageRaw -ne $resolvedSourceImage) {
      Write-Warning "Ignoring changed source_image '$sourceImageRaw'; expansion is locked to existing cluster image '$resolvedSourceImage'."
    }
  }
  elseif (-not [string]::IsNullOrWhiteSpace($sourceImageRaw)) {
    $resolvedSourceImage = $sourceImageRaw
  }
  else {
    $resolvedImageRaw = & gcloud compute images describe-from-family $sourceImageFamily `
      --project $sourceImageProject --format "value(selfLink)"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to resolve image family '$sourceImageProject/$sourceImageFamily'."
    }
    $resolvedSourceImage = (($resolvedImageRaw | Out-String).Trim())
  }
  if ([string]::IsNullOrWhiteSpace($resolvedSourceImage)) {
    throw "Resolved source image is empty."
  }
  Write-Host "Locked source image: $resolvedSourceImage"

  if (-not $SkipQuotaPreflight -and $projectId) {
    Set-Step "quota preflight"
    # During an expansion only the nodes actually being created need quota
    # headroom: the existing nodes are already counted in the GCP quota usage,
    # so checking the full node count would double-count them.
    if ($newNodeCount -gt 0) {
      & (Join-Path $PSScriptRoot "check-gcp-quota.ps1") `
        -ProjectId $projectId `
        -Region $region `
        -MachineType $machineType `
        -NodeCount $newNodeCount `
        -DiskSizeGb $diskSizeGb `
        -DiskType "pd-balanced" `
        -AllowExternalIp $allowExternalIp `
        -OutDir $script:OutDirFull
    }
    else {
      Write-Host "No new VM nodes to create; skipping regional VM quota checks."
    }

    if ($script:IsMethodSpecificNative) {
      & (Join-Path $PSScriptRoot "check-native-routing-quota.ps1") `
        -Method $NetworkMode `
        -ProjectId $projectId `
        -Region $region `
        -NetworkName $networkName `
        -SubnetworkName $subnetworkName `
        -ResourcePrefix $preflightResourcePrefix `
        -NewNodeCount $newNodeCount `
        -TargetRoutingNodeCount $targetRoutingNodeCount `
        -AdditionalRoutingNodeCount $additionalRoutingNodeCount `
        -ClusterPodCidr $preflightPodCidr `
        -OutDir $script:OutDirFull
    }
  }
  elseif (-not $SkipQuotaPreflight) {
    Write-Warning "Could not parse project_id from tfvars; skipping quota preflight."
  }

  Set-Step "terraform plan"
  $planArguments = @(
    "plan",
    "-var-file=$VarFileFull",
    "-var=source_image=$resolvedSourceImage"
  )
  # Forced worker count. -var wins over -var-file.
  $planArguments += "-var=worker_count=$WorkerCount"
  if (-not [string]::IsNullOrWhiteSpace($CiliumVersion)) {
    $planArguments += "-var=cilium_version=$CiliumVersion"
  }
  $planArguments += "-out=$planFile"
  Invoke-Native -File "terraform" -Arguments $planArguments -WorkingDirectory $TfDirFull -LogPath (Join-Path $script:OutDirFull "terraform-plan.log") -TimingName "terraform plan"
  Invoke-Native -File "terraform" -Arguments @("show", "-json", $planFile) -WorkingDirectory $TfDirFull -LogPath $planJson -TimingName "terraform show plan json"

  Set-Step "terraform plan guard"
  & (Join-Path $PSScriptRoot "check-terraform-plan.ps1") `
    -PlanJson $planJson `
    -ExpectedNodeCount $expectedNodeCount `
    -ExpectedInstanceCreates $newNodeCount

  if ($SkipApply) {
    Write-ProvisioningSummary -Status "PLAN_ONLY"
    $script:RunCompleted = $true
    Write-Host "SkipApply was set. Terraform plan and guard checks completed; no resources were created."
    exit 0
  }

  Set-Step "build experiment 2 tool image archive"
  # Outside the measured window. Building before T0 surfaces a missing Docker
  # or a broken build before any VM exists; loading happens after T5.
  $exp2ToolImageArchive = Join-Path $script:OutDirFull "exp2-tools-image.tar"
  Build-Exp2ToolImageArchive `
    -ContextDirectory (Join-Path $PSScriptRoot "exp2\image") `
    -Tag $script:Exp2ToolImageTag `
    -ExpectedIperf3Version $script:Exp2ToolImageIperf3Version `
    -ArchivePath $exp2ToolImageArchive `
    -LogDirectory $script:OutDirFull

  Set-Step "terraform apply"
  $script:ApplyStarted = $true
  Invoke-Native -File "terraform" -Arguments @("apply", "-json", $planFile) -WorkingDirectory $TfDirFull -LogPath $applyLog -TimingName "terraform apply"
  $applyTiming = @($script:CommandTimings | Where-Object { $_.name -eq "terraform apply" })[-1]
  # Uses the UTC/monotonic values captured at the real process boundary, so
  # writing the timeline JSON is not counted inside T0~T1.
  Add-Timeline -Name "T0" -Description "terraform apply started" -Data @{
    command             = "terraform apply -json $planFile"
    target_node_count   = $expectedNodeCount
    existing_node_count = $existingNodeCount
  } -TimestampUtc ([datetime]::Parse($applyTiming.started_at)) -ElapsedMilliseconds ([double]$applyTiming.started_elapsed_ms)
  Add-Timeline -Name "T1" -Description "VM creation completed by terraform apply" -Data @{
    duration_milliseconds = $applyTiming.duration_milliseconds
    duration_seconds      = $applyTiming.duration_seconds
    log_path              = $applyLog
  } -TimestampUtc ([datetime]::Parse($applyTiming.ended_at)) -ElapsedMilliseconds ([double]$applyTiming.ended_elapsed_ms)

  Set-Step "read terraform outputs"
  $inventoryJson = & terraform -chdir="$TfDirFull" output -json inventory
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read terraform inventory output."
  }
  $inventoryJson | Out-String | Set-Content -Encoding UTF8 -Path $inventoryPath
  $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
  $nodes = Convert-InventoryToNodes -Inventory $inventory
  $sshUser = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "ssh_user"
  $podCidr = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "pod_cidr"
  $nodeTag = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "node_tag"
  $resourcePrefix = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "resource_prefix"
  $experimentName = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "experiment_name"
  $terraformKubernetesVersion = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "kubernetes_version"
  $terraformCiliumVersion = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "cilium_version"
  $bootstrapRevision = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "bootstrap_revision"
  if (-not [string]::IsNullOrWhiteSpace($KubernetesVersion) -and $KubernetesVersion -ne $terraformKubernetesVersion) {
    throw "KubernetesVersion parameter '$KubernetesVersion' disagrees with Terraform package version '$terraformKubernetesVersion'. Set kubernetes_apt_version in tfvars instead."
  }
  $KubernetesVersion = $terraformKubernetesVersion
  $CiliumVersion = $terraformCiliumVersion
  if ($experimentName -ne $script:ExperimentName) {
    throw "Terraform experiment_name output '$experimentName' differs from the filename method '$($script:ExperimentName)'."
  }
  $controlPlane = @($nodes | Where-Object { $_.role -eq "control-plane" })[0]
  $benchmark = @($nodes | Where-Object { $_.role -eq "benchmark" })[0]
  $workers = @($nodes | Where-Object { $_.role -eq "worker" } | Sort-Object role_index)
  $ciliumEndpointPair = Get-CiliumEndpointPair -Workers $workers

  Set-Step "wait for node bootstrap"
  # On GCP Ubuntu images the metadata startup script is run by
  # google-startup-scripts.service (guest agent), not cloud-init, so cloud-init
  # completion does not mean the startup script finished. Poll the marker file
  # with a timeout instead, in two stages:
  #  1) retry until SSH itself connects (boot / SSH key propagation)
  #  2) poll the startup-script completion marker (up to 1800s remotely)
  # Splitting them prevents retries multiplied by remote waits from burning
  # hours when the startup script fails permanently.
  # systemd state (is-active) must not be used: a oneshot service reports
  # "activating" while running, so the wait would pass immediately and a manual
  # rerun could collide with the guest agent over the apt lock. Only the marker
  # counts:
  #  - no marker (first boot)      -> poll until the guest agent writes it
  #  - revision mismatch (existing node + changed template) -> rerun manually
  #    (an existing node booted long ago, so no overlap with the guest agent)
  $bootstrapWaitCommand = @'
MARKER=/var/lib/k8s-node-bootstrap.done
REV="__BOOTSTRAP_REVISION__"
if [ ! -f "$MARKER" ]; then
  timeout 1800 bash -c "until test -f $MARKER; do sleep 0.1; done"
fi
if ! grep -Fxq "$REV" "$MARKER" 2>/dev/null; then
  sudo timeout 1800 google_metadata_script_runner startup
fi
grep -Fxq "$REV" "$MARKER"
'@
  $bootstrapWaitCommand = $bootstrapWaitCommand.Replace("__BOOTSTRAP_REVISION__", $bootstrapRevision)
  foreach ($node in $nodes) {
    # Retry every second without an attempt limit until SSH connects, with a
    # 30-minute cap so a host that never connects still reaches auto-destroy.
    Invoke-NodeSsh -Node $node -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull `
      -RetryDelaySeconds 1 -MaxWaitSeconds 1800 `
      -LogPath (Join-Path $script:OutDirFull "ssh-ready-$($node.name).log") `
      -Command "true"
    Invoke-NodeSsh -Node $node -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull `
      -MaxAttempts 2 -RetryDelaySeconds 15 `
      -LogPath (Join-Path $script:OutDirFull "bootstrap-wait-$($node.name).log") `
      -Command $bootstrapWaitCommand
    Write-Host "  bootstrap done: $($node.name) (kubelet/kubeadm/kubectl install + revision match)" -ForegroundColor Green
  }
  Write-Host "All node bootstrap done: Kubernetes package is installed" -ForegroundColor Green

  Set-Step "kubeadm init"
  $initScript = @"
#!/usr/bin/env bash
set -euxo pipefail
if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  sudo kubeadm init \
    --pod-network-cidr "$podCidr" \
    --apiserver-advertise-address "$($controlPlane.private_ip)" \
    --kubernetes-version "$KubernetesVersion" \
    --node-name "$($controlPlane.name)"
fi
mkdir -p "`$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "`$HOME/.kube/config"
sudo chown "`$(id -u):`$(id -g)" "`$HOME/.kube/config"
sudo mkdir -p /root/.kube
sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
sudo chown root:root /root/.kube/config
# Expose a shared kubeconfig so kubectl/cilium work for any SSH account.
sudo install -m 0644 /etc/kubernetes/admin.conf /etc/kubernetes/admin-shared.conf
sudo tee /etc/profile.d/99-experiment-kubeconfig.sh >/dev/null <<'EOF_KUBECONFIG_PROFILE'
if [ -z "`${KUBECONFIG:-}" ] && [ ! -r "`$HOME/.kube/config" ] && [ -r /etc/kubernetes/admin-shared.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin-shared.conf
fi
EOF_KUBECONFIG_PROFILE
"@
  Invoke-RemoteScript -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -Name "$NetworkMode-kubeadm-init" -ScriptContent $initScript -LogPath (Join-Path $script:OutDirFull "kubeadm-init.log")

  Set-Step "kubeadm join"
  # kubeadm token create reads /etc/kubernetes/admin.conf (root-only, 0600) by
  # default, so it fails with permission denied without sudo.
  $joinRaw = Invoke-NodeSshCapture -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -Command "sudo kubeadm token create --print-join-command"
  $joinLines = @($joinRaw -split "`r?`n" | Where-Object { $_ -match "kubeadm join" } | ForEach-Object { $_.Trim() })
  if ($joinLines.Count -eq 0) {
    throw "Failed to create kubeadm join command. Output: $joinRaw"
  }
  $joinCommand = $joinLines[-1]

  # On an expansion rerun, nodes already joined are detected by kubelet.conf.
  foreach ($node in @($benchmark) + $workers) {
    $joinScript = @"
#!/usr/bin/env bash
set -euxo pipefail
if [[ ! -f /etc/kubernetes/kubelet.conf ]]; then
  sudo $joinCommand --node-name "$($node.name)"
fi
"@
    Invoke-RemoteScript -Node $node -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -Name "$NetworkMode-join-$($node.name)" -ScriptContent $joinScript -LogPath (Join-Path $script:OutDirFull "kubeadm-join-$($node.name).log")
  }

  Set-Step "label nodes"
  $labelCommands = @(
    "kubectl label node $($controlPlane.name) experiment-role=control-plane --overwrite",
    "kubectl label node $($benchmark.name) experiment-role=benchmark --overwrite"
  )
  foreach ($worker in $workers) {
    $labelCommands += "kubectl label node $($worker.name) experiment-role=worker --overwrite"
  }
  Invoke-NodeSsh -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -LogPath (Join-Path $script:OutDirFull "label-nodes.log") -Command ($labelCommands -join " && ")

  Set-Step "install cilium"
  if ($NetworkMode -ne "vxlan") {
    $ciliumValues = @"
routingMode: native
ipv4NativeRoutingCIDR: "$podCidr"
autoDirectNodeRoutes: false
k8sServiceHost: "$($controlPlane.private_ip)"
k8sServicePort: "6443"
bgpControlPlane:
  enabled: true
hubble:
  enabled: false
kubeProxyReplacement: "false"
ipam:
  mode: kubernetes
operator:
  replicas: 1
"@
  }
  else {
    $ciliumValues = @"
routingMode: tunnel
tunnelProtocol: vxlan
tunnelPort: 8472
k8sServiceHost: "$($controlPlane.private_ip)"
k8sServicePort: "6443"
bgpControlPlane:
  enabled: true
hubble:
  enabled: false
kubeProxyReplacement: "false"
ipam:
  mode: kubernetes
operator:
  replicas: 1
"@
  }
  $ciliumValuesPath = "/tmp/cilium-values-$NetworkMode.yaml"
  if ($NetworkMode -ne "vxlan") {
    $ciliumValueAssertions = @"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.routingMode')" = "native"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.ipv4NativeRoutingCIDR')" = "$podCidr"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.autoDirectNodeRoutes')" = "false"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.ipam.mode')" = "kubernetes"
"@
  }
  else {
    $ciliumValueAssertions = @"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.routingMode')" = "tunnel"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.tunnelProtocol')" = "vxlan"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.tunnelPort')" = "8472"
test "`$(helm get values cilium -n kube-system -o json | jq -r '.ipam.mode')" = "kubernetes"
"@
  }
  $ciliumScript = @"
#!/usr/bin/env bash
set -euxo pipefail
cat >$ciliumValuesPath <<'EOF_CILIUM_VALUES'
$ciliumValues
EOF_CILIUM_VALUES
# Chart channel is https://helm.cilium.io (the quay.io oci:// path is not public)
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium
helm show chart cilium/cilium --version "$CiliumVersion" >/tmp/cilium-chart.yaml
helm upgrade --install cilium cilium/cilium \
  --version "$CiliumVersion" \
  --namespace kube-system \
  --values $ciliumValuesPath
test "`$(helm list --namespace kube-system --filter '^cilium$' --output json | jq -r '.[0].chart')" = "cilium-$CiliumVersion"
helm get values cilium -n kube-system -o yaml >/tmp/cilium-values-installed.yaml
$ciliumValueAssertions
"@
  Invoke-RemoteScript -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -Name "$NetworkMode-install-cilium" -ScriptContent $ciliumScript -LogPath (Join-Path $script:OutDirFull "install-cilium.log")

  Set-Step "wait all nodes Ready"
  # kubectl wait --all only waits for nodes that are already registered, so a
  # missing join would slip through. Wait for the target count first, then
  # assert the exact count before and after the Ready wait.
  $nodesReadyCommand = @'
set -eu
POLL_START="$SECONDS"
while [ $((SECONDS - POLL_START)) -lt 1200 ]; do
  count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  if [ "$count" -eq __EXPECTED_NODE_COUNT__ ]; then
    break
  fi
  sleep 0.1
done
test "$(kubectl get nodes --no-headers | wc -l)" -eq __EXPECTED_NODE_COUNT__
kubectl wait --for=condition=Ready node --all --timeout=20m
test "$(kubectl get nodes --no-headers | wc -l)" -eq __EXPECTED_NODE_COUNT__
'@
  $nodesReadyCommand = $nodesReadyCommand.Replace("__EXPECTED_NODE_COUNT__", [string]$expectedNodeCount)
  Invoke-NodeSsh -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -LogPath (Join-Path $script:OutDirFull "nodes-ready.log") -Command $nodesReadyCommand
  Add-Timeline -Name "T2" -Description "exactly $expectedNodeCount Kubernetes nodes are registered and Ready"
  Write-StageNotice -Message @(
    "[T2 done] kubectl install: ${expectedNodeCount} nodes are all Ready. "
  )

  Set-Step "wait cilium ready"
  Invoke-NodeSsh -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -LogPath (Join-Path $script:OutDirFull "cilium-status.log") -Command "cilium status --wait"
  Add-Timeline -Name "T3" -Description "Cilium Ready"
  Write-StageNotice -Message @(
    "[T3 done] cilium status all clear - Cilium nodes are ready"
  )

  # -- T4: method-specific VPC task ------------------------------------------
  if ($NetworkMode -in @("vxlan", "host")) {
    Set-Step "record T4 (no VPC task for $networkModeLabel)"
    $t3Boundary = Get-TimelineEntry -Name "T3"
    Add-Timeline `
      -Name "T4" `
      -Description "$networkModeLabel has no method-specific VPC task; T4 shares the T3 boundary (no-op)" `
      -TimestampUtc ([datetime]::Parse($t3Boundary.timestamp)) `
      -ElapsedMilliseconds ([double]$t3Boundary.elapsed_ms)
    Write-StageNotice -Message @(
      "[T4 done] $networkModeLabel does not require VPC tasks (no-op)."
    )
  }
  else {
    Set-Step "$networkModeLabel method-specific T4 routing task"
    # CoreDNS tolerates the kubeadm control-plane taint and uses a regular Pod
    # IP, so every Kubernetes Node PodCIDR must be reachable in native mode.
    $routingNodes = @($controlPlane) + @($benchmark) + @($workers)
    Invoke-NativeRoutingT4 `
      -Method $NetworkMode `
      -ControlPlane $controlPlane `
      -RoutingNodes $routingNodes `
      -SshUser $sshUser `
      -SshKeyFile $sshPrivateKeyFull `
      -ProjectId $projectId `
      -NetworkName $networkName `
      -SubnetworkName $subnetworkName `
      -Region $region `
      -ResourcePrefix $resourcePrefix `
      -TfDirFull $TfDirFull `
      -OutDirFull $script:OutDirFull
    Add-Timeline -Name "T4" -Description "$networkModeLabel method-specific routing task completed" -Data @{
      routed_node_count = $routingNodes.Count
      control_plane_advertised = $true
      routing_state = (Get-T4StatePath -TfDirFull $TfDirFull -Method $NetworkMode)
    }
    Write-StageNotice -Message @(
      "[T4 done] $networkModeLabel routing is configured for Control Plane, Benchmark, and all Worker PodCIDRs."
    )
  }

  Set-Step "$networkModeLabel worker-0 to last-worker connectivity test"
  $anchorNode = [string]$ciliumEndpointPair.anchor
  $targetNode = [string]$ciliumEndpointPair.target
  Write-Host "$networkModeLabel connectivity endpoints: worker-0=$anchorNode, last-worker=$targetNode"
  if ($NetworkMode -eq "host") {
    $ciliumConnectivityScript = @'
#!/usr/bin/env bash
set -euxo pipefail

TEST_NAMESPACE=cilium-__NETWORK_MODE__-connectivity
PAIR_LABEL=experiment-cilium-endpoint
WORKLOAD_LABEL=experiment-cilium-workload
ANCHOR_NODE="__ANCHOR_NODE__"
TARGET_NODE="__TARGET_NODE__"
EXPECTED_ACTIONS_PER_PAIR=6
EXPECTED_SAME_NODE_ACTIONS=3
EXPECTED_CROSS_NODE_ACTIONS=3
EXPECTED_WORKLOAD_PODS=5
ECHO_PORT=8080
CLIENT_IMAGE="quay.io/cilium/alpine-curl:v1.10.0@sha256:913e8c9f3d960dde03882defa0edd3a919d529c2eb167caa7f54194528bde364"
ECHO_IMAGE="quay.io/cilium/json-mock:v1.3.9@sha256:c98b26177a5a60020e5aa404896d55f0ab573d506f42acfb4aa4f5705a5c6f56"
JUNIT_FILE=/tmp/cilium-__NETWORK_MODE__-connectivity.xml
PAIR_LOG=/tmp/cilium-__NETWORK_MODE__-connectivity-pair.log
PAIR_SUMMARY=/tmp/cilium-__NETWORK_MODE__-connectivity-pair.tsv

clear_pair_labels() {
  kubectl label nodes -l experiment-role=worker "$PAIR_LABEL-" --overwrite >/dev/null 2>&1 || true
}
trap clear_pair_labels EXIT

if [[ "$TARGET_NODE" == "$ANCHOR_NODE" ]]; then
  echo "worker-0 and last worker must be different nodes: $ANCHOR_NODE" >&2
  exit 1
fi

kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found --wait=true
clear_pair_labels
kubectl label nodes "$ANCHOR_NODE" "$TARGET_NODE" "$PAIR_LABEL=true" --overwrite

EXPECTED_NODES="$(printf '%s\n%s\n' "$ANCHOR_NODE" "$TARGET_NODE" | sort)"
SELECTED_NODES="$(kubectl get nodes -l "$PAIR_LABEL=true" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)"
if [[ "$SELECTED_NODES" != "$EXPECTED_NODES" ]]; then
  echo "endpoint label selected unexpected nodes" >&2
  echo "expected: $EXPECTED_NODES" >&2
  echo "actual: $SELECTED_NODES" >&2
  exit 1
fi

ANCHOR_IP="$(kubectl get node "$ANCHOR_NODE" -o json | jq -r '.status.addresses[] | select(.type == "InternalIP") | .address' | awk '!/:/{print; exit}')"
TARGET_IP="$(kubectl get node "$TARGET_NODE" -o json | jq -r '.status.addresses[] | select(.type == "InternalIP") | .address' | awk '!/:/{print; exit}')"
if [[ -z "$ANCHOR_IP" || -z "$TARGET_IP" || "$ANCHOR_IP" == "$TARGET_IP" ]]; then
  echo "failed to resolve distinct worker InternalIPv4 addresses: anchor=${ANCHOR_IP:-missing} target=${TARGET_IP:-missing}" >&2
  exit 1
fi

kubectl create namespace "$TEST_NAMESPACE"

create_client_pod() {
  local name="$1"
  local node="$2"
  cat <<EOF_HOST_CLIENT | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${TEST_NAMESPACE}
  labels:
    ${WORKLOAD_LABEL}: "true"
spec:
  nodeName: ${node}
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Always
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: ${CLIENT_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["/usr/bin/pause"]
EOF_HOST_CLIENT
}

create_echo_pod() {
  local name="$1"
  local node="$2"
  cat <<EOF_HOST_ECHO | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${TEST_NAMESPACE}
  labels:
    ${WORKLOAD_LABEL}: "true"
spec:
  nodeName: ${node}
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Always
  terminationGracePeriodSeconds: 0
  containers:
  - name: echo
    image: ${ECHO_IMAGE}
    imagePullPolicy: IfNotPresent
    env:
    - name: PORT
      value: "${ECHO_PORT}"
    - name: NAMED_PORT
      value: "http-${ECHO_PORT}"
    ports:
    - name: "http-${ECHO_PORT}"
      containerPort: ${ECHO_PORT}
      protocol: TCP
    readinessProbe:
      httpGet:
        path: /
        port: ${ECHO_PORT}
      initialDelaySeconds: 1
      periodSeconds: 1
EOF_HOST_ECHO
}

# Reproduces the exact 5-pod shape of the Cilium CLI no-policies/pod-to-pod
# test: client/client2/echo-same-node on worker-0, client3/echo-other-node on
# the last worker. One echo per node, so 8080 never collides under hostNetwork.
create_client_pod client "$ANCHOR_NODE"
create_client_pod client2 "$ANCHOR_NODE"
create_client_pod client3 "$TARGET_NODE"
create_echo_pod echo-same-node "$ANCHOR_NODE"
create_echo_pod echo-other-node "$TARGET_NODE"

kubectl -n "$TEST_NAMESPACE" wait --for=condition=Ready pod -l "$WORKLOAD_LABEL=true" --timeout=10m

WORKLOAD_POD_COUNT="$(kubectl -n "$TEST_NAMESPACE" get pods -l "$WORKLOAD_LABEL=true" -o json | jq '.items | length')"
if [[ "$WORKLOAD_POD_COUNT" -ne "$EXPECTED_WORKLOAD_PODS" ]]; then
  echo "unexpected Host workload pod count: actual=$WORKLOAD_POD_COUNT expected=$EXPECTED_WORKLOAD_PODS" >&2
  kubectl -n "$TEST_NAMESPACE" get pods -o wide >&2
  exit 1
fi

WORKLOAD_NODES="$(kubectl -n "$TEST_NAMESPACE" get pods -l "$WORKLOAD_LABEL=true" -o json | jq -r '.items[].spec.nodeName' | sort -u)"
if [[ "$WORKLOAD_NODES" != "$EXPECTED_NODES" ]]; then
  echo "Host workload did not use exactly worker-0 and the last worker" >&2
  echo "expected: $EXPECTED_NODES" >&2
  echo "actual: $WORKLOAD_NODES" >&2
  kubectl -n "$TEST_NAMESPACE" get pods -o wide >&2
  exit 1
fi

assert_host_pod() {
  local pod="$1"
  local expected_node="$2"
  local expected_ip="$3"
  local actual
  actual="$(kubectl -n "$TEST_NAMESPACE" get pod "$pod" -o jsonpath='{.spec.nodeName}{"|"}{.spec.hostNetwork}{"|"}{.spec.dnsPolicy}{"|"}{.status.podIP}{"|"}{.status.hostIP}{"|"}{.status.phase}')"
  if [[ "$actual" != "$expected_node|true|ClusterFirstWithHostNet|$expected_ip|$expected_ip|Running" ]]; then
    echo "Host workload pod mismatch: pod=$pod expected=$expected_node|true|ClusterFirstWithHostNet|$expected_ip|$expected_ip|Running actual=$actual" >&2
    exit 1
  fi
}

assert_host_pod client "$ANCHOR_NODE" "$ANCHOR_IP"
assert_host_pod client2 "$ANCHOR_NODE" "$ANCHOR_IP"
assert_host_pod client3 "$TARGET_NODE" "$TARGET_IP"
assert_host_pod echo-same-node "$ANCHOR_NODE" "$ANCHOR_IP"
assert_host_pod echo-other-node "$TARGET_NODE" "$TARGET_IP"

BAD_CLIENT_IMAGE_COUNT="$(kubectl -n "$TEST_NAMESPACE" get pods -l "$WORKLOAD_LABEL=true" -o json | jq --arg image "$CLIENT_IMAGE" '[.items[] | select(.metadata.name | test("^client")) | select(.spec.containers[0].image != $image)] | length')"
BAD_ECHO_IMAGE_COUNT="$(kubectl -n "$TEST_NAMESPACE" get pods -l "$WORKLOAD_LABEL=true" -o json | jq --arg image "$ECHO_IMAGE" '[.items[] | select(.metadata.name | test("^echo-")) | select(.spec.containers[0].image != $image)] | length')"
IMAGE_ID_COUNT="$(kubectl -n "$TEST_NAMESPACE" get pods -l "$WORKLOAD_LABEL=true" -o json | jq '[.items[].status.containerStatuses[0].imageID | select(length > 0)] | length')"
UNIQUE_IMAGE_ID_COUNT="$(kubectl -n "$TEST_NAMESPACE" get pods -l "$WORKLOAD_LABEL=true" -o json | jq '[.items[].status.containerStatuses[0].imageID | select(length > 0)] | unique | length')"
CLIENT_IMAGE_ID="$(kubectl -n "$TEST_NAMESPACE" get pod client -o jsonpath='{.status.containerStatuses[0].imageID}')"
ECHO_IMAGE_ID="$(kubectl -n "$TEST_NAMESPACE" get pod echo-other-node -o jsonpath='{.status.containerStatuses[0].imageID}')"
if [[ "$BAD_CLIENT_IMAGE_COUNT" -ne 0 || "$BAD_ECHO_IMAGE_COUNT" -ne 0 || "$IMAGE_ID_COUNT" -ne "$EXPECTED_WORKLOAD_PODS" || "$UNIQUE_IMAGE_ID_COUNT" -ne 2 || -z "$CLIENT_IMAGE_ID" || -z "$ECHO_IMAGE_ID" || "$CLIENT_IMAGE_ID" == "$ECHO_IMAGE_ID" ]]; then
  echo "Host workload image mismatch: bad_clients=$BAD_CLIENT_IMAGE_COUNT bad_echoes=$BAD_ECHO_IMAGE_COUNT image_ids=$IMAGE_ID_COUNT unique_image_ids=$UNIQUE_IMAGE_ID_COUNT client=${CLIENT_IMAGE_ID:-missing} echo=${ECHO_IMAGE_ID:-missing}" >&2
  exit 1
fi

rm -f "$JUNIT_FILE" "$PAIR_LOG" "$PAIR_SUMMARY"
printf 'action\tclient\tdestination\trelation\tresult\n' > "$PAIR_LOG"
ACTION_COUNT=0
SAME_NODE_ACTIONS=0
CROSS_NODE_ACTIONS=0

run_action() {
  local client="$1"
  local destination="$2"
  local relation="$3"
  local next_action=$((ACTION_COUNT + 1))
  if ! kubectl -n "$TEST_NAMESPACE" exec "$client" -- curl --fail --silent --show-error --connect-timeout 5 --max-time 15 --output /dev/null "http://${destination}:${ECHO_PORT}/" 2>>"$PAIR_LOG"; then
    echo "Host connectivity action failed: client=$client destination=$destination relation=$relation" >&2
    exit 1
  fi
  ACTION_COUNT="$next_action"
  if [[ "$relation" == "same-node" ]]; then
    SAME_NODE_ACTIONS=$((SAME_NODE_ACTIONS + 1))
  else
    CROSS_NODE_ACTIONS=$((CROSS_NODE_ACTIONS + 1))
  fi
  printf '%s\t%s\t%s\t%s\tPASS\n' "$ACTION_COUNT" "$client" "$destination" "$relation" | tee -a "$PAIR_LOG"
}

# no-policies/pod-to-pod is 3 clients x 2 echoes = 6 actions, split into 3
# same-node and 3 cross-node. Host runs the same combination and the same ratio.
run_action client "$ANCHOR_IP" same-node
run_action client "$TARGET_IP" cross-node
run_action client2 "$ANCHOR_IP" same-node
run_action client2 "$TARGET_IP" cross-node
run_action client3 "$ANCHOR_IP" cross-node
run_action client3 "$TARGET_IP" same-node

if [[ "$ACTION_COUNT" -ne "$EXPECTED_ACTIONS_PER_PAIR" || "$SAME_NODE_ACTIONS" -ne "$EXPECTED_SAME_NODE_ACTIONS" || "$CROSS_NODE_ACTIONS" -ne "$EXPECTED_CROSS_NODE_ACTIONS" ]]; then
  echo "unexpected Host action counts: total=$ACTION_COUNT same-node=$SAME_NODE_ACTIONS cross-node=$CROSS_NODE_ACTIONS" >&2
  exit 1
fi

WORKLOAD_NODES_CSV="$(printf '%s\n' "$WORKLOAD_NODES" | paste -sd, -)"
printf 'anchor\ttarget\tactions\ttest_namespace\tworkload_nodes\thost_network\tanchor_ip\ttarget_ip\tworkload_pods\tsame_node_actions\tcross_node_actions\tclient_image\tclient_image_id\techo_image\techo_image_id\n' > "$PAIR_SUMMARY"
printf '%s\t%s\t%s\t%s\t%s\ttrue\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ANCHOR_NODE" "$TARGET_NODE" "$ACTION_COUNT" "$TEST_NAMESPACE" "$WORKLOAD_NODES_CSV" "$ANCHOR_IP" "$TARGET_IP" "$WORKLOAD_POD_COUNT" "$SAME_NODE_ACTIONS" "$CROSS_NODE_ACTIONS" "$CLIENT_IMAGE" "$CLIENT_IMAGE_ID" "$ECHO_IMAGE" "$ECHO_IMAGE_ID" >> "$PAIR_SUMMARY"

cat > "$JUNIT_FILE" <<EOF_HOST_JUNIT
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="host-network-connectivity" tests="1" failures="0">
  <testcase classname="host-network" name="worker-pair-six-pod-to-pod-actions" />
</testsuite>
EOF_HOST_JUNIT

echo "All 1 Host tests (${ACTION_COUNT} actions) successful."
cat "$PAIR_SUMMARY"
'@
  }
  else {
    $ciliumConnectivityScript = @'
#!/usr/bin/env bash
set -euxo pipefail

TEST_NAMESPACE=cilium-__NETWORK_MODE__-connectivity
PAIR_LABEL=experiment-cilium-endpoint
ANCHOR_NODE="__ANCHOR_NODE__"
TARGET_NODE="__TARGET_NODE__"
EXPECTED_ACTIONS_PER_PAIR=6
JUNIT_FILE=/tmp/cilium-__NETWORK_MODE__-connectivity.xml
PAIR_LOG=/tmp/cilium-__NETWORK_MODE__-connectivity-pair.log
PAIR_SUMMARY=/tmp/cilium-__NETWORK_MODE__-connectivity-pair.tsv

clear_pair_labels() {
  kubectl label nodes -l experiment-role=worker "$PAIR_LABEL-" --overwrite >/dev/null 2>&1 || true
}
trap clear_pair_labels EXIT

if [[ "$TARGET_NODE" == "$ANCHOR_NODE" ]]; then
  echo "worker-0 and last worker must be different nodes: $ANCHOR_NODE" >&2
  exit 1
fi

cilium connectivity test --cleanup --test-namespace "$TEST_NAMESPACE"
clear_pair_labels
kubectl label nodes "$ANCHOR_NODE" "$TARGET_NODE" "$PAIR_LABEL=true" --overwrite

EXPECTED_NODES="$(printf '%s\n%s\n' "$ANCHOR_NODE" "$TARGET_NODE" | sort)"
SELECTED_NODES="$(kubectl get nodes -l "$PAIR_LABEL=true" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)"
if [[ "$SELECTED_NODES" != "$EXPECTED_NODES" ]]; then
  echo "endpoint label selected unexpected nodes" >&2
  echo "expected: $EXPECTED_NODES" >&2
  echo "actual: $SELECTED_NODES" >&2
  exit 1
fi

rm -f "$JUNIT_FILE" "$PAIR_LOG" "$PAIR_SUMMARY"
echo "=== Cilium worker endpoint pair: ${ANCHOR_NODE} <-> ${TARGET_NODE} ==="
cilium connectivity test \
  --test no-policies/pod-to-pod \
  --node-selector "$PAIR_LABEL=true" \
  --ip-families ipv4 \
  --test-concurrency 1 \
  --test-namespace "$TEST_NAMESPACE" \
  --connect-timeout 5s \
  --request-timeout 15s \
  --timeout 10m \
  --junit-file "$JUNIT_FILE" \
  --hubble=false \
  --flow-validation disabled 2>&1 | tee "$PAIR_LOG"

ACTION_COUNT="$(sed -nE 's/.*All 1 tests \(([0-9]+) actions\) successful.*/\1/p' "$PAIR_LOG" | tail -n 1)"
if [[ "$ACTION_COUNT" != "$EXPECTED_ACTIONS_PER_PAIR" ]]; then
  echo "unexpected Cilium action count for ${ANCHOR_NODE}<->${TARGET_NODE}: actual=${ACTION_COUNT:-missing} expected=$EXPECTED_ACTIONS_PER_PAIR" >&2
  exit 1
fi

mapfile -t RUN_NAMESPACES < <(
  kubectl get namespaces -o json |
    jq -r --arg prefix "${TEST_NAMESPACE}-" '.items[].metadata.name | select(startswith($prefix))' |
    sort
)
if [[ "${#RUN_NAMESPACES[@]}" -ne 1 ]]; then
  echo "expected exactly one Cilium test namespace, found ${#RUN_NAMESPACES[@]}: ${RUN_NAMESPACES[*]:-none}" >&2
  exit 1
fi
RUN_NAMESPACE="${RUN_NAMESPACES[0]}"

WORKLOAD_FILTER='^(client|client2|client3|echo-same-node|echo-other-node)-'
WORKLOAD_POD_COUNT="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq --arg pattern "$WORKLOAD_FILTER" '[.items[] | select(.metadata.name | test($pattern))] | length')"
if [[ "$WORKLOAD_POD_COUNT" -ne 5 ]]; then
  echo "unexpected Cilium workload pod count in $RUN_NAMESPACE: actual=$WORKLOAD_POD_COUNT expected=5" >&2
  kubectl -n "$RUN_NAMESPACE" get pods -o wide >&2
  exit 1
fi
HOSTNETWORK_POD_COUNT="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq --arg pattern "$WORKLOAD_FILTER" '[.items[] | select(.metadata.name | test($pattern)) | select(.spec.hostNetwork == true)] | length')"
if [[ "$HOSTNETWORK_POD_COUNT" -ne 0 ]]; then
  echo "Cilium VXLAN-style T5 must use regular Pod networking, found $HOSTNETWORK_POD_COUNT hostNetwork workload(s)." >&2
  kubectl -n "$RUN_NAMESPACE" get pods -o wide >&2
  exit 1
fi
WORKLOAD_NODES="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq -r --arg pattern "$WORKLOAD_FILTER" '.items[] | select(.metadata.name | test($pattern)) | .spec.nodeName' | sort -u)"
if [[ "$WORKLOAD_NODES" != "$EXPECTED_NODES" ]]; then
  echo "Cilium workload did not use exactly worker-0 and the last worker" >&2
  echo "expected: $EXPECTED_NODES" >&2
  echo "actual: $WORKLOAD_NODES" >&2
  kubectl -n "$RUN_NAMESPACE" get pods -o wide >&2
  exit 1
fi

PRIMARY_CLIENT_NODE="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq -r '.items[] | select(.metadata.name | test("^(client|client2)-")) | .spec.nodeName' | sort -u)"
OTHER_CLIENT_NODE="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq -r '.items[] | select(.metadata.name | test("^client3-")) | .spec.nodeName' | sort -u)"
ECHO_SAME_NODE="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq -r '.items[] | select(.metadata.name | test("^echo-same-node-")) | .spec.nodeName')"
ECHO_OTHER_NODE="$(kubectl -n "$RUN_NAMESPACE" get pods -o json | jq -r '.items[] | select(.metadata.name | test("^echo-other-node-")) | .spec.nodeName')"
if [[ "$(printf '%s\n' "$PRIMARY_CLIENT_NODE" | sed '/^$/d' | wc -l)" -ne 1 || "$(printf '%s\n' "$OTHER_CLIENT_NODE" | sed '/^$/d' | wc -l)" -ne 1 || "$PRIMARY_CLIENT_NODE" != "$ECHO_SAME_NODE" || "$OTHER_CLIENT_NODE" != "$ECHO_OTHER_NODE" || "$PRIMARY_CLIENT_NODE" == "$OTHER_CLIENT_NODE" ]]; then
  echo "Cilium workload topology did not contain the expected cross-node client-to-echo path" >&2
  echo "primary_client_node=$PRIMARY_CLIENT_NODE other_client_node=$OTHER_CLIENT_NODE echo_same_node=$ECHO_SAME_NODE echo_other_node=$ECHO_OTHER_NODE" >&2
  kubectl -n "$RUN_NAMESPACE" get pods -o wide >&2
  exit 1
fi

WORKLOAD_NODES_CSV="$(printf '%s\n' "$WORKLOAD_NODES" | paste -sd, -)"
printf 'anchor\ttarget\tactions\ttest_namespace\tworkload_nodes\thost_network\n' > "$PAIR_SUMMARY"
printf '%s\t%s\t%s\t%s\t%s\tfalse\n' "$ANCHOR_NODE" "$TARGET_NODE" "$ACTION_COUNT" "$RUN_NAMESPACE" "$WORKLOAD_NODES_CSV" >> "$PAIR_SUMMARY"
cat "$PAIR_SUMMARY"
'@
  }
  $ciliumConnectivityScript = $ciliumConnectivityScript.Replace("__NETWORK_MODE__", $NetworkMode).Replace("__ANCHOR_NODE__", $anchorNode).Replace("__TARGET_NODE__", $targetNode)
  Invoke-RemoteScript -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -Name "$NetworkMode-cilium-endpoint-connectivity-test" -ScriptContent $ciliumConnectivityScript -LogPath (Join-Path $script:OutDirFull "cilium-connectivity-test.log")
  $t5Description = if ($NetworkMode -eq "host") {
    "HostNetwork connectivity succeeded between worker-0 and the last worker; five HostNetwork workloads mirroring no-policies/pod-to-pod, fixed six actions (3 same-node, 3 cross-node), and exact node/IP placement verified"
  }
  else {
    "Cilium no-policies/pod-to-pod succeeded between worker-0 and the last worker; fixed six actions and exact cross-node workload placement verified"
  }
  Add-Timeline -Name "T5" -Description $t5Description
  # T5 is retained as the required connectivity validation point, but it is not
  # part of the experiment 1 duration metric. Snapshot the final format (6 POINT
  # + 6 DURATION) here; the SUCCESS summary below refreshes status and script time.
  Assert-CompleteTimeline
  Write-ProvisioningSummary -Status "RUNNING"
  $t0Point = Get-TimelineEntry -Name "T0"
  $t4Point = Get-TimelineEntry -Name "T4"
  $totalProvisioningMs = [math]::Round(([double]$t4Point.elapsed_ms) - ([double]$t0Point.elapsed_ms))
  Write-StageNotice -Message @(
    "[T5 done] $networkModeLabel connectivity succeeded between worker-0 ($anchorNode) and the last worker ($targetNode).",
    "T0~T4 provisioning measurements are complete. (T0_to_T4 = $totalProvisioningMs ms; T5 is validation only)",
    "Subsequent output is verification outside the measurement (e.g. node taint, benchmark script)."
  )

  try {
    Invoke-ScpFromNode -Node $controlPlane -RemotePath "/tmp/cilium-$NetworkMode-connectivity.xml" -LocalPath (Join-Path $script:OutDirFull "cilium-$NetworkMode-connectivity.xml") -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull
  }
  catch {
    Write-Warning "Connectivity test passed, but its JUnit artifact could not be copied: $($_.Exception.Message)"
  }
  try {
    Invoke-ScpFromNode -Node $controlPlane -RemotePath "/tmp/cilium-$NetworkMode-connectivity-pair.tsv" -LocalPath (Join-Path $script:OutDirFull "cilium-$NetworkMode-connectivity-pair.tsv") -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull
  }
  catch {
    Write-Warning "Connectivity test passed, but the endpoint summary could not be copied: $($_.Exception.Message)"
  }

  Set-Step "post-T5 sanity checks"
  # Further verification outside the measured window (T0~T4), after the T5
  # connectivity validation:
  # - the exact installed Cilium Helm chart version
  # - whether the Cilium BGP CRDs are installed (N-Dynamic)
  # - registered node count == target node count (catches a missed join, which
  #   kubectl wait --all cannot detect)
  $sanityCommand = "test `"`$(helm list --namespace kube-system --filter '^cilium$' --output json | jq -r '.[0].chart')`" = `"cilium-$CiliumVersion`" && kubectl get crd -o name | grep -i ciliumbgp && test `"`$(kubectl get nodes --no-headers | wc -l)`" -eq $expectedNodeCount"
  Invoke-NodeSsh -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -LogPath (Join-Path $script:OutDirFull "cilium-helm-crd-check.log") -Command $sanityCommand

  Set-Step "install experiment 2 scripts on control plane"
  # The measurement scripts are placed under the shared CP path only after T5
  # and the sanity checks. Every routing method uses this same engine.
  Install-Exp2ScriptsOnControlPlane `
    -ControlPlane $controlPlane `
    -SshUser $sshUser `
    -SshKeyFile $sshPrivateKeyFull `
    -LocalScriptsRoot $PSScriptRoot `
    -StagingDirectory $script:OutDirFull `
    -LogDirectory $script:OutDirFull

  Set-Step "load experiment 2 tool image on benchmark and worker-0"
  # Load the prebuilt image (iperf3 3.21) used by the experiment 2 Benchmark
  # and Server pods into the containerd (k8s.io) of both nodes. Dummy pods run
  # alpine, and reloading on an expansion rerun is idempotent.
  Install-Exp2ToolImageOnNodes `
    -Nodes @($benchmark, $workers[0]) `
    -SshUser $sshUser `
    -SshKeyFile $sshPrivateKeyFull `
    -ArchivePath $exp2ToolImageArchive `
    -Tag $script:Exp2ToolImageTag `
    -LogDirectory $script:OutDirFull
  Remove-Item -LiteralPath $exp2ToolImageArchive -Force

  $connectivityCleanupCommand = if ($NetworkMode -eq "host") {
    "kubectl delete namespace cilium-host-connectivity --ignore-not-found --wait=true"
  }
  else {
    "cilium connectivity test --cleanup --test-namespace cilium-$NetworkMode-connectivity"
  }
  Invoke-NodeSsh -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -LogPath (Join-Path $script:OutDirFull "connectivity-cleanup.log") -Command $connectivityCleanupCommand

  Set-Step "ensure benchmark node taint"
  # The benchmark node is tainted so ordinary pods cannot be scheduled on it.
  # Experiment 1 creates no benchmark pod, but experiment 2 needs the resource
  # guarantee, so the taint is applied and verified here, outside the measured
  # window. --overwrite makes it safe on an expansion rerun.
  $taintCommand = "kubectl taint node $($benchmark.name) benchmark-only=true:NoSchedule --overwrite && kubectl get node $($benchmark.name) -o jsonpath='{.spec.taints[*].key}' | grep -qw benchmark-only"
  Invoke-NodeSsh -Node $controlPlane -SshUser $sshUser -SshKeyFile $sshPrivateKeyFull -LogPath (Join-Path $script:OutDirFull "benchmark-taint.log") -Command $taintCommand

  Set-Step "control variable checks"
  # Use the same iteration number as the timeline CSV for the result filename.
  $controlVarsIteration = if ($null -eq $script:RunIteration) { 0 } else { [int]$script:RunIteration }
  & (Join-Path $PSScriptRoot "check-control-vars.ps1") `
    -Iteration $controlVarsIteration `
    -InventoryPath $inventoryPath `
    -OutDir $script:OutDirFull `
    -SshUser $sshUser `
    -SshKeyFile $sshPrivateKeyFull `
    -RequiredTag $nodeTag `
    -ExperimentName $experimentName `
    -ExpectedMachineType $machineType `
    -ExpectedMinCpuPlatform $minCpuPlatform `
    -ExpectedNetworkTier "PREMIUM" `
    -ExpectedBootstrapRevision $bootstrapRevision `
    -ExpectedSourceImage $resolvedSourceImage

  Write-ProvisioningSummary -Status "SUCCESS"
  Release-RunResultClaim
  Write-StageNotice -Message @(
    "[SUCCESS] $networkModeLabel provisioning is completed ($expectedNodeCount nodes).",
    "output: $script:OutDirFull"
  )
  $script:RunCompleted = $true
}
catch {
  # Record the failing step, cause and time. An iteration that failed after T0
  # keeps its completed points and FAILURE in the iteration CSV; a preparation
  # failure before T0 does not consume an iteration.
  $caught = $_
  $failedStep = $script:CurrentStep
  $script:RunStatus = "FAILED"
  Write-Host "FAILED at '$failedStep': $($caught.Exception.Message)" -ForegroundColor Red

  # If terraform apply itself fails, the normal T0 recording code is never
  # reached, but the exact apply start captured at the process boundary is kept.
  try {
    if ($null -eq (Get-TimelineEntry -Name "T0") -and
        $script:ApplyAttempted -and
        $null -ne $script:LastNativeTiming -and
        $script:LastNativeTiming.name -eq "terraform apply") {
      Add-Timeline -Name "T0" -Description "terraform apply started" -Data @{
        command = $script:LastNativeTiming.command
      } -TimestampUtc ([datetime]::Parse($script:LastNativeTiming.started_at)) -ElapsedMilliseconds ([double]$script:LastNativeTiming.started_elapsed_ms)
    }
    if ($null -ne (Get-TimelineEntry -Name "T0")) {
      Add-Timeline -Name "FAILURE" -Description "failed at step '$failedStep': $($caught.Exception.Message)"
    }
  }
  catch {
    Write-Warning "Failed to persist the failure timeline before cleanup: $($_.Exception.Message)"
  }

  # Written first so the original cause survives a slow or failing destroy.
  $failure = [pscustomobject]@{
    failed_step    = $failedStep
    error          = $caught.Exception.Message
    timestamp      = (Get-Date).ToUniversalTime().ToString("o")
    cleanup_status = if (-not $script:ApplyAttempted) { "NOT_RUN" } else { "PENDING" }
    cleanup_error  = $null
  }
  try {
    ConvertTo-Json -InputObject $failure -Depth 8 | Set-Content -Encoding UTF8 -Path $failureReportPath
    Write-ProvisioningSummary -Status "FAILED" -Failure $failure
  }
  catch {
    Write-Warning "Failed to persist the preliminary failure report: $($_.Exception.Message)"
  }

  if ($script:ApplyAttempted) {
    $failure.cleanup_status = "RUNNING"
    Write-Host "Failure cleanup: destroying the $networkModeLabel experiment resources..."
    try {
      & (Join-Path $PSScriptRoot "destroy.ps1") -Mode $NetworkMode `
        -TfDir $TfDirFull `
        -VarFile $VarFileFull `
        -OutDir (Join-Path $script:OutDirFull "auto-destroy")
      $failure.cleanup_status = "SUCCESS"
      Write-Host "Failure cleanup completed and deletion was verified."
    }
    catch {
      $failure.cleanup_status = "FAILED"
      $failure.cleanup_error = $_.Exception.Message
      Write-Host "Failure cleanup also failed: $($failure.cleanup_error)" -ForegroundColor Red
    }
  }

  try {
    ConvertTo-Json -InputObject $failure -Depth 8 | Set-Content -Encoding UTF8 -Path $failureReportPath
    Write-ProvisioningSummary -Status "FAILED" -Failure $failure
  }
  catch {
    Write-Warning "Failed to persist failure report: $($_.Exception.Message)"
  }
  Release-RunResultClaim
  # Failure handling is done, so the finally safety net must not interfere.
  $script:RunCompleted = $true
  throw $caught
}
finally {
  # Safety net for an abnormal abort such as Ctrl+C. The normal success and
  # failure paths set RunCompleted, so nothing happens here for them.
  # Right after Ctrl+C the PowerShell pipeline is stopping: console output is
  # suppressed and complex cmdlets are unreliable inside this block, so destroy
  # is delegated to a separate PowerShell process (new window). The initial 5s
  # wait gives the terraform process, which also received Ctrl+C, time to
  # settle its state and exit.
  if (-not $script:RunCompleted -and $script:ApplyStarted) {
    $interruptDestroyScript = Join-Path $PSScriptRoot "destroy.ps1"
    $interruptDestroyOut = Join-Path $script:OutDirFull "interrupt-destroy"
    $interruptCommand = "Start-Sleep -Seconds 5; & '$interruptDestroyScript' -Mode '$NetworkMode' -TfDir '$TfDirFull' -VarFile '$VarFileFull' -OutDir '$interruptDestroyOut'; Read-Host 'Interrupt destroy finished. Press Enter to close'"
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $interruptCommand
    ) | Out-Null
  }
}
