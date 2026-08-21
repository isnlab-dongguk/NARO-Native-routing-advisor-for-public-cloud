Set-StrictMode -Version Latest

# ============================================================================
# exp3-common.ps1 - shared library for experiment 3 (route convergence time)
#
# Dot-sourced by exp3-static.ps1 and exp3-dynamic.ps1. provision.ps1 runs its
# provisioning body the moment it is loaded and cannot be reused directly, so
# the Terraform/gcloud/SSH helpers experiment 3 needs live here in a reduced
# form (the Exp3 prefix avoids name collisions).
#
# Measurement model (hybrid)
#   - The Benchmark pod (benchmark-pod on *-bench-0) created by the experiment 2
#     create profile sends continuous TCP probes to the Server pod IP/port
#     (server-pod on *-worker-0).
#   - The prober runs inside the Benchmark pod and logs the start and end of
#     every probe as epoch ms of the pod (= bench VM) clock.
#   - The re-advertisement gcloud task of the measured window (T0->T1) runs on
#     the control plane VM and records T0/T1 with the CP VM clock
#     (date +%s%3N). CP and bench VM share the same GCP NTP source (usually
#     below 1 ms), so those values compare directly with the prober log (T2).
#     Neither the Windows clock nor the internet path enters the measurement.
#   - The Windows clock is used only for non-measured boundaries such as the
#     teardown; its offset to the bench VM is estimated with an SSH ping-pong
#     (shortest round trip sample).
#   - T2 is the end of the first OK probe after T0 in the prober log. The
#     convergence time T2-T0 is computed from VM clock timestamps, so a slow
#     log poll on the Windows side does not reduce accuracy.
# ============================================================================

$script:Exp3ExperimentLabel = "exp3"
$script:Exp3BenchPodName = "benchmark-pod"
$script:Exp3ServerPodName = "server-pod"
$script:Exp3BenchContainer = "bench"
$script:Exp3ServerContainer = "iperf3"
$script:Exp3PodProbeScript = "/tmp/exp3_probe.py"
$script:Exp3PodProbeLog = "/tmp/exp3_probe.log"
$script:Exp3PodProbePid = "/tmp/exp3_probe.pid"
$script:Exp3PodProbeOut = "/tmp/exp3_probe.out"
$script:Exp3PodListenerPid = "/tmp/exp3_listener.pid"
$script:Exp3PodListenerOut = "/tmp/exp3_listener.out"
$script:Exp3GcloudCallIndex = 0

# A non-interactive SSH (base64|bash) does not read /etc/profile.d, so the
# kubeconfig is named explicitly: prefer the copy kubeadm init placed in the
# ssh_user home, else fall back to the shared kubeconfig provisioning exposed.
$script:Exp3KubeconfigPreamble = @'
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if [ ! -r "$KUBECONFIG" ]; then
  export KUBECONFIG=/etc/kubernetes/admin-shared.conf
fi
'@

function Assert-Exp3Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Write-Exp3Banner {
  param(
    [string[]]$Message,
    [System.ConsoleColor]$Color = [System.ConsoleColor]::Cyan
  )
  $line = "".PadRight(74, "=")
  Write-Host $line -ForegroundColor $Color
  foreach ($text in $Message) {
    Write-Host $text -ForegroundColor $Color
  }
  Write-Host $line -ForegroundColor $Color
}

# -- Time base ---------------------------------------------------------------
# The Windows epoch is built from an epoch-ms anchor taken at start plus a
# monotonic stopwatch, so an NTP correction mid-run cannot shift measurements.

function Initialize-Exp3Clock {
  $script:Exp3Clock = [System.Diagnostics.Stopwatch]::StartNew()
  $script:Exp3EpochAnchorMs = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) - $script:Exp3Clock.Elapsed.TotalMilliseconds
}

function Get-Exp3WinEpochMs {
  return $script:Exp3EpochAnchorMs + $script:Exp3Clock.Elapsed.TotalMilliseconds
}

function ConvertTo-Exp3UtcIso {
  # Format epoch ms (Windows or VM axis) as an ISO UTC string.
  param([double]$EpochMs)
  return [DateTimeOffset]::FromUnixTimeMilliseconds([long][math]::Round($EpochMs)).UtcDateTime.ToString("o")
}

function ConvertTo-Exp3VmMs {
  # Windows epoch ms -> bench VM (= pod) epoch ms
  param([object]$Ctx, [double]$WinEpochMs)
  return $WinEpochMs + [double]$Ctx.ClockOffsetMs
}

function ConvertFrom-Exp3VmMs {
  # bench VM (= pod) epoch ms -> Windows epoch ms
  param([object]$Ctx, [double]$VmEpochMs)
  return $VmEpochMs - [double]$Ctx.ClockOffsetMs
}

# -- Paths / Terraform / tfvars ----------------------------------------------

function Resolve-Exp3WorkspacePath {
  param([string]$Path, [string]$BasePath)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return (Resolve-Path -LiteralPath $Path).Path
  }
  return (Resolve-Path -LiteralPath (Join-Path $BasePath $Path)).Path
}

function Join-Exp3WorkspacePath {
  param([string]$Path, [string]$BasePath)
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    $Path
  }
  else {
    Join-Path $BasePath $Path
  }
  return [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-Exp3TfvarsPath {
  # terraform.tfvars holds per-user values and is not shipped, so a missing file
  # names the template to copy instead of raising a bare path error.
  param([string]$Path, [string]$BasePath)
  $full = Join-Exp3WorkspacePath -Path $Path -BasePath $BasePath
  if (Test-Path -LiteralPath $full -PathType Leaf) {
    return (Resolve-Path -LiteralPath $full).Path
  }
  if (Test-Path -LiteralPath "$full.example" -PathType Leaf) {
    throw "terraform.tfvars not found: $full`nCopy the template next to it and fill it in:`n  copy `"$full.example`" `"$full`""
  }
  throw "terraform.tfvars not found: $full"
}

function Get-Exp3TfVarString {
  param([string]$Path, [string]$Name)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $pattern = "^\s*$([regex]::Escape($Name))\s*=\s*`"([^`"]+)`""
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $pattern) {
      return $Matches[1]
    }
  }
  return $null
}

function Get-Exp3TerraformOutputRaw {
  # terraform 'output -raw' can warn and still exit 0 with an empty string when
  # the output does not exist (empty state). '-json <name>' reliably exits 1, so
  # even a single output is read with -json.
  param([string]$TfDirFull, [string]$Name)
  $value = & terraform -chdir="$TfDirFull" output -json $Name
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read terraform output '$Name' from $TfDirFull. Run this against a non-empty Terraform state, i.e. after experiment 1 provisioning finished."
  }
  $text = [string]((([string]($value | Out-String)).Trim()) | ConvertFrom-Json)
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Terraform output '$Name' is empty in $TfDirFull."
  }
  return $text.Trim()
}

function Get-Exp3TerraformOutputJson {
  param([string]$TfDirFull, [string]$Name)
  $value = & terraform -chdir="$TfDirFull" output -json $Name
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read terraform output '$Name' from $TfDirFull."
  }
  return (($value | Out-String) | ConvertFrom-Json)
}

# -- gcloud ------------------------------------------------------------------

function Invoke-Exp3Gcloud {
  # Runs one gcloud command and returns the Windows epoch ms timing captured at
  # the native process boundary. The T0/T1 boundaries of the measured
  # re-advertisement use these values directly.
  param(
    [object]$Ctx,
    [string[]]$Arguments,
    [string]$Name
  )

  $script:Exp3GcloudCallIndex++
  $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-')
  $logPath = $null
  if ($null -ne $Ctx -and $null -ne $Ctx.PSObject.Properties["RawDir"] -and
      -not [string]::IsNullOrWhiteSpace([string]$Ctx.RawDir)) {
    $logPath = Join-Path $Ctx.RawDir ("gcloud-{0:d3}-{1}.log" -f $script:Exp3GcloudCallIndex, $safeName)
  }

  $startedWinMs = Get-Exp3WinEpochMs
  $output = @()
  $exitCode = -1
  try {
    # On PS 5.1 redirecting native stderr while EAP=Stop can promote a single
    # stderr line to a NativeCommandError, so it is lowered for the call only.
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = $null
    $output = @(& gcloud @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($null -ne $global:LASTEXITCODE) {
      $exitCode = [int]$global:LASTEXITCODE
    }
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  $endedWinMs = Get-Exp3WinEpochMs

  if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    ($output -join [Environment]::NewLine) | Set-Content -Encoding UTF8 -Path $logPath
  }
  if ($exitCode -ne 0) {
    $tail = (@($output | Select-Object -Last 25) -join [Environment]::NewLine)
    throw "gcloud command failed (exit $exitCode): gcloud $($Arguments -join ' ')`n$tail"
  }

  return [pscustomobject]@{
    name            = $Name
    command         = "gcloud $($Arguments -join ' ')"
    started_win_ms  = $startedWinMs
    ended_win_ms    = $endedWinMs
    started_utc     = ConvertTo-Exp3UtcIso -EpochMs $startedWinMs
    ended_utc       = ConvertTo-Exp3UtcIso -EpochMs $endedWinMs
    duration_ms     = [math]::Round($endedWinMs - $startedWinMs, 3)
    exit_code       = $exitCode
    log_path        = $logPath
  }
}

function Get-Exp3GcloudJson {
  param([string[]]$Arguments)

  $output = @()
  $exitCode = -1
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& gcloud @Arguments --format=json --quiet)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($exitCode -ne 0) {
    throw "gcloud query failed: gcloud $($Arguments -join ' ')"
  }
  $json = [string]($output | Out-String)
  if ([string]::IsNullOrWhiteSpace($json)) {
    return $null
  }
  return ($json | ConvertFrom-Json)
}

function Get-Exp3ResourceMapByName {
  param([string[]]$Arguments)

  $items = @(Get-Exp3GcloudJson -Arguments $Arguments)
  $map = @{}
  foreach ($item in $items) {
    if ($null -eq $item) {
      continue
    }
    $name = [string]$item.name
    if ([string]::IsNullOrWhiteSpace($name)) {
      continue
    }
    if ($map.ContainsKey($name)) {
      throw "Duplicate resource name '$name' returned by: gcloud $($Arguments -join ' ')"
    }
    $map[$name] = $item
  }
  return $map
}

function Get-Exp3PropertyArray {
  param([object]$Object, [string]$Name)
  if ($null -eq $Object) {
    return @()
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return @()
  }
  return @($property.Value)
}

# -- SSH ---------------------------------------------------------------------

function Get-Exp3SshTarget {
  param([object]$Node, [string]$SshUser)
  if ([string]::IsNullOrWhiteSpace($SshUser)) {
    throw "ssh_user must not be empty."
  }
  $address = [string]$Node.external_ip
  if ([string]::IsNullOrWhiteSpace($address)) {
    throw "Node $($Node.node_name) has no external IP."
  }
  return "$SshUser@$address"
}

function Get-Exp3SshCommonArguments {
  param([string]$SshKeyFile)
  $arguments = @(
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "LogLevel=ERROR"
  )
  if (-not [string]::IsNullOrWhiteSpace($SshKeyFile)) {
    $arguments += @("-i", $SshKeyFile)
  }
  return $arguments
}

function Get-Exp3RemoteBashInvocation {
  # base64 wrapper so PS 5.1 native quoting cannot corrupt a multi-line or
  # nested-quote command (same pattern as provision.ps1).
  param([string]$Command)
  $normalized = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
  return "echo $encoded | base64 -d | bash"
}

function Invoke-Exp3SshCapture {
  param([object]$Ctx, [object]$Node, [string]$Command)

  $sshArguments = @("-n") + (Get-Exp3SshCommonArguments -SshKeyFile $Ctx.SshKeyFile)
  $sshArguments += @(
    (Get-Exp3SshTarget -Node $Node -SshUser $Ctx.SshUser),
    (Get-Exp3RemoteBashInvocation -Command $Command)
  )
  $output = & ssh @sshArguments
  if ($LASTEXITCODE -ne 0) {
    $text = (($output | Out-String)).Trim()
    throw "ssh command failed on $($Node.node_name) (exit $LASTEXITCODE): $text"
  }
  return ($output | Out-String)
}

function Invoke-Exp3Kubectl {
  # Runs a bash script on the control plane node with the kubeconfig preamble.
  param([object]$Ctx, [string]$Script)
  $full = "set -euo pipefail`n$($script:Exp3KubeconfigPreamble)`n$Script"
  return Invoke-Exp3SshCapture -Ctx $Ctx -Node $Ctx.ControlPlane -Command $full
}

function Assert-Exp3SafeBashArgument {
  # Checks the value can be embedded safely as a single-quoted bash argument.
  param([string]$Value, [string]$What)
  if ($Value -match "['`r`n]") {
    throw "$What contains a character that cannot be passed as a single-quoted bash argument: $Value"
  }
}

function ConvertTo-Exp3BashSingleQuoted {
  param([string]$Value)
  Assert-Exp3SafeBashArgument -Value $Value -What "bash argument"
  return "'" + $Value + "'"
}

function ConvertFrom-Exp3TimedTaskOutput {
  # Parses the EXP3_T0 / EXP3_CMD / EXP3_T1 lines out of the CP timed task
  # output. Every timestamp is epoch ms on the CP VM clock.
  param([string]$Output, [int]$ExpectedCommandCount)

  $t0Values = @()
  $t1Values = @()
  $commands = @()
  foreach ($line in ($Output -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^EXP3_T0 (\d{12,14})$') {
      $t0Values += [double][long]$Matches[1]
    }
    elseif ($trimmed -match '^EXP3_T1 (\d{12,14})$') {
      $t1Values += [double][long]$Matches[1]
    }
    elseif ($trimmed -match '^EXP3_CMD (\S+) (\d{12,14}) (\d{12,14})$') {
      $commands += [pscustomobject]@{
        name          = $Matches[1]
        started_vm_ms = [double][long]$Matches[2]
        ended_vm_ms   = [double][long]$Matches[3]
        duration_ms   = [math]::Round([double][long]$Matches[3] - [double][long]$Matches[2], 3)
      }
    }
  }

  if ($t0Values.Count -ne 1 -or $t1Values.Count -ne 1) {
    throw "The timed task output must contain EXP3_T0/EXP3_T1 exactly once each (T0=$($t0Values.Count), T1=$($t1Values.Count))."
  }
  if ($commands.Count -ne $ExpectedCommandCount) {
    throw "Timed task command count differs from the expected value ($ExpectedCommandCount), found $($commands.Count)."
  }
  $t0 = $t0Values[0]
  $t1 = $t1Values[0]
  if ($t1 -lt $t0) {
    throw "Timed task T1 is earlier than T0."
  }
  # Stages can run in parallel, so no order is enforced between commands: each
  # one only has to sit inside the T0~T1 window and keep start <= end.
  foreach ($command in $commands) {
    if ([double]$command.started_vm_ms -lt $t0 -or
        [double]$command.ended_vm_ms -gt $t1 -or
        [double]$command.ended_vm_ms -lt [double]$command.started_vm_ms) {
      throw "Timed task command '$($command.name)' has timestamps outside the T0~T1 range or in the wrong order."
    }
  }

  return [pscustomobject]@{
    t0_vm_ms    = $t0
    t1_vm_ms    = $t1
    duration_ms = [math]::Round($t1 - $t0, 3)
    commands    = @($commands | Sort-Object started_vm_ms, ended_vm_ms)
  }
}

function Invoke-Exp3TimedControlPlaneGcloud {
  # Runs the gcloud commands under measurement as a single bash script on the
  # control plane VM and returns T0/T1 plus per-command boundaries recorded with
  # the CP VM clock (date +%s%3N) - the core of the hybrid measurement. CP and
  # bench VM share the same GCP NTP source, so the returned T0/T1 live on the
  # same time axis as the prober log (T2).
  #
  # Stages: an array of arrays. The outer array runs sequentially; commands
  # inside one stage run concurrently as background jobs. Each command is
  # @{ name = <string>; arguments = <string[]> } (arguments without "gcloud").
  # The rule is "the highest concurrency the method allows": the two N-Static
  # routes are independent resources and share one stage, while N-Dynamic is
  # split into sequential stages because add-bgp-peer depends on the spoke
  # registration and because a Cloud Router modification is read-modify-write
  # (concurrent edits risk losing a peer).
  # Every EXP3_CMD line is a single write below PIPE_BUF (4KB), so lines never
  # interleave even in parallel, and gcloud output is isolated per command log.
  param(
    [object]$Ctx,
    [string]$Name,
    [object[]]$Stages
  )

  if ([string]::IsNullOrWhiteSpace([string]$Ctx.CpGcloudPath)) {
    throw "The control plane gcloud preflight has not completed."
  }
  $totalCommands = 0
  foreach ($stage in @($Stages)) {
    $totalCommands += @($stage).Count
  }
  if ($totalCommands -lt 1) {
    throw "Timed task '$Name' has no command to run."
  }

  $builder = New-Object System.Text.StringBuilder
  $null = $builder.AppendLine("set -euo pipefail")
  $null = $builder.AppendLine("GCLOUD=" + (ConvertTo-Exp3BashSingleQuoted -Value ([string]$Ctx.CpGcloudPath)))
  $null = $builder.AppendLine('rm -f /tmp/exp3-task-cmd-*.log')
  $null = $builder.AppendLine('FAIL=0')
  $null = $builder.AppendLine(@'
run_one() {
  local name="$1" logfile="$2"
  shift 2
  local start end rc
  start=$(date +%s%3N)
  if "$GCLOUD" "$@" >"$logfile" 2>&1; then rc=0; else rc=$?; fi
  end=$(date +%s%3N)
  echo "EXP3_CMD $name $start $end"
  return "$rc"
}
'@)
  $null = $builder.AppendLine('echo "EXP3_T0 $(date +%s%3N)"')

  # Per-command essential flag (default true). essential=false marks a
  # redundancy/auxiliary command that is not a connectivity prerequisite, so the
  # driver excludes it from the T0 anchor.
  $essentialByName = @{}
  $commandIndex = 0
  foreach ($stage in @($Stages)) {
    $stageCommands = @($stage)
    if ($stageCommands.Count -lt 1) {
      continue
    }
    $invocations = @()
    foreach ($command in $stageCommands) {
      $commandIndex++
      $commandName = ([string]$command.name -replace '[^a-zA-Z0-9._-]', '-')
      if ([string]::IsNullOrWhiteSpace($commandName)) {
        $commandName = "command-$commandIndex"
      }
      if ($essentialByName.ContainsKey($commandName)) {
        throw "Duplicate timed task command name: $commandName"
      }
      $isEssential = $true
      if ($command -is [System.Collections.IDictionary]) {
        if ($command.Contains("essential")) {
          $isEssential = [bool]$command["essential"]
        }
      }
      elseif ($null -ne $command.PSObject.Properties["essential"]) {
        $isEssential = [bool]$command.essential
      }
      $essentialByName[$commandName] = $isEssential
      $quotedArguments = @(
        foreach ($argument in @($command.arguments)) {
          ConvertTo-Exp3BashSingleQuoted -Value ([string]$argument)
        }
      )
      $logFile = "/tmp/exp3-task-cmd-$commandIndex.log"
      $invocations += ("run_one " + (ConvertTo-Exp3BashSingleQuoted -Value $commandName) + " " +
        (ConvertTo-Exp3BashSingleQuoted -Value $logFile) + " " + ($quotedArguments -join ' '))
    }

      # A failed stage stops the following stages (dependency protection).
    $null = $builder.AppendLine('if [ "$FAIL" -eq 0 ]; then')
    if ($invocations.Count -eq 1) {
      $null = $builder.AppendLine("  $($invocations[0]) || FAIL=1")
    }
    else {
      $null = $builder.AppendLine('  PIDS=()')
      foreach ($invocation in $invocations) {
        $null = $builder.AppendLine("  $invocation & PIDS+=(`$!)")
      }
      $null = $builder.AppendLine('  for pid in "${PIDS[@]}"; do wait "$pid" || FAIL=1; done')
    }
    $null = $builder.AppendLine('fi')
  }

  $null = $builder.AppendLine('echo "EXP3_T1 $(date +%s%3N)"')
  $null = $builder.AppendLine(@'
if [ "$FAIL" -ne 0 ]; then
  for logfile in /tmp/exp3-task-cmd-*.log; do
    [ -f "$logfile" ] || continue
    echo "----- $logfile"
    tail -n 20 "$logfile"
  done
  exit 1
fi
rm -f /tmp/exp3-task-cmd-*.log
'@)

  $output = Invoke-Exp3SshCapture -Ctx $Ctx -Node $Ctx.ControlPlane -Command $builder.ToString()
  if ($null -ne $Ctx.PSObject.Properties["RawDir"] -and
      -not [string]::IsNullOrWhiteSpace([string]$Ctx.RawDir)) {
    $script:Exp3GcloudCallIndex++
    $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-')
    $output | Set-Content -Encoding UTF8 -Path (Join-Path $Ctx.RawDir ("cp-timed-{0:d3}-{1}.log" -f $script:Exp3GcloudCallIndex, $safeName))
  }
  $result = ConvertFrom-Exp3TimedTaskOutput -Output $output -ExpectedCommandCount $totalCommands
  foreach ($parsedCommand in @($result.commands)) {
    $isEssential = $true
    if ($essentialByName.ContainsKey([string]$parsedCommand.name)) {
      $isEssential = [bool]$essentialByName[[string]$parsedCommand.name]
    }
    $parsedCommand | Add-Member -NotePropertyName essential -NotePropertyValue $isEssential -Force
  }
  return $result
}

function Assert-Exp3ControlPlaneGcloudReady {
  # Preflight for the hybrid measurement: gcloud exists on the CP (including a
  # snap install), the VM service account credentials are present, and a Compute
  # API call works (scope + IAM). The first run also warms the snap/config cache
  # here so it stays out of the measured window.
  param([object]$Ctx)

  $probeScript = @'
set -u
GCLOUD="$(command -v gcloud 2>/dev/null || true)"
if [ -z "$GCLOUD" ]; then
  for candidate in /snap/bin/gcloud /usr/bin/gcloud /usr/local/bin/gcloud; do
    if [ -x "$candidate" ]; then GCLOUD="$candidate"; break; fi
  done
fi
if [ -z "$GCLOUD" ]; then echo "EXP3_NO_GCLOUD"; exit 0; fi
echo "EXP3_GCLOUD_PATH $GCLOUD"
ACTIVE="$("$GCLOUD" auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)"
if [ -z "$ACTIVE" ]; then echo "EXP3_NO_CREDENTIAL"; exit 0; fi
echo "EXP3_GCLOUD_ACCOUNT $ACTIVE"
if ! "$GCLOUD" compute routes list --project '__PROJECT__' --limit 1 --format='value(name)' >/dev/null 2>/tmp/exp3-gcloud-probe.err; then
  echo "EXP3_NO_COMPUTE_ACCESS"
  head -n 5 /tmp/exp3-gcloud-probe.err 2>/dev/null || true
  rm -f /tmp/exp3-gcloud-probe.err
  exit 0
fi
rm -f /tmp/exp3-gcloud-probe.err
echo "EXP3_GCLOUD_READY"
'@
  $probeScript = $probeScript.Replace("__PROJECT__", $Ctx.ProjectId)
  $output = Invoke-Exp3SshCapture -Ctx $Ctx -Node $Ctx.ControlPlane -Command $probeScript

  if ($output -match "EXP3_NO_GCLOUD") {
    throw "gcloud is missing on the control plane. Ubuntu GCE images usually ship it as the google-cloud-cli snap; if it is absent, run 'sudo snap install google-cloud-cli --classic' on the CP and retry."
  }
  if ($output -match "EXP3_NO_CREDENTIAL") {
    throw "The control plane VM has no service account credentials. The cluster must have been provisioned with service_account_email set in infra/<method>/terraform.tfvars (an older cluster has to be reprovisioned)."
  }
  if ($output -match "EXP3_NO_COMPUTE_ACCESS") {
    throw "The control plane service account cannot call the Compute API (missing access scope or IAM role). See the IAM role step in README-exp3.md. Details: $($output.Trim())"
  }
  if ($output -notmatch "EXP3_GCLOUD_READY") {
    throw "Could not interpret the control plane gcloud preflight response: $($output.Trim())"
  }
  $pathMatch = [regex]::Match($output, 'EXP3_GCLOUD_PATH (\S+)')
  $accountMatch = [regex]::Match($output, 'EXP3_GCLOUD_ACCOUNT (\S+)')
  if (-not $pathMatch.Success -or -not $accountMatch.Success) {
    throw "Could not read the path/account from the control plane gcloud preflight: $($output.Trim())"
  }
  $Ctx.CpGcloudPath = $pathMatch.Groups[1].Value
  $Ctx.CpGcloudAccount = $accountMatch.Groups[1].Value
  Write-Host "    CP gcloud: $($Ctx.CpGcloudPath) (account: $($Ctx.CpGcloudAccount))"
}

function ConvertTo-Exp3ProcessArguments {
  # Quoting for System.Diagnostics.ProcessStartInfo.Arguments (single string).
  param([string[]]$Arguments)
  $quoted = foreach ($argument in $Arguments) {
    if ($argument -match '[\s"]') {
      '"' + ($argument -replace '(\\*)"', '$1$1\"') + '"'
    }
    else {
      $argument
    }
  }
  return ($quoted -join ' ')
}

function Measure-Exp3ClockOffset {
  # Estimates the offset (vm - win) between the given VM clock and the Windows
  # clock. A line ping-pong over a persistent SSH session is repeated and the
  # shortest round trip wins. Uncertainty is at least minRTT/2 (usually tens of
  # ms once the connection is established).
  param([object]$Ctx, [object]$Node, [int]$SampleCount = 10)

  $pingPongScript = @'
trap 'rm -f /tmp/exp3-pingpong.sh' EXIT
while IFS= read -r line; do
  # WinPS 5.1 can write a UTF-8 preamble to redirected stdin during
  # Process.Start, before the caller can replace its StreamWriter. Keep the
  # wire protocol ASCII by removing that first-line preamble and any CR.
  line="${line#$'\xEF\xBB\xBF'}"
  line="${line%$'\r'}"
  printf 'PONG %s %s\n' "$line" "$(date +%s%3N)"
done
'@
  $normalized = $pingPongScript.Replace("`r`n", "`n").Replace("`r", "`n")
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
  # stdin must stay on the SSH channel, so the base64|bash wrapper is not used.
  $remoteCommand = "echo $encoded | base64 -d > /tmp/exp3-pingpong.sh && exec bash /tmp/exp3-pingpong.sh"

  $sshArguments = (Get-Exp3SshCommonArguments -SshKeyFile $Ctx.SshKeyFile) + @(
    (Get-Exp3SshTarget -Node $Node -SshUser $Ctx.SshUser),
    $remoteCommand
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = "ssh"
  $startInfo.Arguments = ConvertTo-Exp3ProcessArguments -Arguments $sshArguments
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $startInfo.StandardOutputEncoding = $utf8NoBom
  $startInfo.StandardErrorEncoding = $utf8NoBom

  $process = [System.Diagnostics.Process]::Start($startInfo)
  $samples = @()
  $stdinWriter = $null
  try {
    # Drain stderr asynchronously to avoid a pipe buffer deadlock (unused).
    $null = $process.StandardError.ReadToEndAsync()
    # Careful (PS 5.1 / .NET Framework): Process.Start can make its internal
    # StandardInput writer emit a UTF-8 preamble before BaseStream is exposed.
    # The remote loop strips that unavoidable first preamble. This replacement
    # writer keeps subsequent tokens BOM-free and uses LF instead of CRLF.
    # StandardOutputEncoding above ensures any residual preamble is decoded as
    # U+FEFF, which the parser below removes before matching.
    $stdinWriter = New-Object System.IO.StreamWriter(
      $process.StandardInput.BaseStream, ([System.Text.UTF8Encoding]::new($false)))
    $stdinWriter.AutoFlush = $true
    $stdinWriter.NewLine = "`n"

    for ($index = 1; $index -le $SampleCount; $index++) {
      $token = "S$index"
      $sentWinMs = Get-Exp3WinEpochMs
      $stdinWriter.WriteLine($token)
      $readTask = $process.StandardOutput.ReadLineAsync()
      $waitMs = if ($index -eq 1) { 45000 } else { 10000 }
      if (-not $readTask.Wait($waitMs)) {
        throw "Clock ping-pong timed out waiting for sample $index from $($Node.node_name)."
      }
      $receivedWinMs = Get-Exp3WinEpochMs
      $line = $readTask.Result
      if ($null -eq $line) {
        throw "Clock ping-pong stream closed unexpectedly at sample $index."
      }
      # Defensively strip any leftover zero-width BOM or newline.
      $line = (($line -replace [string][char]0xFEFF, '')).Trim()
      $match = [regex]::Match($line, "^PONG $token (\d{12,14})$")
      if (-not $match.Success) {
        throw "Unexpected clock ping-pong reply: $line"
      }
      $vmMs = [double][long]$match.Groups[1].Value
      $rttMs = $receivedWinMs - $sentWinMs
      $samples += [pscustomobject]@{
        token           = $token
        sent_win_ms     = [math]::Round($sentWinMs, 3)
        received_win_ms = [math]::Round($receivedWinMs, 3)
        rtt_ms          = [math]::Round($rttMs, 3)
        vm_ms           = $vmMs
        offset_ms       = [math]::Round($vmMs - ($sentWinMs + $rttMs / 2.0), 3)
      }
    }
  }
  finally {
    try { if ($null -ne $stdinWriter) { $stdinWriter.Close() } } catch { }
    try { $process.StandardInput.Close() } catch { }
    if (-not $process.WaitForExit(5000)) {
      try { $process.Kill() } catch { }
    }
    $process.Dispose()
  }

  if (@($samples).Count -lt 3) {
    throw "Clock offset estimation collected fewer than 3 samples."
  }
  $best = @($samples | Sort-Object rtt_ms)[0]
  return [pscustomobject]@{
    offset_ms = [double]$best.offset_ms
    rtt_ms    = [double]$best.rtt_ms
    samples   = $samples
  }
}

# -- Other checks ------------------------------------------------------------

function Test-Exp3Ipv4InCidr {
  param([string]$Ip, [string]$Cidr)

  $parts = $Cidr -split "/"
  if ($parts.Count -ne 2) {
    throw "Invalid CIDR: $Cidr"
  }
  $prefixLength = [int]$parts[1]
  $ipBytes = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
  $netBytes = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
  [array]::Reverse($ipBytes)
  [array]::Reverse($netBytes)
  $ipValue = [BitConverter]::ToUInt32($ipBytes, 0)
  $netValue = [BitConverter]::ToUInt32($netBytes, 0)
  $mask = if ($prefixLength -eq 0) {
    [uint32]0
  }
  else {
    # PS 5.1 parses the hex literal 0xFFFFFFFF as Int32 (-1), so use decimal.
    [uint32]((([long]4294967295) -shl (32 - $prefixLength)) -band ([long]4294967295))
  }
  return (($ipValue -band $mask) -eq ($netValue -band $mask))
}

function Read-Exp3T4State {
  # The T4 ownership marker proves the resources this experiment touches belong
  # to this experiment. Without it, withdrawing/recreating an advertisement
  # could hit an unrelated resource, so it is mandatory.
  param(
    [string]$TfDirFull,
    [string]$Method,
    [string]$ProjectId,
    [string]$ResourcePrefix
  )

  $path = Join-Path $TfDirFull ".native-routing-t4-$Method.json"
  if (-not (Test-Path -LiteralPath $path)) {
    throw "T4 ownership marker not found: $path. Experiment 3 can only run on a cluster where the method-specific T4 task of experiment 1 completed."
  }
  $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if ([int]$state.schema_version -ne 1 -or
      [string]$state.method -ne $Method -or
      [string]$state.project_id -ne $ProjectId -or
      [string]$state.resource_prefix -ne $ResourcePrefix) {
    throw "T4 ownership state does not match this run: $path"
  }
  return $state
}

# -- Result files ------------------------------------------------------------

function Initialize-Exp3ResultFile {
  # Same iteration filename rule as experiment 1:
  # {method}_{nodes}_exp3_iter{iteration}.csv. The highest completed iteration
  # plus one is chosen automatically and claimed by creating the empty file.
  param([string]$OutDirFull, [string]$Method, [int]$NodeCount)

  $prefix = "{0}_{1}_{2}_" -f $Method.ToLowerInvariant(), $NodeCount, $script:Exp3ExperimentLabel
  $pattern = "^{0}iter(?<iteration>[1-9][0-9]*)\.csv$" -f [regex]::Escape($prefix)
  $highest = [long]0
  foreach ($file in @(Get-ChildItem -LiteralPath $OutDirFull -Force | Where-Object { -not $_.PSIsContainer })) {
    $match = [regex]::Match($file.Name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
      continue
    }
    $parsed = [long]0
    if ([long]::TryParse($match.Groups["iteration"].Value, [ref]$parsed) -and $parsed -gt $highest) {
      $highest = $parsed
    }
  }
  $iteration = [int]($highest + 1)
  $baseName = "{0}iter{1}" -f $prefix, $iteration
  $csvPath = Join-Path $OutDirFull "$baseName.csv"
  if (Test-Path -LiteralPath $csvPath) {
    throw "Result CSV already exists: $csvPath"
  }
  New-Item -ItemType File -Path $csvPath | Out-Null
  $rawDir = Join-Path (Join-Path $OutDirFull "raw") $baseName
  New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

  return [pscustomobject]@{
    iteration = $iteration
    base_name = $baseName
    csv_path  = $csvPath
    raw_dir   = $rawDir
  }
}

function New-Exp3ResultRow {
  param([object]$Ctx, [hashtable]$Values)

  $row = [ordered]@{
    record_type            = $null
    method                 = $Ctx.Method
    node_count             = $Ctx.NodeCount
    experiment             = $script:Exp3ExperimentLabel
    iteration              = $Ctx.Iteration
    repetition             = $null
    status                 = $null
    teardown_started_utc   = $null
    teardown_ended_utc     = $null
    teardown_ms            = $null
    loss_confirmed_utc     = $null
    loss_fail_count        = $null
    loss_span_ms           = $null
    t0_utc                 = $null
    t0_vm_unix_ms          = $null
    t1_utc                 = $null
    t1_vm_unix_ms          = $null
    t2_utc                 = $null
    t2_vm_unix_ms          = $null
    t0_to_t1_ms            = $null
    t1_to_t2_ms            = $null
    t0_to_t2_ms            = $null
    stable_ok              = $null
    clock_offset_ms        = $null
    clock_rtt_ms           = $null
    cp_bench_offset_est_ms = $null
    probe_port             = $Ctx.ProbePort
    probe_interval_seconds = $Ctx.ProbeIntervalSeconds
    probe_timeout_seconds  = $Ctx.ProbeTimeoutSeconds
    server_pod_ip          = $Ctx.ServerPodIp
    bench_pod_ip           = $Ctx.BenchPodIp
    notes                  = $null
  }
  foreach ($key in $Values.Keys) {
    if (-not $row.Contains($key)) {
      throw "Unknown result column: $key"
    }
    $row[$key] = $Values[$key]
  }
  return [pscustomobject]$row
}

function Save-Exp3Rows {
  param([object]$Ctx)
  if (@($script:Exp3Rows).Count -eq 0) {
    return
  }
  $temporaryPath = "$($Ctx.ResultCsvPath).tmp-$PID"
  try {
    @($script:Exp3Rows) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $temporaryPath
    Move-Item -LiteralPath $temporaryPath -Destination $Ctx.ResultCsvPath -Force
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }
}

# -- Context initialization --------------------------------------------------

function Initialize-Exp3Context {
  param(
    [ValidateSet("static", "dynamic", "cloud")]
    [string]$Method,
    # The repository root: every relative path (infra/, results/) is
    # resolved against it, so the tree can be copied anywhere and still runs.
    [string]$ScriptsRoot,
    [string]$TfDir,
    [string]$VarFile,
    [string]$OutDir,
    [string]$Namespace,
    [int]$ProbePort,
    [double]$ProbeIntervalSeconds,
    [double]$ProbeTimeoutSeconds,
    [bool]$RestoreOnly = $false
  )

  Assert-Exp3Command "terraform"
  Assert-Exp3Command "gcloud"
  Assert-Exp3Command "ssh"
  Initialize-Exp3Clock

  if ($Namespace -notmatch '^exp2-[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
    throw "Experiment 3 uses the pods in the exp2- namespace created by experiment 2: $Namespace"
  }
  if ($ProbePort -eq 10000 -or $ProbePort -eq 10001) {
    throw "ProbePort must not collide with the experiment 2 iperf3 (10000) / netserver (10001) ports."
  }

  $tfDirFull = Resolve-Exp3WorkspacePath -Path $TfDir -BasePath $ScriptsRoot
  if ([string]::IsNullOrWhiteSpace($VarFile)) {
    $VarFile = Join-Path $tfDirFull "terraform.tfvars"
  }
  $varFileFull = Resolve-Exp3TfvarsPath -Path $VarFile -BasePath $ScriptsRoot
  $outDirFull = Join-Exp3WorkspacePath -Path $OutDir -BasePath $ScriptsRoot
  New-Item -ItemType Directory -Force -Path $outDirFull | Out-Null

  Write-Host "==> reading Terraform outputs: $tfDirFull"
  $experimentName = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "experiment_name"
  if ($experimentName -ne $Method) {
    throw "Terraform experiment_name output '$experimentName' differs from method '$Method'. Check TfDir."
  }
  $projectId = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "project_id"
  $region = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "region"
  $sshUser = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "ssh_user"
  $sshKeyRaw = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "ssh_private_key_path"
  $resourcePrefix = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "resource_prefix"
  $clusterPodCidr = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "pod_cidr"
  $inventory = Get-Exp3TerraformOutputJson -TfDirFull $tfDirFull -Name "inventory"

  $sshKeyFile = if ([System.IO.Path]::IsPathRooted($sshKeyRaw)) {
    $sshKeyRaw
  }
  else {
    Join-Path $tfDirFull $sshKeyRaw
  }
  if (-not (Test-Path -LiteralPath $sshKeyFile -PathType Leaf)) {
    throw "SSH private key not found: $sshKeyFile"
  }

  $networkName = Get-Exp3TfVarString -Path $varFileFull -Name "network_name"
  $subnetworkName = Get-Exp3TfVarString -Path $varFileFull -Name "subnetwork_name"
  if ([string]::IsNullOrWhiteSpace($networkName) -or [string]::IsNullOrWhiteSpace($subnetworkName)) {
    throw "Could not read network_name/subnetwork_name from $varFileFull."
  }

  $inventoryNodes = @(
    $inventory.PSObject.Properties | ForEach-Object {
      $value = $_.Value
      [pscustomobject]@{
        node_name   = [string]$value.name
        role        = [string]$value.role
        role_index  = [int]$value.role_index
        zone        = [string]$value.zone
        private_ip  = [string]$value.private_ip
        external_ip = [string]$value.external_ip
      }
    }
  )

  Write-Host "==> verifying the T4 ownership marker"
  $t4State = Read-Exp3T4State -TfDirFull $tfDirFull -Method $Method -ProjectId $projectId -ResourcePrefix $resourcePrefix
  $rawMarkerNodes = @(Get-Exp3PropertyArray -Object $t4State -Name "nodes")
  if ($rawMarkerNodes.Count -ne $inventoryNodes.Count) {
    throw "T4 marker node count ($($rawMarkerNodes.Count)) differs from the Terraform inventory node count ($($inventoryNodes.Count)). The cluster changed after T4."
  }

  # Merge the marker (holds pod_cidr) with the inventory (current external IP).
  $markerNodes = @()
  foreach ($markerNode in $rawMarkerNodes) {
    $nodeName = [string]$markerNode.node_name
    $matched = @($inventoryNodes | Where-Object { $_.node_name -eq $nodeName })
    if ($matched.Count -ne 1) {
      throw "T4 marker node '$nodeName' is not in the Terraform inventory."
    }
    $inventoryNode = $matched[0]
    if ([string]$markerNode.private_ip -ne $inventoryNode.private_ip -or
        [string]$markerNode.zone -ne $inventoryNode.zone) {
      throw "private_ip/zone of node '$nodeName' differ between the T4 marker and the inventory."
    }
    if ([string]::IsNullOrWhiteSpace([string]$markerNode.pod_cidr)) {
      throw "T4 marker node '$nodeName' has no pod_cidr."
    }
    $markerNodes += [pscustomobject]@{
      node_name   = $nodeName
      role        = [string]$markerNode.role
      role_index  = [int]$markerNode.role_index
      zone        = $inventoryNode.zone
      private_ip  = $inventoryNode.private_ip
      external_ip = $inventoryNode.external_ip
      pod_cidr    = [string]$markerNode.pod_cidr
    }
  }

  $nodeCount = $markerNodes.Count
  if ($nodeCount -ne 4 -and $nodeCount -ne 8) {
    throw "Experiment 3 only runs on a 4-node or 8-node cluster (found $nodeCount)."
  }

  $benchMatches = @($markerNodes | Where-Object { $_.role -eq "benchmark" -and $_.role_index -eq 0 })
  $workerZeroMatches = @($markerNodes | Where-Object { $_.role -eq "worker" -and $_.role_index -eq 0 })
  $controlPlaneMatches = @($markerNodes | Where-Object { $_.role -eq "control-plane" })
  if ($benchMatches.Count -ne 1 -or $workerZeroMatches.Count -ne 1 -or $controlPlaneMatches.Count -ne 1) {
    throw "Could not find exactly one benchmark, worker-0 and control-plane node."
  }
  $benchNode = $benchMatches[0]
  $workerZeroNode = $workerZeroMatches[0]
  $controlPlane = $controlPlaneMatches[0]

  if ($benchNode.node_name -ne "$resourcePrefix-bench-0") {
    throw "Benchmark node name '$($benchNode.node_name)' does not follow the experiment 1 rule ($resourcePrefix-bench-0)."
  }
  if ($workerZeroNode.node_name -ne "$resourcePrefix-worker-0") {
    throw "worker-0 node name '$($workerZeroNode.node_name)' does not follow the experiment 1 rule ($resourcePrefix-worker-0)."
  }

  # Exactly these two nodes are withdrawn/re-advertised; the rest are untouched.
  $targetNodes = @($benchNode, $workerZeroNode)
  $otherNodes = @($markerNodes | Where-Object {
    $_.node_name -ne $benchNode.node_name -and $_.node_name -ne $workerZeroNode.node_name
  })

  $ctx = [pscustomobject]@{
    Method               = $Method
    ScriptsRoot          = $ScriptsRoot
    TfDirFull            = $tfDirFull
    VarFileFull          = $varFileFull
    OutDirFull           = $outDirFull
    ProjectId            = $projectId
    Region               = $region
    NetworkName          = $networkName
    SubnetworkName       = $subnetworkName
    ResourcePrefix       = $resourcePrefix
    ClusterPodCidr       = $clusterPodCidr
    SshUser              = $sshUser
    SshKeyFile           = $sshKeyFile
    NodeCount            = $nodeCount
    MarkerNodes          = $markerNodes
    TargetNodes          = $targetNodes
    OtherNodes           = $otherNodes
    ControlPlane         = $controlPlane
    BenchVm              = $benchNode
    WorkerZeroVm         = $workerZeroNode
    Namespace            = $Namespace
    ProbePort            = $ProbePort
    ProbeIntervalSeconds = $ProbeIntervalSeconds
    ProbeTimeoutSeconds  = $ProbeTimeoutSeconds
    ServerPodIp          = $null
    BenchPodIp           = $null
    ClockOffsetMs        = $null
    ClockRttMs           = $null
    CpBenchOffsetEstMs   = $null
    CpGcloudPath         = $null
    CpGcloudAccount      = $null
    Iteration            = $null
    ResultCsvPath        = $null
    RawDir               = $null
  }

  Write-Host "==> withdraw/re-advertise targets: $($benchNode.node_name) ($($benchNode.pod_cidr)), $($workerZeroNode.node_name) ($($workerZeroNode.pod_cidr))"
  Write-Host "==> left untouched: $(@($otherNodes | ForEach-Object { $_.node_name }) -join ', ')"

  if ($RestoreOnly) {
    return $ctx
  }

  Write-Host "==> verifying Kubernetes PodCIDRs and the experiment 2 pods"
  $clusterScript = @'
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.podCIDR}{"\n"}{end}' | sed 's/^/NODE /'
printf 'POD_SERVER %s\n' "$(kubectl -n __NS__ get pod __SERVER_POD__ -o jsonpath='{.spec.nodeName}|{.status.podIP}|{.spec.hostNetwork}|{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
printf 'POD_BENCH %s\n' "$(kubectl -n __NS__ get pod __BENCH_POD__ -o jsonpath='{.spec.nodeName}|{.status.podIP}|{.spec.hostNetwork}|{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
'@
  $clusterScript = $clusterScript.Replace("__NS__", $Namespace).
    Replace("__SERVER_POD__", $script:Exp3ServerPodName).
    Replace("__BENCH_POD__", $script:Exp3BenchPodName)
  $clusterOutput = Invoke-Exp3Kubectl -Ctx $ctx -Script $clusterScript

  $podCidrByNode = @{}
  $serverPodLine = $null
  $benchPodLine = $null
  foreach ($line in ($clusterOutput -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^NODE (\S+) (\S+)$') {
      $podCidrByNode[$Matches[1]] = $Matches[2]
    }
    elseif ($trimmed -match '^POD_SERVER (.+)$') {
      $serverPodLine = $Matches[1]
    }
    elseif ($trimmed -match '^POD_BENCH (.+)$') {
      $benchPodLine = $Matches[1]
    }
  }

  foreach ($node in $markerNodes) {
    if (-not $podCidrByNode.ContainsKey($node.node_name)) {
      throw "Node '$($node.node_name)' was not found in Kubernetes."
    }
    if ([string]$podCidrByNode[$node.node_name] -ne [string]$node.pod_cidr) {
      throw "Current PodCIDR of node '$($node.node_name)' ($($podCidrByNode[$node.node_name])) differs from the T4 marker ($($node.pod_cidr))."
    }
  }

  if ([string]::IsNullOrWhiteSpace($serverPodLine) -or [string]::IsNullOrWhiteSpace($benchPodLine)) {
    throw "Could not read the experiment 2 pods ($($script:Exp3BenchPodName)/$($script:Exp3ServerPodName)). Run 'bash exp2/exp2_create_normal_min.sh -m $Method' (or the medium-density create profile) first."
  }

  $serverParts = $serverPodLine -split '\|'
  $benchParts = $benchPodLine -split '\|'
  if ($serverParts.Count -lt 4 -or $benchParts.Count -lt 4) {
    throw "Unexpected pod status response format: server='$serverPodLine' bench='$benchPodLine'"
  }
  if ($serverParts[0] -ne $workerZeroNode.node_name) {
    throw "The Server pod must run on $($workerZeroNode.node_name) (found $($serverParts[0]))."
  }
  if ($benchParts[0] -ne $benchNode.node_name) {
    throw "The Benchmark pod must run on $($benchNode.node_name) (found $($benchParts[0]))."
  }
  if ($serverParts[2] -eq "true" -or $benchParts[2] -eq "true") {
    throw "PodCIDR route convergence cannot be measured with hostNetwork pods. Recreate the normal pod network with exp2_create_normal_min.sh or exp2_create_normal_medium.sh."
  }
  if ($serverParts[3] -ne "True" -or $benchParts[3] -ne "True") {
    throw "Both pods must be Ready (server=$($serverParts[3]), bench=$($benchParts[3]))."
  }
  if (-not (Test-Exp3Ipv4InCidr -Ip $serverParts[1] -Cidr $workerZeroNode.pod_cidr)) {
    throw "Server pod IP $($serverParts[1]) is not inside the worker-0 PodCIDR $($workerZeroNode.pod_cidr)."
  }
  if (-not (Test-Exp3Ipv4InCidr -Ip $benchParts[1] -Cidr $benchNode.pod_cidr)) {
    throw "Benchmark pod IP $($benchParts[1]) is not inside the benchmark PodCIDR $($benchNode.pod_cidr)."
  }
  $ctx.ServerPodIp = $serverParts[1]
  $ctx.BenchPodIp = $benchParts[1]
  Write-Host "    Benchmark Pod: $($ctx.BenchPodIp) on $($benchNode.node_name)"
  Write-Host "    Server Pod   : $($ctx.ServerPodIp) on $($workerZeroNode.node_name)"

  Write-Host "==> control plane gcloud preflight (hybrid measurement: T0/T1 on the CP clock)"
  Assert-Exp3ControlPlaneGcloudReady -Ctx $ctx

  $resultFile = Initialize-Exp3ResultFile -OutDirFull $outDirFull -Method $Method -NodeCount $nodeCount
  $ctx.Iteration = $resultFile.iteration
  $ctx.ResultCsvPath = $resultFile.csv_path
  $ctx.RawDir = $resultFile.raw_dir
  Write-Host "==> result iteration $($resultFile.iteration): $($resultFile.csv_path)"

  return $ctx
}

# -- Probe listener / prober -------------------------------------------------

function Start-Exp3ProbeListener {
  # Opens a TCP listener (socat) dedicated to experiment 3 inside the Server
  # pod, so probe connections never pollute the experiment 2 iperf3 (10000) and
  # netserver (10001) ports.
  param([object]$Ctx)

  $listenerScript = @'
kubectl -n __NS__ exec __SERVER_POD__ -c __SERVER_CONTAINER__ -- bash -c '
set -u
command -v socat >/dev/null || { echo NO_SOCAT; exit 21; }
if [ -f __LISTENER_PID__ ]; then kill "$(cat __LISTENER_PID__)" 2>/dev/null || true; fi
rm -f __LISTENER_OUT__
nohup socat TCP-LISTEN:__PORT__,reuseaddr,fork /dev/null >__LISTENER_OUT__ 2>&1 &
echo "$!" > __LISTENER_PID__
sleep 1
timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/__PORT__" || { echo LISTENER_SELFTEST_FAILED; cat __LISTENER_OUT__; exit 22; }
echo LISTENER_OK
'
'@
  $listenerScript = $listenerScript.Replace("__NS__", $Ctx.Namespace).
    Replace("__SERVER_POD__", $script:Exp3ServerPodName).
    Replace("__SERVER_CONTAINER__", $script:Exp3ServerContainer).
    Replace("__LISTENER_PID__", $script:Exp3PodListenerPid).
    Replace("__LISTENER_OUT__", $script:Exp3PodListenerOut).
    Replace("__PORT__", [string]$Ctx.ProbePort)

  $output = Invoke-Exp3Kubectl -Ctx $Ctx -Script $listenerScript
  if ($output -notmatch "LISTENER_OK") {
    throw "Failed to start the probe listener: $($output.Trim())"
  }
  Write-Host "==> server pod probe listener started (TCP $($Ctx.ProbePort))"
}

function Stop-Exp3ProbeListener {
  param([object]$Ctx)
  $stopScript = @'
kubectl -n __NS__ exec __SERVER_POD__ -c __SERVER_CONTAINER__ -- bash -c '
if [ -f __LISTENER_PID__ ]; then kill "$(cat __LISTENER_PID__)" 2>/dev/null || true; fi
rm -f __LISTENER_PID__ __LISTENER_OUT__
echo LISTENER_STOPPED
' || true
'@
  $stopScript = $stopScript.Replace("__NS__", $Ctx.Namespace).
    Replace("__SERVER_POD__", $script:Exp3ServerPodName).
    Replace("__SERVER_CONTAINER__", $script:Exp3ServerContainer).
    Replace("__LISTENER_PID__", $script:Exp3PodListenerPid).
    Replace("__LISTENER_OUT__", $script:Exp3PodListenerOut)
  $null = Invoke-Exp3Kubectl -Ctx $Ctx -Script $stopScript
}

function Start-Exp3Prober {
  # Starts the python3 prober detached inside the Benchmark pod.
  # Parallel (stagger) pipeline: a new TCP probe is fired every interval and each
  # probe waits independently up to its timeout. The kernel only retransmits the
  # initial SYN after a second, so an in-flight probe cannot notice the route
  # coming back; a probe fired right after recovery succeeds immediately
  # (connect ~1ms). T2 resolution is therefore about the firing interval, and the
  # timeout is only a per-probe wait cap, unrelated to resolution.
  # Each line is "OK|FAIL <fired epoch ms> <finished epoch ms>", in finish order.
  param([object]$Ctx)

  $invariant = [System.Globalization.CultureInfo]::InvariantCulture
  $proberScript = @'
cat > /tmp/exp3_probe.py <<'PYEOF'
import asyncio, sys, time

target = sys.argv[1]
port = int(sys.argv[2])
interval = float(sys.argv[3])   # probe firing interval = T2 resolution
timeout = float(sys.argv[4])    # per-probe connect wait cap (not the resolution)
path = sys.argv[5]

f = open(path, "a", buffering=1)

async def probe():
    start = int(time.time() * 1000)
    ok = False
    try:
        connect = asyncio.open_connection(target, port)
        reader, writer = await asyncio.wait_for(connect, timeout=timeout)
        writer.close()
        ok = True
    except (OSError, asyncio.TimeoutError):
        ok = False
    end = int(time.time() * 1000)
    # The event loop is single threaded, so writes never interleave mid-line.
    f.write(("OK " if ok else "FAIL ") + str(start) + " " + str(end) + "\n")

async def main():
    loop = asyncio.get_running_loop()
    next_launch = loop.time()
    while True:
        asyncio.ensure_future(probe())
        next_launch += interval
        delay = next_launch - loop.time()
        if delay > 0:
            await asyncio.sleep(delay)
        else:
            # If the loop fell behind, reset the schedule to keep the interval.
            next_launch = loop.time()

asyncio.run(main())
PYEOF
kubectl -n __NS__ exec -i __BENCH_POD__ -c __BENCH_CONTAINER__ -- bash -c 'cat > __PROBE_SCRIPT__' < /tmp/exp3_probe.py
rm -f /tmp/exp3_probe.py
kubectl -n __NS__ exec __BENCH_POD__ -c __BENCH_CONTAINER__ -- bash -c '
set -u
command -v python3 >/dev/null || { echo NO_PYTHON3; exit 21; }
if [ -f __PROBE_PID__ ]; then kill "$(cat __PROBE_PID__)" 2>/dev/null || true; fi
rm -f __PROBE_LOG__ __PROBE_OUT__
nohup python3 __PROBE_SCRIPT__ __TARGET__ __PORT__ __INTERVAL__ __TIMEOUT__ __PROBE_LOG__ >__PROBE_OUT__ 2>&1 &
echo "$!" > __PROBE_PID__
sleep 2
[ -s __PROBE_LOG__ ] || { echo PROBER_NOT_WRITING; cat __PROBE_OUT__ 2>/dev/null; exit 22; }
echo PROBER_OK
'
'@
  $proberScript = $proberScript.Replace("__NS__", $Ctx.Namespace).
    Replace("__BENCH_POD__", $script:Exp3BenchPodName).
    Replace("__BENCH_CONTAINER__", $script:Exp3BenchContainer).
    Replace("__PROBE_SCRIPT__", $script:Exp3PodProbeScript).
    Replace("__PROBE_LOG__", $script:Exp3PodProbeLog).
    Replace("__PROBE_PID__", $script:Exp3PodProbePid).
    Replace("__PROBE_OUT__", $script:Exp3PodProbeOut).
    Replace("__TARGET__", [string]$Ctx.ServerPodIp).
    Replace("__PORT__", [string]$Ctx.ProbePort).
    Replace("__INTERVAL__", ([double]$Ctx.ProbeIntervalSeconds).ToString($invariant)).
    Replace("__TIMEOUT__", ([double]$Ctx.ProbeTimeoutSeconds).ToString($invariant))

  $output = Invoke-Exp3Kubectl -Ctx $Ctx -Script $proberScript
  if ($output -notmatch "PROBER_OK") {
    throw "Failed to start the TCP prober: $($output.Trim())"
  }
  Write-Host "==> benchmark pod TCP prober started ($($Ctx.ServerPodIp):$($Ctx.ProbePort), parallel stagger: interval=$($Ctx.ProbeIntervalSeconds)s (= T2 resolution), probe timeout=$($Ctx.ProbeTimeoutSeconds)s)"
}

function Stop-Exp3Prober {
  param([object]$Ctx)
  $stopScript = @'
kubectl -n __NS__ exec __BENCH_POD__ -c __BENCH_CONTAINER__ -- bash -c '
if [ -f __PROBE_PID__ ]; then kill "$(cat __PROBE_PID__)" 2>/dev/null || true; fi
echo PROBER_STOPPED
' || true
'@
  $stopScript = $stopScript.Replace("__NS__", $Ctx.Namespace).
    Replace("__BENCH_POD__", $script:Exp3BenchPodName).
    Replace("__BENCH_CONTAINER__", $script:Exp3BenchContainer).
    Replace("__PROBE_PID__", $script:Exp3PodProbePid)
  $null = Invoke-Exp3Kubectl -Ctx $Ctx -Script $stopScript
}

function Save-Exp3ProbeLog {
  param([object]$Ctx)
  if ($null -eq $Ctx.RawDir) {
    return
  }
  $catScript = "kubectl -n $($Ctx.Namespace) exec $($script:Exp3BenchPodName) -c $($script:Exp3BenchContainer) -- cat $($script:Exp3PodProbeLog)"
  $log = Invoke-Exp3Kubectl -Ctx $Ctx -Script $catScript
  $path = Join-Path $Ctx.RawDir "probe-log.txt"
  $log | Set-Content -Encoding UTF8 -Path $path
  Write-Host "==> raw probe log saved: $path"
}

function Remove-Exp3PodArtifacts {
  param([object]$Ctx)
  $cleanupScript = @'
kubectl -n __NS__ exec __BENCH_POD__ -c __BENCH_CONTAINER__ -- bash -c 'rm -f __PROBE_SCRIPT__ __PROBE_LOG__ __PROBE_PID__ __PROBE_OUT__' || true
echo CLEANED
'@
  $cleanupScript = $cleanupScript.Replace("__NS__", $Ctx.Namespace).
    Replace("__BENCH_POD__", $script:Exp3BenchPodName).
    Replace("__BENCH_CONTAINER__", $script:Exp3BenchContainer).
    Replace("__PROBE_SCRIPT__", $script:Exp3PodProbeScript).
    Replace("__PROBE_LOG__", $script:Exp3PodProbeLog).
    Replace("__PROBE_PID__", $script:Exp3PodProbePid).
    Replace("__PROBE_OUT__", $script:Exp3PodProbeOut)
  $null = Invoke-Exp3Kubectl -Ctx $Ctx -Script $cleanupScript
}

function ConvertFrom-Exp3ProbeLog {
  # Parses the prober log text and returns entries sorted by finish time
  # (end_ms). Parallel probes can finish out of firing order (success ~1ms,
  # failure after the timeout), so end_ms ordering keeps the time axis coherent.
  param([string]$Raw)

  $entries = @()
  foreach ($line in ($Raw -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^(OK|FAIL)\s+(\d{12,14})\s+(\d{12,14})$') {
      $entries += [pscustomobject]@{
        ok       = ($Matches[1] -eq "OK")
        start_ms = [double][long]$Matches[2]
        end_ms   = [double][long]$Matches[3]
      }
    }
  }
  return @($entries | Sort-Object end_ms, start_ms)
}

function Get-Exp3ProbeRate {
  # Probes fired per second (used to size the tail window of the wait helpers).
  param([object]$Ctx)
  return [int][math]::Max(1, [math]::Ceiling(1.0 / [double]$Ctx.ProbeIntervalSeconds))
}

function Get-Exp3ProbeEntries {
  param([object]$Ctx, [int]$TailLines = 200)

  # The tail window only bounds the transfer; the parser sorts and filters.
  $boundedTail = [int][math]::Min(50000, [math]::Max(50, $TailLines))
  $tailScript = "kubectl -n $($Ctx.Namespace) exec $($script:Exp3BenchPodName) -c $($script:Exp3BenchContainer) -- tail -n $boundedTail $($script:Exp3PodProbeLog) 2>/dev/null || true"
  $raw = Invoke-Exp3Kubectl -Ctx $Ctx -Script $tailScript
  return (ConvertFrom-Exp3ProbeLog -Raw $raw)
}

function Get-Exp3TrailingEntries {
  # Returns the trailing run of identical results (ok/fail) at the end of the
  # list. Note: PS 5.1 throws ArgumentException when wrapping a
  # List[object] of PSCustomObject in @(), so this uses boundary index + slice.
  param([object[]]$Entries, [bool]$Ok, [double]$AfterVmMs = 0)
  $startIndex = $Entries.Count
  for ($index = $Entries.Count - 1; $index -ge 0; $index--) {
    $entry = $Entries[$index]
    if ($entry.ok -ne $Ok -or [double]$entry.start_ms -lt $AfterVmMs) {
      break
    }
    $startIndex = $index
  }
  if ($startIndex -ge $Entries.Count) {
    return @()
  }
  return @($Entries[$startIndex..($Entries.Count - 1)])
}

function Wait-Exp3TrailingOk {
  # Confirms the prober is alive and recent probes are consecutive OK (baseline).
  param([object]$Ctx, [int]$MinCount = 3, [int]$TimeoutSeconds = 90, [double]$FreshWithinMs = 20000)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $tailLines = [int][math]::Max(60, $MinCount + (Get-Exp3ProbeRate -Ctx $Ctx) * 3)
  do {
    $entries = @(Get-Exp3ProbeEntries -Ctx $Ctx -TailLines $tailLines)
    if ($entries.Count -gt 0) {
      $trailing = @(Get-Exp3TrailingEntries -Entries $entries -Ok $true)
      $nowVmMs = ConvertTo-Exp3VmMs -Ctx $Ctx -WinEpochMs (Get-Exp3WinEpochMs)
      if ($trailing.Count -ge $MinCount -and ($nowVmMs - [double]$entries[-1].end_ms) -le $FreshWithinMs) {
        return $trailing[-1]
      }
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "Baseline connectivity check failed: no run of $MinCount consecutive OK probes within ${TimeoutSeconds}s. Check $($script:Exp3PodProbeOut) inside the pod."
}

function Wait-Exp3ConsecutiveFail {
  # Waits until the consecutive FAIL run (= packet loss) after the withdrawal
  # reaches the required count and duration. Timestamps are pod clock epoch ms.
  param(
    [object]$Ctx,
    [double]$AfterVmMs,
    [int]$MinCount,
    [double]$MinSpanMs,
    [int]$TimeoutSeconds
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  # The FAIL window must span MinSpan seconds, so the tail scales with the rate.
  $probeRate = Get-Exp3ProbeRate -Ctx $Ctx
  $windowSeconds = ($MinSpanMs / 1000.0) + [double]$Ctx.ProbeTimeoutSeconds + 5.0
  $tailLines = [int][math]::Max(200, [math]::Ceiling($windowSeconds * $probeRate * 1.5))
  do {
    $entries = @(Get-Exp3ProbeEntries -Ctx $Ctx -TailLines $tailLines)
    if ($entries.Count -gt 0) {
      $trailing = @(Get-Exp3TrailingEntries -Entries $entries -Ok $false -AfterVmMs $AfterVmMs)
      if ($trailing.Count -ge $MinCount) {
        $spanMs = [double]$trailing[-1].end_ms - [double]$trailing[0].start_ms
        if ($spanMs -ge $MinSpanMs) {
          return [pscustomobject]@{
            fail_count = $trailing.Count
            first      = $trailing[0]
            last       = $trailing[-1]
            span_ms    = [math]::Round($spanMs, 3)
          }
        }
      }
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  throw "Packet loss check failed: no run of $MinCount consecutive FAIL probes (at least $([int]$MinSpanMs) ms) within ${TimeoutSeconds}s after the withdrawal."
}

function Wait-Exp3FirstOk {
  # Finds the first OK probe after T0 (converted to VM clock). T2 = its end_ms.
  param([object]$Ctx, [double]$AfterVmMs, [int]$TimeoutSeconds)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $tailLines = [int][math]::Max(400, (Get-Exp3ProbeRate -Ctx $Ctx) * 10)
  do {
    $entries = @(Get-Exp3ProbeEntries -Ctx $Ctx -TailLines $tailLines)
    if ($entries.Count -gt 0) {
      $candidates = @($entries | Where-Object { $_.ok -and [double]$_.end_ms -ge $AfterVmMs })
      if ($candidates.Count -gt 0) {
        # If the tail window is entirely OK the real first OK may be outside it,
        # so the boundary is searched once more with a larger window.
        if ($entries.Count -ge $tailLines -and $entries[0].ok -and [double]$entries[0].end_ms -ge $AfterVmMs) {
          $entries = @(Get-Exp3ProbeEntries -Ctx $Ctx -TailLines 20000)
          $candidates = @($entries | Where-Object { $_.ok -and [double]$_.end_ms -ge $AfterVmMs })
        }
        return $candidates[0]
      }
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "Route convergence failed: no TCP probe succeeded within ${TimeoutSeconds}s after T0."
}

function Wait-Exp3StableOk {
  # Checks whether the first OK is followed by enough consecutive OK probes
  # (flap detection). A failure here still leaves the measurement valid, so it
  # returns $null instead of throwing.
  param([object]$Ctx, [double]$AfterVmMs, [int]$MinCount, [int]$TimeoutSeconds = 120)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $tailLines = [int][math]::Max(60, $MinCount + [math]::Ceiling((Get-Exp3ProbeRate -Ctx $Ctx) * ([double]$Ctx.ProbeTimeoutSeconds + 2.0)))
  do {
    $entries = @(Get-Exp3ProbeEntries -Ctx $Ctx -TailLines $tailLines)
    if ($entries.Count -gt 0) {
      $trailing = @(Get-Exp3TrailingEntries -Entries $entries -Ok $true -AfterVmMs $AfterVmMs)
      if ($trailing.Count -ge $MinCount) {
        return $trailing[-1]
      }
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $null
}

# -- Measurement driver ------------------------------------------------------

function Invoke-Exp3Experiment {
  param(
    [Parameter(Mandatory = $true)] [object]$Ctx,
    [Parameter(Mandatory = $true)] [scriptblock]$AssertAdvertised,
    [Parameter(Mandatory = $true)] [scriptblock]$Withdraw,
    [Parameter(Mandatory = $true)] [scriptblock]$Readvertise,
    [Parameter(Mandatory = $true)] [scriptblock]$EnsureAdvertised,
    [Parameter(Mandatory = $true)] [scriptblock]$VerifyRestored,
    [int]$Repetitions = 3,
    [int]$LossConfirmProbes = 10,
    [int]$LossConfirmSeconds = 5,
    [int]$StableOkProbes = 5,
    [int]$LossTimeoutSeconds = 600,
    [int]$ConvergenceTimeoutSeconds = 900,
    [switch]$RestoreOnly
  )

  if ($RestoreOnly) {
    Write-Exp3Banner -Message @("[$($Ctx.Method)] restore-only mode: restoring the PodCIDR advertisements of $($Ctx.TargetNodes.node_name -join ', ').")
    & $EnsureAdvertised $Ctx | Out-Null
    & $VerifyRestored $Ctx | Out-Null
    Write-Host "Advertisement restored and verified." -ForegroundColor Green
    return
  }

  $script:Exp3Rows = @()
  $script:Exp3OutageOpen = $false
  $proberStarted = $false
  $listenerStarted = $false
  $currentRep = 0

  try {
    Write-Exp3Banner -Message @(
      "[$($Ctx.Method)] experiment 3 - route convergence time (nodes $($Ctx.NodeCount), iteration $($Ctx.Iteration), repetitions $Repetitions)",
      "targets: $($Ctx.TargetNodes.node_name -join ', ') / probe: $($Ctx.ServerPodIp):$($Ctx.ProbePort)"
    )

    Write-Host "==> verifying the advertisement state up front"
    & $AssertAdvertised $Ctx | Out-Null

    Start-Exp3ProbeListener -Ctx $Ctx
    $listenerStarted = $true
    Start-Exp3Prober -Ctx $Ctx
    $proberStarted = $true

    Write-Host "==> measuring clock offsets (SSH ping-pong: bench VM, control plane)"
    # The bench offset converts non-measured Windows boundaries (teardown) to the
    # VM time axis. The CP offset is not used in any calculation; it only records
    # the CP-bench relative estimate as a sanity check of the assumption that
    # both VM clocks are chrony-synchronized.
    $clockBench = Measure-Exp3ClockOffset -Ctx $Ctx -Node $Ctx.BenchVm
    $Ctx.ClockOffsetMs = $clockBench.offset_ms
    $Ctx.ClockRttMs = $clockBench.rtt_ms
    ConvertTo-Json -InputObject $clockBench -Depth 6 |
      Set-Content -Encoding UTF8 -Path (Join-Path $Ctx.RawDir "clock-offset-bench.json")
    $clockCp = Measure-Exp3ClockOffset -Ctx $Ctx -Node $Ctx.ControlPlane
    ConvertTo-Json -InputObject $clockCp -Depth 6 |
      Set-Content -Encoding UTF8 -Path (Join-Path $Ctx.RawDir "clock-offset-cp.json")
    $Ctx.CpBenchOffsetEstMs = [math]::Round([double]$clockCp.offset_ms - [double]$clockBench.offset_ms, 3)
    Write-Host ("    win-bench offset = {0} ms (min RTT {1} ms) / estimated CP-bench relative offset = {2} ms (+/-{3} ms, not used in any calculation)" -f `
      $clockBench.offset_ms, $clockBench.rtt_ms, $Ctx.CpBenchOffsetEstMs, `
      [math]::Round(([double]$clockBench.rtt_ms + [double]$clockCp.rtt_ms) / 2.0, 1))

    Write-Host "==> baseline connectivity check (consecutive OK probes)"
    $null = Wait-Exp3TrailingOk -Ctx $Ctx -MinCount 3 -TimeoutSeconds 90

    for ($rep = 1; $rep -le $Repetitions; $rep++) {
      $currentRep = $rep
      Write-Exp3Banner -Message @("[$($Ctx.Method)] repetition $rep / $Repetitions") -Color Yellow

      if ($rep -gt 1) {
        Write-Host "==> re-checking baseline connectivity before the repetition"
        $null = Wait-Exp3TrailingOk -Ctx $Ctx -MinCount 3 -TimeoutSeconds 180
      }

      # 1) Withdraw: remove only the PodCIDR advertisement of the benchmark and
      #    worker-0 nodes. It also runs as a CP timed task, so its boundaries are
      #    recorded with the VM clock.
      Write-Host "==> [withdraw] removing the advertisement of $($Ctx.TargetNodes.node_name -join ', ') (run on the CP)"
      $script:Exp3OutageOpen = $true
      $withdrawOutputs = @(& $Withdraw $Ctx | Where-Object { $null -ne $_ })
      if ($withdrawOutputs.Count -lt 1) {
        throw "The withdraw callback returned no result."
      }
      $withdrawResult = $withdrawOutputs[-1]
      if ($null -eq $withdrawResult.PSObject.Properties["t0_vm_ms"] -or
          $null -eq $withdrawResult.PSObject.Properties["t1_vm_ms"]) {
        throw "The withdraw callback returned no CP timed task result (t0_vm_ms/t1_vm_ms)."
      }
      ConvertTo-Json -InputObject $withdrawResult -Depth 6 |
        Set-Content -Encoding UTF8 -Path (Join-Path $Ctx.RawDir "rep$rep-withdraw-timings.json")
      $teardownStartVmMs = [double]$withdrawResult.t0_vm_ms
      $teardownEndVmMs = [double]$withdrawResult.t1_vm_ms

      # 2) Packet loss check: after the withdrawal a consecutive FAIL run must
      #    reach the configured threshold.
      Write-Host "==> [loss check] waiting for $LossConfirmProbes consecutive FAIL probes (at least ${LossConfirmSeconds}s)"
      $loss = Wait-Exp3ConsecutiveFail -Ctx $Ctx `
        -AfterVmMs $teardownEndVmMs `
        -MinCount $LossConfirmProbes `
        -MinSpanMs ([double]$LossConfirmSeconds * 1000.0) `
        -TimeoutSeconds $LossTimeoutSeconds
      Write-Host ("    loss confirmed: {0} consecutive FAIL probes over {1} ms" -f $loss.fail_count, $loss.span_ms)

      # 3) T0 -> re-advertisement task -> T1. The task runs on the control plane
      #    and T0/T1 are recorded with the CP VM clock (hybrid measurement: the
      #    Windows clock and the internet path stay out of the measured window).
      Write-Host "==> [re-advertise] running the routing task on the control plane (T0 = last command fired)"
      $advOutputs = @(& $Readvertise $Ctx | Where-Object { $null -ne $_ })
      if ($advOutputs.Count -lt 1) {
        throw "The readvertise callback returned no result."
      }
      $advResult = $advOutputs[-1]
      if ($null -eq $advResult.PSObject.Properties["t0_vm_ms"] -or
          $null -eq $advResult.PSObject.Properties["t1_vm_ms"]) {
        throw "The readvertise callback returned no CP timed task result (t0_vm_ms/t1_vm_ms)."
      }
      ConvertTo-Json -InputObject $advResult -Depth 6 |
        Set-Content -Encoding UTF8 -Path (Join-Path $Ctx.RawDir "rep$rep-readvertise-timings.json")
      # T0 definition: the moment the last task call needed for route
      # convergence is fired, i.e. the last essential command that completes the
      # connectivity prerequisite (CP clock). Redundancy commands
      # (essential=false, for example the second peer of each N-Dynamic node)
      # are not a prerequisite and are excluded from the T0 anchor. The metric
      # is convergence time, not serial application time, so the preceding
      # commands (spoke, earlier peers) also stay out of T2-T0. For the parallel
      # methods every command is essential and fired at once, so T0 is about the
      # task start. The raw task start/end and per-command boundaries are kept in
      # the rep JSON.
      # (commands are sorted by start time, so the last essential is the latest.)
      $advCommands = @($advResult.commands)
      $anchorCommands = @($advCommands | Where-Object {
        $null -eq $_.PSObject.Properties["essential"] -or [bool]$_.essential
      })
      if ($anchorCommands.Count -lt 1) {
        throw "The re-advertisement task has no T0 anchor (essential) command."
      }
      $t0VmMs = [double]$anchorCommands[-1].started_vm_ms
      $t1VmMs = [double]$advResult.t1_vm_ms
      Write-Host ("    T0: last essential command '$($anchorCommands[-1].name)' fired (CP clock) / T1: advertisement task finished (T0_to_T1 = {0} ms)" -f [math]::Round($t1VmMs - $t0VmMs))

      # 4) T2: first OK probe after T0. T0 and T2 share the GCP NTP time axis, so
      #    they are compared without conversion.
      Write-Host "==> [convergence] waiting for the first successful TCP probe"
      $firstOk = Wait-Exp3FirstOk -Ctx $Ctx -AfterVmMs $t0VmMs -TimeoutSeconds $ConvergenceTimeoutSeconds
      $t2VmMs = [double]$firstOk.end_ms
      $t0ToT2Ms = $t2VmMs - $t0VmMs
      $t1ToT2Ms = $t2VmMs - $t1VmMs

      $stableEntry = Wait-Exp3StableOk -Ctx $Ctx -AfterVmMs $t2VmMs -MinCount $StableOkProbes
      $stableOk = ($null -ne $stableEntry)
      if (-not $stableOk) {
        Write-Warning "Could not confirm $StableOkProbes consecutive OK probes after the first OK (possible flap). T2 is still recorded as the first OK, per its definition."
      }

      # 5) Restore check: confirm the advertisement is back to the initial state.
      Write-Host "==> [restore check]"
      & $VerifyRestored $Ctx | Out-Null
      $script:Exp3OutageOpen = $false

      # Every *_utc is on the VM (NTP-synchronized) time axis, including the
      # teardown boundaries recorded by the CP timed task.
      $row = New-Exp3ResultRow -Ctx $Ctx -Values @{
        record_type            = "MEASUREMENT"
        repetition             = $rep
        status                 = "SUCCESS"
        teardown_started_utc   = ConvertTo-Exp3UtcIso -EpochMs $teardownStartVmMs
        teardown_ended_utc     = ConvertTo-Exp3UtcIso -EpochMs $teardownEndVmMs
        teardown_ms            = [math]::Round($teardownEndVmMs - $teardownStartVmMs, 3)
        loss_confirmed_utc     = ConvertTo-Exp3UtcIso -EpochMs ([double]$loss.last.end_ms)
        loss_fail_count        = $loss.fail_count
        loss_span_ms           = $loss.span_ms
        t0_utc                 = ConvertTo-Exp3UtcIso -EpochMs $t0VmMs
        t0_vm_unix_ms          = [long][math]::Round($t0VmMs)
        t1_utc                 = ConvertTo-Exp3UtcIso -EpochMs $t1VmMs
        t1_vm_unix_ms          = [long][math]::Round($t1VmMs)
        t2_utc                 = ConvertTo-Exp3UtcIso -EpochMs $t2VmMs
        t2_vm_unix_ms          = [long][math]::Round($t2VmMs)
        t0_to_t1_ms            = [math]::Round($t1VmMs - $t0VmMs, 3)
        t1_to_t2_ms            = [math]::Round($t1ToT2Ms, 3)
        t0_to_t2_ms            = [math]::Round($t0ToT2Ms, 3)
        stable_ok              = $stableOk
        clock_offset_ms        = $Ctx.ClockOffsetMs
        clock_rtt_ms           = $Ctx.ClockRttMs
        cp_bench_offset_est_ms = $Ctx.CpBenchOffsetEstMs
      }
      $script:Exp3Rows += $row
      Save-Exp3Rows -Ctx $Ctx
      Write-Host ("repetition {0} convergence time (T2-T0): {1} ms" -f $rep, [math]::Round($t0ToT2Ms)) -ForegroundColor Green
    }

    $successRows = @($script:Exp3Rows | Where-Object { $_.record_type -eq "MEASUREMENT" -and $_.status -eq "SUCCESS" })
    if ($successRows.Count -gt 0) {
      $meanT0T1 = ($successRows | Measure-Object -Property t0_to_t1_ms -Average).Average
      $meanT1T2 = ($successRows | Measure-Object -Property t1_to_t2_ms -Average).Average
      $meanT0T2 = ($successRows | Measure-Object -Property t0_to_t2_ms -Average).Average
      $script:Exp3Rows += New-Exp3ResultRow -Ctx $Ctx -Values @{
        record_type = "AVERAGE"
        status      = "SUCCESS"
        t0_to_t1_ms = [math]::Round($meanT0T1, 3)
        t1_to_t2_ms = [math]::Round($meanT1T2, 3)
        t0_to_t2_ms = [math]::Round($meanT0T2, 3)
        notes       = "mean of $($successRows.Count) successful repetitions"
      }
      Save-Exp3Rows -Ctx $Ctx
    }

    $summary = [pscustomobject]@{
      method            = $Ctx.Method
      node_count        = $Ctx.NodeCount
      iteration         = $Ctx.Iteration
      repetitions       = $Repetitions
      result_csv        = $Ctx.ResultCsvPath
      cp_gcloud_path    = $Ctx.CpGcloudPath
      cp_gcloud_account = $Ctx.CpGcloudAccount
      clock_offset_ms   = $Ctx.ClockOffsetMs
      clock_rtt_ms      = $Ctx.ClockRttMs
      cp_bench_offset_est_ms = $Ctx.CpBenchOffsetEstMs
      probe_port        = $Ctx.ProbePort
      server_pod_ip     = $Ctx.ServerPodIp
      bench_pod_ip      = $Ctx.BenchPodIp
      generated_at      = (Get-Date).ToUniversalTime().ToString("o")
      convergence_ms    = @($successRows | ForEach-Object { $_.t0_to_t2_ms })
      mean_t0_to_t2_ms  = [math]::Round(($successRows | Measure-Object -Property t0_to_t2_ms -Average).Average, 3)
    }
    ConvertTo-Json -InputObject $summary -Depth 6 |
      Set-Content -Encoding UTF8 -Path (Join-Path $Ctx.RawDir "summary.json")

    Write-Exp3Banner -Message (@(
      "[$($Ctx.Method)] experiment 3 complete - nodes $($Ctx.NodeCount), iteration $($Ctx.Iteration)"
    ) + @($successRows | ForEach-Object { "  repetition $($_.repetition): T2-T0 = $([math]::Round([double]$_.t0_to_t2_ms)) ms" }) + @(
      "  mean: $($summary.mean_t0_to_t2_ms) ms",
      "  result CSV: $($Ctx.ResultCsvPath)"
    )) -Color Green
  }
  catch {
    $message = $_.Exception.Message
    Write-Warning "Experiment 3 measurement failed (repetition $currentRep): $message"
    if ($null -ne $Ctx.ResultCsvPath) {
      $script:Exp3Rows += New-Exp3ResultRow -Ctx $Ctx -Values @{
        record_type = "FAILURE"
        repetition  = if ($currentRep -gt 0) { $currentRep } else { $null }
        status      = "FAILED"
        notes       = $message
      }
      Save-Exp3Rows -Ctx $Ctx
    }
    throw
  }
  finally {
    if ($script:Exp3OutageOpen) {
      Write-Warning "Exiting with the advertisement withdrawn; attempting an automatic restore..."
      try {
        & $EnsureAdvertised $Ctx | Out-Null
        & $VerifyRestored $Ctx | Out-Null
        $script:Exp3OutageOpen = $false
        Write-Host "Advertisement restored automatically." -ForegroundColor Green
      }
      catch {
        Write-Warning "Automatic restore failed: $($_.Exception.Message)"
        Write-Warning "Manual restore: run the same script again with -RestoreOnly."
      }
    }
    if ($proberStarted) {
      try { Stop-Exp3Prober -Ctx $Ctx } catch { Write-Warning "failed to stop the prober: $($_.Exception.Message)" }
      try { Save-Exp3ProbeLog -Ctx $Ctx } catch { Write-Warning "failed to save the probe log: $($_.Exception.Message)" }
      try { Remove-Exp3PodArtifacts -Ctx $Ctx } catch { Write-Warning "failed to clean up the pod temp files: $($_.Exception.Message)" }
    }
    if ($listenerStarted) {
      try { Stop-Exp3ProbeListener -Ctx $Ctx } catch { Write-Warning "failed to stop the listener: $($_.Exception.Message)" }
    }
  }
}
