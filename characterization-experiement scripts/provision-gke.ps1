[CmdletBinding()]
param(
  # 4 = initial build (bench 1 + worker 2 + managed control plane) from an empty
  #     Terraform state.
  # 8 = expansion of that cluster: the worker pool is resized 2 -> 6 on the same
  #     state. It never builds from scratch.
  [ValidateSet(4, 8)]
  [int]$NodeCount = 4,

  # Optional overrides. Empty means infra/gke and
  # results/gke/provisioning-<n>node.
  [string]$TfDir = "",
  [string]$VarFile = "",
  [string]$OutDir = "",

  [string]$ExperimentLabel = "exp1",

  # GKE compact placement is documented as best effort. When the policy is
  # attached but the nodes did not actually land on one rack, the default is to
  # fail the iteration as a control-variable violation (the kubeadm
  # max_distance=1 is not available on GKE, so this measurement is the only
  # guarantee). With this switch the deviation is only recorded.
  [switch]$AllowRackSpread,

  [switch]$SkipApply,
  [switch]$SkipQuotaPreflight
)

# Experiment 1 provisioning for N-Cloud on GKE Standard. Design: infra/gke/README.md
#
# Differences from the kubeadm engine (provision.ps1):
#  - T1 is the last node-VM creation audit event, T2 is the apply end, and T3 is
#    GKE dataplane convergence (the counterpart of kubeadm `cilium status
#    --wait`). T4 shares T3 exactly because GKE has no separate VPC task.
#  - T5 remains the required connectivity-validation point but is excluded from
#    the experiment 1 duration metric, whose measured total is T0~T4. T3 and T5
#    run on the ops VM in the same zone, because running them from Cloud Shell
#    (asia-east1) adds a cross-region round trip to hundreds of API calls and
#    makes T2~T3 incomparable with kubeadm (which runs on the CP VM).
#  - The ops VM (cloud-ops-0) is created in the same apply with
#    -var=create_ops_vm=true and remains available for the post-measurement T5.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerCount = $NodeCount - 2
$RequiredExistingWorkers = if ($NodeCount -eq 4) { 0 } else { 2 }
if ([string]::IsNullOrWhiteSpace($TfDir))   { $TfDir = Join-Path $PSScriptRoot "infra\gke" }
if ([string]::IsNullOrWhiteSpace($VarFile)) { $VarFile = Join-Path $TfDir "terraform.tfvars" }
if ([string]::IsNullOrWhiteSpace($OutDir))  { $OutDir = ".\results\gke\provisioning-${NodeCount}node" }

. (Join-Path $PSScriptRoot "provision-common.ps1")

# Token compared against tfvars/Terraform resources. The cluster name and prefix
# are 'cloud', so this stays 'cloud'.
$script:ExperimentName = "cloud"
# Label written to the result filename and the CSV method column. It stays GKE
# so the results never mix with a kubeadm N-Cloud run: GKE_4_exp1_iterN.csv
$script:ResultMethodLabel = "GKE"
# Experiment 2 measurement image (ubuntu:22.04 + iperf3 3.21 built from source,
# exp2/image/Dockerfile). Saved locally with docker save and loaded into the
# containerd (k8s.io) of the Benchmark/Server nodes. The tag must match the
# TOOL_IMAGE default of gke/exp2/exp2_benchmark_gke.sh.
$script:Exp2ToolImageTag = "localhost/exp2-tools:iperf3-3.21"
$script:ExperimentLabel = $ExperimentLabel
$script:TerraformWorkspace = "default"
$script:ProvisioningStartedAt = Get-Date
$script:MonotonicClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:CurrentStep = "initialize"
$script:ExpectedNodeCount = 0        # CSV label (4/8) = worker + managed CP + bench
$script:ActualNodeCount = 0          # real GKE node count (3/7) = worker + bench
$script:RunIteration = $null
$script:RunOutputClaimed = $false
$script:RunResultCsvPath = $null
$script:RunResultClaimPath = $null
$script:RunStatus = "RUNNING"
$script:DurationRows = @()
$script:ApplyAttempted = $false
$script:ApplyStarted = $false
$script:RunCompleted = $false
$script:LastNativeTiming = $null

function Get-TerraformStateResources {
  param([string]$TfDirFull)
  $lines = @()
  try {
    $ErrorActionPreference = "Continue"
    $lines = @(& terraform -chdir="$TfDirFull" state list 2>&1 | ForEach-Object { $_.ToString() })
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($LASTEXITCODE -ne 0) {
    return @()
  }
  return @($lines | Where-Object { $_ -match '^\S' })
}

function Get-GcloudValueLines {
  param([string[]]$Arguments)
  $gcloudArgs = $Arguments + @("--verbosity", "error")
  $output = & gcloud @gcloudArgs
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud command failed: gcloud $($gcloudArgs -join ' ')"
  }
  return @(
    ($output | Out-String) -split "`r?`n" |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() }
  )
}

function Get-NodeSshArguments {
  # GKE node SSH. Injecting ssh-keys through the node pool metadata is verified
  # to work (vxlan account auth + google-sudoers group + sudo ctr access).
  # Nodes are recreated every iteration and external IPs are reused, so the host
  # key is not pinned.
  return @(
    "-i", $script:OpsSshKeyFile,
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "ConnectTimeout=30"
  )
}

function Install-Exp2ToolImageOnGkeNodes {
  # Loads the experiment 2 tool image into the containerd (k8s.io) of the two
  # nodes that will host the Benchmark and Server pods. It is the same path the
  # kubeadm engine uses (Install-Exp2ToolImageOnNodes), so every method shares
  # the same image bytes and the same load mechanism. No registry (Artifact
  # Registry) is involved: scp + ctr import works thanks to the node pool
  # ssh-keys, and that keeps the control variables aligned.
  param(
    [string]$ProjectId,
    [string]$Zone,
    [string]$SshUser,
    [string]$ArchivePath,
    [string]$Tag,
    [string[]]$TargetInstances,
    [string]$LogDirectory
  )

  $remoteArchive = "/tmp/exp2-tools-image.tar"
  foreach ($instance in $TargetInstances) {
    $ip = (& gcloud compute instances describe $instance --project $ProjectId --zone $Zone `
      --format "value(networkInterfaces[0].accessConfigs[0].natIP)" --verbosity error | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) {
      throw "Node '$instance' has no external IP; cannot scp the experiment 2 tool image."
    }
    $target = "$SshUser@$ip"

    Invoke-Native -File "scp" -Arguments ((Get-NodeSshArguments) + @($ArchivePath, "${target}:$remoteArchive")) `
      -WorkingDirectory $LogDirectory `
      -LogPath (Join-Path $LogDirectory "exp2-tool-image-scp-$instance.log") `
      -TimingName "exp2 tool image scp $instance"

    $importCommand = @(
      'set -euo pipefail',
      "trap 'rm -f $remoteArchive' EXIT",
      "sudo -n ctr -n k8s.io images import '$remoteArchive' >/dev/null",
      "sudo -n ctr -n k8s.io images ls -q | grep -Fx '$Tag' >/dev/null",
      # Also check the CRI store kubelet queries (warn only when absent).
      "if command -v crictl >/dev/null 2>&1; then sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock inspecti '$Tag' >/dev/null; else echo 'crictl not found; skipped CRI-level check' >&2; fi",
      "echo EXP2_IMAGE_OK"
    ) -join ([string][char]10)

    $importLog = Join-Path $LogDirectory "exp2-tool-image-import-$instance.log"
    Invoke-Native -File "ssh" -Arguments ((Get-NodeSshArguments) + @($target, "bash -s")) `
      -WorkingDirectory $LogDirectory -LogPath $importLog `
      -TimingName "exp2 tool image import $instance" -StdinText $importCommand
    if ((Get-Content -LiteralPath $importLog -Raw) -notmatch "EXP2_IMAGE_OK") {
      throw "Experiment 2 tool image import failed on '$instance'. See $importLog"
    }
    Write-Host "  tool image loaded into containerd (k8s.io) on ${instance}: $Tag"
  }
}

function Get-OpsSshArguments {
  return @(
    "-i", $script:OpsSshKeyFile,
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    # The ops VM is a throwaway VM recreated every iteration, and GCP reuses
    # ephemeral external IPs, so a preserved host key is guaranteed to collide
    # on the next iteration ("REMOTE HOST IDENTIFICATION HAS CHANGED" - and
    # accept-new rejects a *changed* key, which blocks the connection outright).
    # Pinning the host key buys no security here either: the target VM was
    # created by our own Terraform seconds ago and its address was read straight
    # from the GCP API. exp3-common.ps1 uses StrictHostKeyChecking=no +
    # UserKnownHostsFile=NUL for the same reason.
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "ConnectTimeout=30"
  )
}

function Invoke-OpsVmScript {
  # Runs a bash script on the ops VM (Seoul, same zone). T3/T5 run there to
  # match the kubeadm condition of running the CLI on the CP VM: from Cloud
  # Shell (asia-east1) every one of the hundreds of API round trips would carry
  # a cross-region delay and the measured T2~T3 would not be comparable.
  param(
    [string]$ScriptContent,
    [string]$RemoteName,
    [string]$LogPath,
    [string]$TimingName
  )
  $normalized = $ScriptContent.Replace("`r`n", "`n")
  [System.IO.File]::WriteAllText((Join-Path $script:OutDirFull $RemoteName), $normalized, (New-Object System.Text.UTF8Encoding($false)))
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
  $command = "printf '%s' '$b64' | base64 -d >'/tmp/$RemoteName' && bash '/tmp/$RemoteName'"
  Invoke-Native -File "ssh" -Arguments ((Get-OpsSshArguments) + @($script:OpsSshTarget, $command)) `
    -WorkingDirectory $script:OutDirFull -LogPath $LogPath -TimingName $TimingName
}

function Wait-OpsVmReady {
  # Preparation that must finish before the T4 measurement: bootstrap complete,
  # kubectl talking to the API, CLI versions. The ops VM bootstrap runs in
  # parallel with cluster creation (~6 min) and is usually done already.
  param(
    [string]$ProjectId,
    [string]$Zone,
    [string]$ClusterName,
    [string]$CiliumCliVersion,
    [string]$LogDirectory
  )
  $readyTemplate = @'
#!/usr/bin/env bash
set -euxo pipefail
export PATH="/usr/local/bin:$PATH"
# Wait until bootstrap (apt + kubectl + helm + Cilium CLI) is finished.
timeout 1800 bash -c 'until test -f /var/lib/experiment-ops-bootstrap.done; do sleep 5; done'
cilium version --client | grep -F "__CILIUM_CLI_VERSION__" >/dev/null
gcloud container clusters get-credentials "__CLUSTER__" --zone "__ZONE__" --project "__PROJECT__" --quiet
# The ops VM is an API client, not a cluster member. Without GKE IAM on its
# attached compute SA this is where it stops (roles/container.developer or
# roles/editor).
kubectl get nodes >/dev/null
kubectl auth can-i create pods >/dev/null

# get-credentials only writes the ~/.kube/config of the account that ran it.
# Connecting through gcloud compute ssh makes you a different, Google-account
# based user whose kubectl then targets localhost:8080 and fails. The shared
# kubeconfig is exposed the same way the kubeadm engine solves it with
# /etc/kubernetes/admin-shared.conf + profile.d. Authentication is performed by
# gke-gcloud-auth-plugin with each account's own gcloud credentials, so the file
# holds no secret (only endpoint + CA + the plugin reference).
sudo install -m 0644 "$HOME/.kube/config" /etc/kubernetes-ops-kubeconfig
sudo tee /etc/profile.d/99-experiment-kubeconfig.sh >/dev/null <<'EOF_KUBECONFIG'
if [ -z "${KUBECONFIG:-}" ] && [ ! -r "$HOME/.kube/config" ] && [ -r /etc/kubernetes-ops-kubeconfig ]; then
  export KUBECONFIG=/etc/kubernetes-ops-kubeconfig
fi
EOF_KUBECONFIG
sudo chmod 0644 /etc/profile.d/99-experiment-kubeconfig.sh
echo "OPS_VM_READY cilium=$(cilium version --client 2>/dev/null | head -1)"
'@
  # The ops VM is created last in the apply because of depends_on, so at apply
  # end its guest OS/sshd may still be coming up: retry until it accepts a
  # connection (same intent as the "wait for node bootstrap" retry of the
  # kubeadm engine). This wait happens before the T4 measurement, so it is not
  # part of T3~T4.
  $sshDeadline = (Get-Date).AddMinutes(10)
  $sshAttempt = 0
  $sshProbeLog = Join-Path $LogDirectory "ops-ssh-probe.log"
  $lastSshOutput = ""
  while ($true) {
    $sshAttempt++
    $probeOk = $false
    try {
      $ErrorActionPreference = "Continue"
      $global:LASTEXITCODE = $null
      # Keep the output so a connection refusal/timeout can be told apart from
      # an authentication failure; -v keeps the auth negotiation, which shows a
      # key or OS Login problem immediately.
      $lastSshOutput = (
        & ssh @((Get-OpsSshArguments) + @("-v", $script:OpsSshTarget, "true")) 2>&1 |
          ForEach-Object { $_.ToString() }
      ) -join [Environment]::NewLine
      $probeOk = ($global:LASTEXITCODE -eq 0)
    }
    finally {
      $ErrorActionPreference = "Stop"
    }
    if ($probeOk) {
      Write-Host "ops VM SSH reachable after $sshAttempt attempt(s)."
      break
    }
    # Accumulate every attempt: keeping only the last one hides early symptoms.
    Add-Content -Path $sshProbeLog -Value ("=== attempt $sshAttempt @ $((Get-Date).ToString('o')) ===" + [Environment]::NewLine + $lastSshOutput)
    if ((Get-Date) -gt $sshDeadline) {
      $tail = ($lastSshOutput -split "`r?`n" | Select-Object -Last 15) -join [Environment]::NewLine
      throw @"
ops VM SSH did not become reachable within 10 minutes ($($script:OpsSshTarget)).
Full probe log: $sshProbeLog
Last ssh -v output:
$tail

Diagnose by symptom:
  - "Connection timed out" / "No route to host" -> firewall: check the '<prefix>-allow-ssh' rule exists,
    that the ops VM carries the '<prefix>-node' network tag, and ssh_source_ranges in tfvars.
  - "Permission denied (publickey)" -> key/account: the VM metadata ssh-keys entry must be
    '<ssh_user>:<public key>' and project metadata must not force OS Login (enable-oslogin).
  - "Connection refused" -> sshd not up yet, or the startup script broke the boot; check the
    serial console: gcloud compute instances get-serial-port-output <ops vm> --zone <zone>
"@
    }
    Start-Sleep -Seconds 5
  }

  $readyScript = $readyTemplate.
    Replace("__CILIUM_CLI_VERSION__", $CiliumCliVersion).
    Replace("__CLUSTER__", $ClusterName).
    Replace("__ZONE__", $Zone).
    Replace("__PROJECT__", $ProjectId)
  $readyLog = Join-Path $LogDirectory "ops-vm-ready.log"
  Invoke-OpsVmScript -ScriptContent $readyScript -RemoteName "gke-ops-ready.sh" `
    -LogPath $readyLog -TimingName "ops vm readiness"
  if ((Get-Content -LiteralPath $readyLog -Raw) -notmatch "OPS_VM_READY") {
    throw "ops VM is not ready for T3/T5. If kubectl failed, the attached compute service account likely lacks GKE IAM (grant roles/container.developer or roles/editor). See $readyLog"
  }
  Write-Host "ops VM ready: bootstrap done, Cilium CLI $CiliumCliVersion, kubectl verified."
}

function Install-OpsVmExperimentAssets {
  # Installs the experiment 2 assets on the ops VM (which plays the CP VM
  # orchestrator role) and verifies kubectl really reaches the GKE API:
  #  1) wait for the bootstrap marker (apt/CLI installs finish asynchronously)
  #  2) gcloud container clusters get-credentials + a real kubectl get nodes
  #     (the ops VM is an API client, not a cluster member, so a missing GKE IAM
  #      role on its attached compute SA stops here - see README-exp3.md)
  #  3) install gke/exp2/* under the shared path /opt/experiment/scripts
  #     (CRLF->LF, root:root 0755, bash -n), the counterpart of the kubeadm
  #     Install-Exp2ScriptsOnControlPlane.
  # Wait-OpsVmReady already did the bootstrap wait and the kubectl check before
  # T4, so only the experiment 2 scripts are installed here (outside the
  # measured window).
  param([string]$LogDirectory)

  # Uploads the experiment 2 scripts plus the tool image build context, carried
  # as base64 to avoid Windows path and CRLF problems. The image context is
  # needed so docker build/push can run inside the ops VM (no local Docker).
  $exp2Dir = Join-Path $PSScriptRoot "gke\exp2"
  $files = @(Get-ChildItem -LiteralPath $exp2Dir -Filter "*.sh" -File)
  if ($files.Count -eq 0) {
    throw "No experiment 2 scripts found under $exp2Dir"
  }
  $installLines = @("set -euo pipefail", "sudo install -d -m 0755 -o root -g root /opt/experiment/scripts")

  # Copy the tool image build context (exp2/image/*) to /opt/experiment/image.
  $imageDir = Join-Path $PSScriptRoot "exp2\image"
  if (Test-Path -LiteralPath $imageDir) {
    $installLines += "sudo install -d -m 0755 -o root -g root /opt/experiment/image"
    foreach ($imageFile in @(Get-ChildItem -LiteralPath $imageDir -File)) {
      $imageText = ([System.IO.File]::ReadAllText($imageFile.FullName)).Replace("`r`n", "`n")
      $imageB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($imageText))
      $installLines += "printf '%s' '$imageB64' | base64 -d | sudo tee /opt/experiment/image/$($imageFile.Name) >/dev/null"
      $installLines += "sudo chown root:root /opt/experiment/image/$($imageFile.Name)"
    }
  }
  foreach ($file in $files) {
    $normalized = ([System.IO.File]::ReadAllText($file.FullName)).Replace("`r`n", "`n")
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
    $sha = (Get-FileHash -InputStream (New-Object System.IO.MemoryStream(, [System.Text.Encoding]::UTF8.GetBytes($normalized))) -Algorithm SHA256).Hash.ToLowerInvariant()
    $installLines += "printf '%s' '$b64' | base64 -d | sudo tee /opt/experiment/scripts/$($file.Name) >/dev/null"
    $installLines += "sudo chown root:root /opt/experiment/scripts/$($file.Name)"
    $installLines += "sudo chmod 0755 /opt/experiment/scripts/$($file.Name)"
    $installLines += "test `"`$(sha256sum /opt/experiment/scripts/$($file.Name) | cut -d' ' -f1)`" = '$sha'"
    $installLines += "bash -n /opt/experiment/scripts/$($file.Name)"
  }
  $installLines += "ls -l /opt/experiment/scripts"
  $installLines += "echo OPS_EXP2_SCRIPTS_OK"
  $installLog = Join-Path $LogDirectory "ops-exp2-script-install.log"
  Invoke-Native -File "ssh" -Arguments ((Get-OpsSshArguments) + @($script:OpsSshTarget, "bash -s")) `
    -WorkingDirectory $LogDirectory -LogPath $installLog -TimingName "ops vm exp2 script install" `
    -StdinText ($installLines -join ([string][char]10))
  if ((Get-Content -LiteralPath $installLog -Raw) -notmatch "OPS_EXP2_SCRIPTS_OK") {
    throw "Experiment 2 script installation on the ops VM failed. See $installLog"
  }
  Write-Host "ops VM ready: kubectl verified, $($files.Count) experiment 2 script(s) installed to /opt/experiment/scripts."
}

function Get-GkeNodeVmCreationCompletedUtc {
  # Reads T1 (= node VM creation finished) from the Cloud Logging audit log
  # instead of a polling watcher: the server-recorded millisecond timestamp has
  # no polling error, it needs no second process (= second clock), and it does
  # not run concurrently with the apply, so it cannot perturb the measurement.
  #
  # Careful: remove_default_node_pool=true makes GKE create and delete a
  # temporary 'gke-<cluster>-default-pool-*' instance. It appears early in
  # cluster creation, so without excluding it the timestamp lands minutes before
  # the real nodes.
  param(
    [string]$ProjectId,
    [string]$ClusterName,
    [datetime]$ApplyStartedUtc,
    [string]$LogDirectory
  )

  # Pin UTC here as well, so a caller passing a local time stays correct.
  # (With Kind=Unspecified, ToUniversalTime would assume local time and skew.)
  $startUtc = if ($ApplyStartedUtc.Kind -eq [System.DateTimeKind]::Utc) {
    $ApplyStartedUtc
  }
  else {
    $ApplyStartedUtc.ToUniversalTime()
  }
  $filter = @(
    'resource.type="gce_instance"',
    'protoPayload.methodName="v1.compute.instances.insert"',
    "protoPayload.resourceName:`"gke-$ClusterName-`"",
    'operation.last=true',
    ('timestamp>="{0}"' -f $startUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
  ) -join " AND "

  # Windows PowerShell 5.1 strips the double quotes from native command
  # arguments, which turns the colons of a timestamp (07:00:00) into a filter
  # syntax error ("Unparseable filter: syntax error ... token ':'"). Escaping
  # them makes the value arrive intact.
  $filterArg = $filter -replace '"', '\"'

  $raw = ""
  try {
    $ErrorActionPreference = "Continue"
    $raw = (& gcloud logging read $filterArg --project $ProjectId --order asc --limit 200 `
      --format "value(timestamp,protoPayload.resourceName)" | Out-String)
    $exit = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($exit -ne 0) {
    throw "Failed to read Cloud Logging audit entries for node VM creation."
  }
  Set-Content -Encoding UTF8 -Path (Join-Path $LogDirectory "node-vm-creation-audit.log") -Value $raw

  $latest = [datetime]::MinValue
  $matched = 0
  foreach ($line in ($raw -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "\s+"
    if ($parts.Count -lt 2) { continue }
    # The temporary default pool is not one of our nodes.
    if ($parts[1] -match "/instances/gke-$ClusterName-default-pool-") { continue }
    $stamp = [datetime]::MinValue
    if (-not [datetime]::TryParse($parts[0], [ref]$stamp)) { continue }
    $stamp = $stamp.ToUniversalTime()
    $matched++
    if ($stamp -gt $latest) { $latest = $stamp }
  }
  if ($matched -eq 0) {
    throw "No node VM creation audit entries found for cluster '$ClusterName' after $($ApplyStartedUtc.ToString('o')). Cloud Logging may be delayed; see node-vm-creation-audit.log"
  }
  Write-Host "Node VM creation audit: $matched completion event(s), last at $($latest.ToString('o'))."
  return $latest
}

function Get-PlanResourceChanges {
  param([string]$PlanJsonPath)
  $plan = Get-Content -LiteralPath $PlanJsonPath -Raw | ConvertFrom-Json
  $changes = @()
  if ($plan.PSObject.Properties.Name -contains "resource_changes" -and $null -ne $plan.resource_changes) {
    $changes = @($plan.resource_changes)
  }
  # Data source reads are not part of what the guard inspects.
  return @($changes | Where-Object { $_.mode -eq "managed" })
}

function Assert-GkeMeasurementPlan {
  # Measurement plan guard:
  #  - no delete/replace of any resource
  #  - zero changes to the ops VM (google_compute_instance.ops), for isolation
  #  - initial build: only 5 creates (cluster + bench/worker pool + compact
  #    policy + ssh firewall)
  #  - expansion: only 1 worker pool update
  param(
    [string]$PlanJsonPath,
    [bool]$IsExpansion,
    [int]$ExpectedWorkerCount
  )

  $changes = Get-PlanResourceChanges -PlanJsonPath $PlanJsonPath
  $nonNoop = @($changes | Where-Object { @($_.change.actions) -notcontains "no-op" -and @($_.change.actions).Count -gt 0 -and (@($_.change.actions) -join ",") -ne "read" })

  foreach ($change in $nonNoop) {
    $actions = @($change.change.actions)
    if ($actions -contains "delete") {
      throw "Plan guard: '$($change.address)' would be destroyed/replaced ($($actions -join '+')). The measurement plan must never delete resources."
    }
  }

  if (-not $IsExpansion) {
    $creates = @($nonNoop | Where-Object { @($_.change.actions) -contains "create" })
    # The ops VM runs measured T3 convergence and post-measurement T5 validation,
    # so it is created in the measured apply. depends_on makes it the last
    # resource created, after the GKE nodes fixed their sub-blocks.
    $expectedAddresses = @(
      "google_container_cluster.cluster",
      "google_container_node_pool.bench",
      "google_container_node_pool.worker",
      "google_compute_resource_policy.compact",
      "google_compute_firewall.ssh",
      "google_compute_instance.ops[0]"
    )
    $createAddresses = @($creates | ForEach-Object { $_.address } | Sort-Object)
    $missing = @($expectedAddresses | Where-Object { $createAddresses -notcontains $_ })
    $unexpected = @($createAddresses | Where-Object { $expectedAddresses -notcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
      throw "Plan guard: fresh 4-node plan must create exactly [$($expectedAddresses -join ', ')]. Missing: [$($missing -join ', ')]. Unexpected: [$($unexpected -join ', ')]."
    }
    if ($nonNoop.Count -ne $creates.Count) {
      $others = @($nonNoop | Where-Object { @($_.change.actions) -notcontains "create" } | ForEach-Object { "$($_.address)($((@($_.change.actions)) -join '+'))" })
      throw "Plan guard: fresh plan contains non-create changes: $($others -join ', ')."
    }
  }
  else {
    if ($nonNoop.Count -ne 1 -or
        $nonNoop[0].address -ne "google_container_node_pool.worker" -or
        (@($nonNoop[0].change.actions) -join ",") -ne "update") {
      $summary = @($nonNoop | ForEach-Object { "$($_.address)($((@($_.change.actions)) -join '+'))" })
      throw "Plan guard: expansion plan must contain exactly one update of google_container_node_pool.worker. Found: [$($summary -join ', ')]."
    }
    $afterNodeCount = [int]$nonNoop[0].change.after.node_count
    if ($afterNodeCount -ne $ExpectedWorkerCount) {
      throw "Plan guard: worker pool node_count after apply would be $afterNodeCount, expected $ExpectedWorkerCount."
    }
  }
  Write-Host "Plan guard passed ($(if ($IsExpansion) { 'expansion: worker pool resize only' } else { 'fresh: cluster + pools + policy + firewall' }))."
}

function Assert-GkeOpsPlan {
  # post-T5 ops VM plan guard: only one create of google_compute_instance.ops[0].
  param([string]$PlanJsonPath)

  $changes = Get-PlanResourceChanges -PlanJsonPath $PlanJsonPath
  $nonNoop = @($changes | Where-Object { @($_.change.actions) -notcontains "no-op" -and @($_.change.actions).Count -gt 0 -and (@($_.change.actions) -join ",") -ne "read" })
  if ($nonNoop.Count -ne 1 -or
      $nonNoop[0].address -notmatch '^google_compute_instance\.ops\[' -or
      (@($nonNoop[0].change.actions) -join ",") -ne "create") {
    $summary = @($nonNoop | ForEach-Object { "$($_.address)($((@($_.change.actions)) -join '+'))" })
    throw "Ops plan guard: expected exactly one create of google_compute_instance.ops[0]. Found: [$($summary -join ', ')]."
  }
  Write-Host "Ops plan guard passed (ops VM create only)."
}

function Assert-CompleteGkeTimeline {
  $expectedNames = @("T0", "T1", "T2", "T3", "T4", "T5")
  $points = @($script:Timeline | Where-Object { $expectedNames -contains $_.name })
  if ($points.Count -ne $expectedNames.Count) {
    throw "Timeline is incomplete: expected T0-T5 (6 points), found $($points.Count)."
  }
  if (@($script:Timeline | Where-Object { $_.name -eq "FAILURE" }).Count -gt 0) {
    throw "A successful timeline must not contain FAILURE."
  }
  for ($index = 0; $index -lt $expectedNames.Count; $index++) {
    if ($points[$index].name -ne $expectedNames[$index]) {
      throw "Timeline order mismatch at index ${index}."
    }
  }

  $applyTimings = @($script:CommandTimings | Where-Object { $_.name -eq "terraform apply" })
  if ($applyTimings.Count -eq 0) {
    throw "Timeline has T0/T1 but command-timings has no terraform apply record."
  }
  $applyTiming = $applyTimings[-1]
  if ([math]::Abs([double]$points[0].elapsed_ms - [double]$applyTiming.started_elapsed_ms) -gt 0.0005) {
    throw "T0 elapsed_ms does not match the terraform apply start boundary."
  }
  # T2 (= apply end) must match the apply boundary. T1 is an audit log timestamp
  # inside the apply window, so T0 < T1 < T2 must hold.
  if ([math]::Abs([double]$points[2].elapsed_ms - [double]$applyTiming.ended_elapsed_ms) -gt 0.0005) {
    throw "T2 elapsed_ms does not match the terraform apply end boundary."
  }
  if ([double]$points[1].elapsed_ms -le [double]$points[0].elapsed_ms -or
      [double]$points[1].elapsed_ms -ge [double]$points[2].elapsed_ms) {
    throw "T1 (node VM creation) must fall strictly inside the terraform apply window."
  }
  if ([double]$points[3].elapsed_ms -le [double]$points[2].elapsed_ms) {
    throw "T3 must be strictly later than T2 ('cilium status --wait' takes time)."
  }
  # GKE has no method-specific VPC task, so T4 shares the exact T3 boundary.
  if ([double]$points[4].elapsed_ms -ne [double]$points[3].elapsed_ms -or
      [long]$points[4].timestamp_unix_ms -ne [long]$points[3].timestamp_unix_ms) {
    throw "T4 must share the exact T3 boundary on GKE (no method-specific VPC task)."
  }
  if ([double]$points[5].elapsed_ms -le [double]$points[4].elapsed_ms) {
    throw "T5 must be strictly later than T4 (connectivity verification takes time)."
  }
}

function Write-ProvisioningSummary {
  param(
    [string]$Status,
    [object]$Failure = $null
  )

  if ($Status -eq "SUCCESS") {
    Assert-CompleteGkeTimeline
  }

  $endedAt = Get-Date
  $scriptDurationMs = $script:MonotonicClock.Elapsed.TotalMilliseconds
  $rows = @()
  $rows += New-ProvisioningDurationRow `
    -Name "script_total" `
    -Description "provision-gke.ps1 start to completion, including preflight, Terraform, ops VM convergence/connectivity, and post-T5 checks" `
    -StartedAt $script:ProvisioningStartedAt `
    -EndedAt $endedAt `
    -DurationMilliseconds $scriptDurationMs `
    -Status $Status

  $t0 = Get-TimelineEntry -Name "T0"
  $t1 = Get-TimelineEntry -Name "T1"
  $t4 = Get-TimelineEntry -Name "T4"

  $t2 = Get-TimelineEntry -Name "T2"
  $t3 = Get-TimelineEntry -Name "T3"

  # Interval meaning is kept identical to the kubeadm methods.
  foreach ($segment in @(
    [pscustomobject]@{ Name = "T0_to_T1"; From = $t0; To = $t1; Description = "terraform apply: node VM creation (kubeadm T0_to_T1 equivalent)" },
    [pscustomobject]@{ Name = "T1_to_T2"; From = $t1; To = $t2; Description = "GKE managed node registration/Ready and Dataplane V2 startup, until apply returns (kubeadm T1_to_T2 equivalent: bootstrap + kubeadm join + CNI install + nodes Ready)" },
    [pscustomobject]@{ Name = "T2_to_T3"; From = $t2; To = $t3; Description = "'cilium status --wait' from the ops VM (kubeadm T2_to_T3 equivalent)" }
  )) {
    if ($null -ne $segment.From -and $null -ne $segment.To) {
      $rows += New-ProvisioningDurationRow `
        -Name $segment.Name `
        -Description $segment.Description `
        -StartedAt ([datetime]::Parse($segment.From.timestamp)) `
        -EndedAt ([datetime]::Parse($segment.To.timestamp)) `
        -DurationMilliseconds ([double]$segment.To.elapsed_ms - [double]$segment.From.elapsed_ms) `
        -Status $Status
    }
  }

  # T3~T4: GKE has no method-specific VPC task (Alias IPs are automatic), so it
  # is recorded as a literal 0 without re-measuring, like kubeadm VXLAN/Host.
  if ($null -ne $t3) {
    $rows += New-ProvisioningDurationRow `
      -Name "T3_to_T4" `
      -Description "method-specific VPC task (none on GKE: VPC-native assigns Alias IP at node creation, recorded as immediate no-op)" `
      -StartedAt ([datetime]::Parse($t3.timestamp)) `
      -EndedAt ([datetime]::Parse($t3.timestamp)) `
      -DurationMilliseconds 0 `
      -Status $Status
  }

  if ($null -ne $t0 -and $null -ne $t4) {
    $rows += New-ProvisioningDurationRow `
      -Name "T0_to_T4" `
      -Description "total provisioning time (experiment 1 metric)" `
      -StartedAt ([datetime]::Parse($t0.timestamp)) `
      -EndedAt ([datetime]::Parse($t4.timestamp)) `
      -DurationMilliseconds ([double]$t4.elapsed_ms - [double]$t0.elapsed_ms) `
      -Status $Status
  }

  if ($Status -eq "SUCCESS") {
    $intervalRows = @($rows | Where-Object { $_.name -in @("T0_to_T1", "T1_to_T2", "T2_to_T3", "T3_to_T4") })
    $totalRows = @($rows | Where-Object { $_.name -eq "T0_to_T4" })
    if ($intervalRows.Count -ne 4 -or $totalRows.Count -ne 1) {
      throw "Successful timeline did not produce all four intervals and T0_to_T4."
    }
    $zeroRow = @($intervalRows | Where-Object { $_.name -eq "T3_to_T4" })[0]
    if ([double]$zeroRow.duration_milliseconds -ne 0) {
      throw "T3_to_T4 must be a literal constant 0 on GKE (no method-specific VPC task)."
    }
    $intervalSum = ($intervalRows | Measure-Object -Property duration_milliseconds -Sum).Sum
    if ([math]::Abs([double]$intervalSum - [double]$totalRows[0].duration_milliseconds) -gt 0.005) {
      throw "Timeline duration arithmetic mismatch: interval sum does not equal T0_to_T4."
    }
  }

  $hasT0 = $null -ne $t0
  $summary = [pscustomobject]@{
    status               = $Status
    experiment_name      = $script:ExperimentName
    experiment_label     = $script:ExperimentLabel
    node_count           = $script:ExpectedNodeCount
    actual_node_count    = $script:ActualNodeCount
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
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:ProvisioningSummaryCsvPath
  }
}

# -- main --------------------------------------------------------------------

Assert-Command "terraform"
Assert-Command "gcloud"
# ops VM and node access use Windows OpenSSH directly (no PuTTY plink).
Assert-Command "ssh"
# Needed to load the experiment 2 tool image. Checked before T0 so a missing
# Docker cannot waste a whole iteration by surfacing only after T5.
Assert-Command "scp"
Assert-Command "docker"

$script:Timeline = @()
$script:CommandTimings = @()
# Every relative path (infra/, results/) is resolved against this directory, so
# the tree can be copied anywhere and still runs.
$WorkspaceRoot = $PSScriptRoot
$TfDirFull = Resolve-WorkspacePath -Path $TfDir -BasePath $WorkspaceRoot
$VarFileFull = Resolve-TfvarsPath -Path $VarFile -BasePath $WorkspaceRoot
$script:OutDirFull = Join-WorkspacePath -Path $OutDir -BasePath $WorkspaceRoot
New-Item -ItemType Directory -Force -Path $script:OutDirFull | Out-Null
$script:OpsKnownHostsPath = Join-Path $script:OutDirFull "ops_known_hosts"
$script:OpsSshTarget = ""
$script:OpsSshKeyFile = ""
$script:CommandTimingsJsonPath = Join-Path $script:OutDirFull "command-timings.json"
$script:CommandTimingsCsvPath = Join-Path $script:OutDirFull "command-timings.csv"
$script:ProvisioningSummaryJsonPath = Join-Path $script:OutDirFull "provisioning-summary.json"
$script:ProvisioningSummaryCsvPath = Join-Path $script:OutDirFull "provisioning-summary-failed.csv"
$failureReportPath = Join-Path $script:OutDirFull "failure-report.json"

$planFile = Join-Path $script:OutDirFull "terraform.tfplan"
$planJson = Join-Path $script:OutDirFull "terraform-plan.json"
$applyLog = Join-Path $script:OutDirFull "terraform-apply.jsonl"
$opsPlanFile = Join-Path $script:OutDirFull "terraform-ops.tfplan"
$opsPlanJson = Join-Path $script:OutDirFull "terraform-ops-plan.json"
$opsApplyLog = Join-Path $script:OutDirFull "terraform-ops-apply.jsonl"

try {
  Set-Step "parse tfvars"
  $projectId = Get-TfVarString -Path $VarFileFull -Name "project_id"
  $networkName = Get-TfVarString -Path $VarFileFull -Name "network_name"
  $subnetworkName = Get-TfVarString -Path $VarFileFull -Name "subnetwork_name"
  if ([string]::IsNullOrWhiteSpace($projectId) -or [string]::IsNullOrWhiteSpace($networkName) -or
      [string]::IsNullOrWhiteSpace($subnetworkName)) {
    throw "project_id, network_name, and subnetwork_name must be literal string values in $VarFileFull."
  }
  $experimentNameFromTfvars = Get-TfVarString -Path $VarFileFull -Name "experiment_name"
  if ([string]::IsNullOrWhiteSpace($experimentNameFromTfvars)) { $experimentNameFromTfvars = "cloud" }
  if ($experimentNameFromTfvars -ne $script:ExperimentName) {
    throw "experiment_name '$experimentNameFromTfvars' must be 'cloud' (the CSV label stays GKE while the Terraform token stays cloud)."
  }
  $configuredPrefix = Get-TfVarString -Path $VarFileFull -Name "prefix"
  $resourcePrefix = if ([string]::IsNullOrWhiteSpace($configuredPrefix)) { $experimentNameFromTfvars } else { $configuredPrefix }
  $clusterName = $resourcePrefix
  $region = Get-TfVarScalar -Path $VarFileFull -Name "region"
  if ([string]::IsNullOrWhiteSpace($region)) { $region = "asia-northeast3" }
  $zone = Get-TfVarScalar -Path $VarFileFull -Name "zone"
  if ([string]::IsNullOrWhiteSpace($zone)) { $zone = "asia-northeast3-a" }
  $machineType = Get-TfVarScalar -Path $VarFileFull -Name "machine_type"
  if ([string]::IsNullOrWhiteSpace($machineType)) { $machineType = "c2-standard-4" }
  $diskSizeGbRaw = Get-TfVarScalar -Path $VarFileFull -Name "disk_size_gb"
  $diskSizeGb = if ([string]::IsNullOrWhiteSpace($diskSizeGbRaw)) { 25 } else { [int]$diskSizeGbRaw }
  $gkeVersion = Get-TfVarString -Path $VarFileFull -Name "gke_version"
  if ([string]::IsNullOrWhiteSpace($gkeVersion)) { $gkeVersion = "1.35.6-gke.1641000" }
  $ciliumCliVersion = Get-TfVarString -Path $VarFileFull -Name "cilium_cli_version"
  if ([string]::IsNullOrWhiteSpace($ciliumCliVersion)) { $ciliumCliVersion = "v0.19.5" }
  $podCidr = Get-TfVarString -Path $VarFileFull -Name "pod_cidr"
  if ([string]::IsNullOrWhiteSpace($podCidr)) { $podCidr = "10.244.0.0/16" }
  if ($podCidr -ne "10.244.0.0/16") {
    throw "N-Cloud requires pod_cidr = 10.244.0.0/16, found '$podCidr'."
  }

  $tfvarsWorkerRaw = Get-TfVarScalar -Path $VarFileFull -Name "worker_count"
  $tfvarsWorker = if ([string]::IsNullOrWhiteSpace($tfvarsWorkerRaw)) { 2 } else { [int]$tfvarsWorkerRaw }
  $effectiveWorkerCount = if ($WorkerCount -gt 0) { $WorkerCount } else { $tfvarsWorker }
  if ($effectiveWorkerCount -lt 2) {
    throw "worker_count must be at least 2, got $effectiveWorkerCount."
  }
  # CSV label: 4/8 = worker + benchmark + managed control plane. Real nodes: worker + 1.
  $script:ExpectedNodeCount = $effectiveWorkerCount + 2
  $script:ActualNodeCount = $effectiveWorkerCount + 1

  Set-Step "validate gcloud authentication"
  $activeAccounts = @(& gcloud auth list --filter "status:ACTIVE" --format "value(account)")
  if ($LASTEXITCODE -ne 0 -or @($activeAccounts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
    throw "No active gcloud account. Run 'gcloud auth login' before provisioning."
  }

  Set-Step "legacy kubeadm N-Cloud environment check"
  # The prefix 'cloud' is shared with a kubeadm infra/cloud environment, so both
  # must never exist at once. cloud-cp-0 only exists in the kubeadm environment
  # and is a definitive marker.
  $legacyCp = @(Get-GcloudValueLines -Arguments @(
    "compute", "instances", "list",
    "--project", $projectId,
    "--filter", "name=$resourcePrefix-cp-0",
    "--format", "value(name)"
  ))
  if ($legacyCp.Count -gt 0) {
    throw "Legacy kubeadm N-Cloud environment detected ($($legacyCp -join ', ')). Destroy the kubeadm N-Cloud environment first before provisioning the GKE variant."
  }

  Set-Step "terraform init"
  Invoke-Native -File "terraform" -Arguments @("init", "-input=false", "-upgrade=false") -WorkingDirectory $TfDirFull -LogPath (Join-Path $script:OutDirFull "terraform-init.log") -TimingName "terraform init"
  Select-ExperimentTerraformWorkspace -TfDirFull $TfDirFull -Workspace $script:TerraformWorkspace -CreateIfMissing $true

  Set-Step "inspect existing terraform state"
  # A function returning an array is unrolled by the pipeline (0 -> $null,
  # 1 -> scalar), so the caller re-wraps it in @() to keep .Count valid under
  # StrictMode.
  $stateResources = @(Get-TerraformStateResources -TfDirFull $TfDirFull)
  $clusterInState = $stateResources -contains "google_container_cluster.cluster"
  $opsInState = @($stateResources | Where-Object { $_ -match '^google_compute_instance\.ops(\[|$)' }).Count -gt 0
  $currentWorkers = 0
  if ($clusterInState) {
    $currentWorkersRaw = Get-TerraformOutputRawOptional -TfDirFull $TfDirFull -Name "worker_node_count"
    if ([string]::IsNullOrWhiteSpace($currentWorkersRaw)) {
      throw "Cluster exists in state but the worker_node_count output is unreadable. The previous apply may have failed mid-way; inspect the state before continuing."
    }
    $currentWorkers = [int]$currentWorkersRaw
  }
  Write-Host "State: cluster=$clusterInState, workers=$currentWorkers, opsVm=$opsInState, resources=$($stateResources.Count)"

  if ($RequiredExistingWorkers -ge 0) {
    if ($RequiredExistingWorkers -eq 0) {
      if ($clusterInState -or $stateResources.Count -gt 0) {
        throw "4-node run requires an empty Terraform state, but found $($stateResources.Count) resource(s) (cluster=$clusterInState). Destroy first (.\destroy-gke.ps1)."
      }
    }
    else {
      if (-not $clusterInState) {
        throw "Expansion requires an existing cluster in state, but none was found. Run the 4-node provisioning first."
      }
      if ($currentWorkers -ne $RequiredExistingWorkers) {
        throw "Expansion requires exactly $RequiredExistingWorkers existing workers in state, found $currentWorkers."
      }
    }
  }
  $isExpansion = $clusterInState
  if ($isExpansion -and $effectiveWorkerCount -le $currentWorkers) {
    throw "Expansion must increase the worker pool: current=$currentWorkers, requested=$effectiveWorkerCount."
  }

  # No Cloud Shell preflight: T3/T5 run on the ops VM, so the Cloud Shell
  # dependency is gone. The ops VM is created by the apply and cannot be checked
  # before T0; instead Wait-OpsVmReady asserts bootstrap, CLI versions and
  # kubectl right after the apply.

  if (-not $SkipQuotaPreflight) {
    Set-Step "quota preflight"
    # Only newly created VMs are checked. When the post-T5 phase of this
    # iteration also creates the ops VM (c2-standard-4), that one is included;
    # on an expansion, where the ops VM already exists, it is not.
    $newNodes = ($script:ActualNodeCount) - $(if ($clusterInState) { $currentWorkers + 1 } else { 0 })
    $newVmCount = $newNodes + $(if ($opsInState) { 0 } else { 1 })
    if ($newVmCount -gt 0) {
      & (Join-Path $PSScriptRoot "check-gcp-quota.ps1") `
        -ProjectId $projectId `
        -Region $region `
        -MachineType $machineType `
        -NodeCount $newVmCount `
        -DiskSizeGb $diskSizeGb `
        -DiskType "pd-balanced" `
        -AllowExternalIp $true `
        -OutDir $script:OutDirFull
    }
    else {
      Write-Host "No new VM to create; skipping regional VM quota checks."
    }
  }

  Set-Step "claim result iteration"
  Initialize-RunResultFile `
    -Method $script:ResultMethodLabel `
    -NodeCount $script:ExpectedNodeCount `
    -Experiment $script:ExperimentLabel `
    -PlanOnly ([bool]$SkipApply)

  Set-Step "terraform plan"
  # Measured plan: the ops VM flag is passed as whatever the state already has,
  # so no ops VM change is planned. The ops VM is the T5 execution host and is
  # always part of the measured apply.
  $createOpsVmVar = "true"
  $planArguments = @(
    "plan",
    "-input=false",
    "-var-file=$VarFileFull",
    "-var=worker_count=$effectiveWorkerCount",
    "-var=create_ops_vm=$createOpsVmVar",
    "-out=$planFile"
  )
  Invoke-Native -File "terraform" -Arguments $planArguments -WorkingDirectory $TfDirFull -LogPath (Join-Path $script:OutDirFull "terraform-plan.log") -TimingName "terraform plan"
  Invoke-Native -File "terraform" -Arguments @("show", "-json", $planFile) -WorkingDirectory $TfDirFull -LogPath $planJson -TimingName "terraform show plan json"

  Set-Step "terraform plan guard"
  Assert-GkeMeasurementPlan -PlanJsonPath $planJson -IsExpansion $isExpansion -ExpectedWorkerCount $effectiveWorkerCount

  if ($SkipApply) {
    Write-ProvisioningSummary -Status "PLAN_ONLY"
    $script:RunCompleted = $true
    Write-Host "SkipApply was set. Terraform plan and guard checks completed; no resources were created."
    exit 0
  }

  Set-Step "terraform apply"
  $script:ApplyStarted = $true
  Invoke-Native -File "terraform" -Arguments @("apply", "-json", $planFile) -WorkingDirectory $TfDirFull -LogPath $applyLog -TimingName "terraform apply"
  $applyTiming = @($script:CommandTimings | Where-Object { $_.name -eq "terraform apply" })[-1]
  # [datetime]::Parse returns Kind=Local even for a "...Z" ISO string.
  # Add-Timeline calls ToUniversalTime internally, so that was harmless there,
  # but anywhere the value is formatted directly (the Cloud Logging filter) it
  # would print KST as UTC and query nine hours into the future (observed: zero
  # results). It is pinned to UTC here.
  $applyStartedUtc = [datetime]::Parse($applyTiming.started_at).ToUniversalTime()
  $applyEndedUtc = [datetime]::Parse($applyTiming.ended_at).ToUniversalTime()
  $applyStartedElapsed = [double]$applyTiming.started_elapsed_ms
  $applyEndedElapsed = [double]$applyTiming.ended_elapsed_ms

  Add-Timeline -Name "T0" -Description "terraform apply started" -Data @{
    command             = "terraform apply -json $planFile"
    node_count_label    = $script:ExpectedNodeCount
    actual_node_target  = $script:ActualNodeCount
    existing_workers    = $currentWorkers
    is_expansion        = $isExpansion
  } -TimestampUtc $applyStartedUtc -ElapsedMilliseconds $applyStartedElapsed
  # T1 = node VM creation finished (same meaning as the kubeadm T1). It uses the
  # server-side timestamp of the Cloud Logging audit log, converted onto the
  # monotonic axis relative to the T0 boundary. The clock source is a GCP server
  # and therefore mixes with T0/T2 (local process boundaries), which is stated
  # in the results.
  Set-Step "resolve T1 (node VM creation) from Cloud Logging"
  $nodeVmCreatedUtc = Get-GkeNodeVmCreationCompletedUtc -ProjectId $projectId -ClusterName $clusterName `
    -ApplyStartedUtc $applyStartedUtc -LogDirectory $script:OutDirFull
  if ($nodeVmCreatedUtc -lt $applyStartedUtc -or $nodeVmCreatedUtc -gt $applyEndedUtc) {
    throw "Node VM creation time $($nodeVmCreatedUtc.ToString('o')) is outside the terraform apply window ($($applyStartedUtc.ToString('o')) ~ $($applyEndedUtc.ToString('o')))."
  }
  $nodeVmCreatedElapsed = $applyStartedElapsed + ($nodeVmCreatedUtc - $applyStartedUtc).TotalMilliseconds
  Add-Timeline -Name "T1" -Description "node VM creation completed (last v1.compute.instances.insert audit entry; excludes the temporary GKE default pool)" -Data @{
    clock_source = "gcp-audit-log"
    audit_log    = "node-vm-creation-audit.log"
  } -TimestampUtc $nodeVmCreatedUtc -ElapsedMilliseconds $nodeVmCreatedElapsed

  Add-Timeline -Name "T2" -Description "terraform apply completed: nodes registered/Ready and Dataplane V2 up (managed creation covers kubeadm's join + CNI install)" -Data @{
    duration_milliseconds = $applyTiming.duration_milliseconds
    duration_seconds      = $applyTiming.duration_seconds
    log_path              = $applyLog
    gke_version           = $gkeVersion
  } -TimestampUtc $applyEndedUtc -ElapsedMilliseconds $applyEndedElapsed

  Write-StageNotice -Message @(
    "[T0~T2 done] apply completed in $([math]::Round([double]$applyTiming.duration_seconds, 1))s (T1 = node VM creation, T2 = apply end).",
    "Next: T2~T3 = 'cilium status --wait' (same criterion as kubeadm T3)."
  )

  # -- ops VM readiness (finished before T4 so it stays out of the measurement)
  # The ops VM was created by the same apply and its bootstrap runs
  # asynchronously, overlapping cluster creation. Checking the marker here keeps
  # that wait out of T3~T4.
  Set-Step "ops VM readiness (outside T3~T4 measurement)"
  $opsName = "$resourcePrefix-ops-0"
  $opsDescribeRaw = (& gcloud compute instances describe $opsName --project $projectId --zone $zone --format json | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw "ops VM describe failed for $opsName."
  }
  $opsVm = $opsDescribeRaw | ConvertFrom-Json
  $opsExternalIp = [string]$opsVm.networkInterfaces[0].accessConfigs[0].natIP
  if ([string]::IsNullOrWhiteSpace($opsExternalIp)) {
    throw "ops VM has no external IP; T5 cannot run there."
  }
  $sshUser = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "ssh_user"
  $sshKeyRaw = Get-TerraformOutputRaw -TfDirFull $TfDirFull -Name "ssh_private_key_path"
  $sshPrivateKeyFull = if ([System.IO.Path]::IsPathRooted($sshKeyRaw)) { $sshKeyRaw } else { Join-Path $TfDirFull $sshKeyRaw }
  if (-not (Test-Path -LiteralPath $sshPrivateKeyFull -PathType Leaf)) {
    throw "SSH private key not found for ops VM access: $sshPrivateKeyFull"
  }
  $script:OpsSshTarget = "$sshUser@$opsExternalIp"
  $script:OpsSshKeyFile = $sshPrivateKeyFull
  Wait-OpsVmReady -ProjectId $projectId -Zone $zone -ClusterName $clusterName `
    -CiliumCliVersion $ciliumCliVersion -LogDirectory $script:OutDirFull

  # -- T4: GKE dataplane convergence (counterpart of `cilium status --wait`) --
  Set-Step "T3~T4: GKE dataplane convergence via ops VM"
  $convergenceTemplate = @'
#!/usr/bin/env bash
set -euxo pipefail
export PATH="/usr/local/bin:$PATH"
EXPECTED_NODES=__EXPECTED_NODES__

# A finished terraform apply only means the node pools exist; it does not
# guarantee the system pods converged. GKE proxies control plane -> node traffic
# (kubectl exec) through konnectivity, so before konnectivity-agent is ready an
# exec fails with "No agent available" and the cilium connectivity test dies
# during feature detection (which execs into anetd).
kubectl wait --for=condition=Ready node --all --timeout=15m
test "$(kubectl get nodes --no-headers | wc -l)" -eq "$EXPECTED_NODES"
kubectl -n kube-system rollout status ds/anetd --timeout=15m
# Wait until exec over konnectivity works (cilium status also execs the agent).
timeout 900 bash -c 'until kubectl exec -n kube-system ds/anetd -c cilium-agent -- true >/dev/null 2>&1; do sleep 2; done'

# The CLI `cilium status --wait` cannot be used on GKE:
#   - plain form: "Unable to determine status: timeout ... context deadline
#     exceeded" (GKE has neither a 'cilium' DaemonSet nor a 'cilium-operator'
#     Deployment)
#   - `--agent-daemonset-name` is a `connectivity test` flag and does not exist
#     on status
#
# Instead the agent binary inside anetd is asked directly. It has the same name
# but it is the in-container `cilium` command, not the CLI, and it works on GKE.
# `rollout status` checks the DaemonSet ready count (the same aggregate the CLI
# looks at) and the exec below checks that the agent actually answers and that
# the runtime config cilium-cli reads during feature detection is reachable.
#
# Only one pod is inspected: iterating over every node would scale the
# konnectivity exec cost with the node count (+2.7s measured at 8 nodes) and the
# T2~T3 check would no longer be equally strict across methods. The agent state
# of every node is already reflected in the rollout status above through the
# readiness probe.
kubectl exec -n kube-system ds/anetd -c cilium-agent -- sh -c \
  'cilium status >/dev/null && cat /var/run/cilium/state/agent-runtime-config.json >/dev/null'
echo "CILIUM_STATUS_MODE=in-pod-agent-status"
echo "GKE_CONVERGENCE_OK"
'@
  $convergenceScript = $convergenceTemplate.Replace("__EXPECTED_NODES__", [string]$script:ActualNodeCount)
  $convergenceLog = Join-Path $script:OutDirFull "ops-t4-convergence.log"
  Invoke-OpsVmScript -ScriptContent $convergenceScript -RemoteName "gke-t4-convergence.sh" `
    -LogPath $convergenceLog -TimingName "ops vm dataplane convergence"
  if ((Get-Content -LiteralPath $convergenceLog -Raw) -notmatch "GKE_CONVERGENCE_OK") {
    throw "GKE dataplane convergence did not report GKE_CONVERGENCE_OK. See $convergenceLog"
  }
  $ciliumStatusMode = "unknown"
  if ((Get-Content -LiteralPath $convergenceLog -Raw) -match "CILIUM_STATUS_MODE=(\S+)") {
    $ciliumStatusMode = $Matches[1]
    if ($ciliumStatusMode -ne "default") {
      Write-Warning "cilium status --wait needed an override on this cluster (mode=$ciliumStatusMode). Record this with the round."
    }
  }
  Add-Timeline -Name "T3" -Description "Cilium ready: all nodes Ready, anetd rolled out, and every node's agent reports status + runtime config (GKE equivalent of kubeadm's 'cilium status --wait', which the CLI cannot provide here)" -Data @{
    log_path           = $convergenceLog
    cilium_status_mode = $ciliumStatusMode
  }
  # T4 = method-specific VPC task. GKE is VPC-native and assigns Alias IPs when
  # the node is created, so there is nothing to do. Like kubeadm VXLAN/Host it
  # shares the T3 boundary exactly and is recorded as a constant 0, free of
  # instrumentation and file I/O overhead.
  $t3Boundary = Get-TimelineEntry -Name "T3"
  Add-Timeline -Name "T4" -Description "GKE has no method-specific VPC task (VPC-native assigns Alias IP at node creation); T4 shares the T3 boundary (no-op)" -Data @{
    measured = $false
    reason   = "Alias IP is assigned by GKE at node creation; no separate VPC task"
  } -TimestampUtc ([datetime]::Parse($t3Boundary.timestamp)) -ElapsedMilliseconds ([double]$t3Boundary.elapsed_ms)
  Write-StageNotice -Message @(
    "[T3=T4 done] Cilium is ready and GKE requires no VPC task. Next: T5 post-measurement connectivity validation."
  )

  Set-Step "T5: post-measurement connectivity validation via ops VM"
  # Keeps the same assertions as the kubeadm T5 verification script
  # (provision.ps1), with two GKE adaptations:
  #  1) --agent-daemonset-name anetd (the Cilium DaemonSet name of GKE DPv2)
  #  2) anchor/target are chosen as the first/last name-sorted node carrying
  #     experiment-role=worker instead of coming from the inventory, because GKE
  #     node names are generated.
  $t5Template = @'
#!/usr/bin/env bash
set -euxo pipefail

# The pinned Cilium CLI is installed by the preflight into ~/.local/bin, which
# survives between sessions. A non-interactive SSH does not read .profile, so
# PATH is extended explicitly.
export PATH="$HOME/.local/bin:$PATH"

PROJECT="__PROJECT__"
ZONE="__ZONE__"
CLUSTER="__CLUSTER__"
EXPECTED_WORKERS=__EXPECTED_WORKERS__
EXPECTED_CLI_VERSION="__CILIUM_CLI_VERSION__"
TEST_NAMESPACE=cilium-cloud-connectivity
PAIR_LABEL=experiment-cilium-endpoint
AGENT_DAEMONSET=anetd
EXPECTED_ACTIONS_PER_PAIR=6
JUNIT_FILE=/tmp/cilium-cloud-connectivity.xml
PAIR_LOG=/tmp/cilium-cloud-connectivity-pair.log
PAIR_SUMMARY=/tmp/cilium-cloud-connectivity-pair.tsv

# Re-check the pinned CLI (part of the per-iteration invariants)
cilium version --client 2>/dev/null | grep -F "$EXPECTED_CLI_VERSION" >/dev/null

gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --quiet

# Convergence was already awaited in T3~T4 (ops-t4-convergence.log). This step
# measures the connectivity test time alone.

mapfile -t WORKERS < <(kubectl get nodes -l experiment-role=worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
if [[ "${#WORKERS[@]}" -ne "$EXPECTED_WORKERS" ]]; then
  echo "expected $EXPECTED_WORKERS worker nodes, found ${#WORKERS[@]}" >&2
  exit 1
fi
ANCHOR_NODE="${WORKERS[0]}"
TARGET_NODE="${WORKERS[$((${#WORKERS[@]}-1))]}"

clear_pair_labels() {
  kubectl label nodes -l experiment-role=worker "$PAIR_LABEL-" --overwrite >/dev/null 2>&1 || true
}
trap clear_pair_labels EXIT

if [[ "$TARGET_NODE" == "$ANCHOR_NODE" ]]; then
  echo "worker-0 and last worker must be different nodes: $ANCHOR_NODE" >&2
  exit 1
fi

cilium connectivity test --cleanup --test-namespace "$TEST_NAMESPACE" --agent-daemonset-name "$AGENT_DAEMONSET"
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
  --agent-daemonset-name "$AGENT_DAEMONSET" \
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
  echo "Cloud(GKE) T5 must use regular Pod networking, found $HOSTNETWORK_POD_COUNT hostNetwork workload(s)." >&2
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

echo "T5_CONNECTIVITY_OK anchor=$ANCHOR_NODE target=$TARGET_NODE namespace=$RUN_NAMESPACE"
'@
  $t5Script = $t5Template.
    Replace("__PROJECT__", $projectId).
    Replace("__ZONE__", $zone).
    Replace("__CLUSTER__", $clusterName).
    Replace("__EXPECTED_WORKERS__", [string]$effectiveWorkerCount).
    Replace("__CILIUM_CLI_VERSION__", $ciliumCliVersion)
  $t5Log = Join-Path $script:OutDirFull "ops-t5-connectivity.log"
  Invoke-OpsVmScript `
    -ScriptContent $t5Script `
    -RemoteName "gke-t5-connectivity.sh" `
    -LogPath $t5Log `
    -TimingName "ops vm connectivity test"
  $t5Output = Get-Content -LiteralPath $t5Log -Raw
  if ($t5Output -notmatch "T5_CONNECTIVITY_OK") {
    throw "ops VM connectivity test did not report T5_CONNECTIVITY_OK. See $t5Log"
  }
  Add-Timeline -Name "T5" -Description "worker-0 to last-worker Cilium no-policies/pod-to-pod connectivity verified from the ops VM (1 test / 6 actions, workload placement asserted)" -Data @{
    log_path = $t5Log
  }
  # T5 is retained as the required connectivity validation point, but it is not
  # part of the experiment 1 duration metric. Snapshot the final format (6 POINT
  # + 6 DURATION) here so later post-T5 checks cannot lose the measurement.
  Assert-CompleteGkeTimeline
  Write-ProvisioningSummary -Status "RUNNING"
  $t0Point = Get-TimelineEntry -Name "T0"
  $t4Point = Get-TimelineEntry -Name "T4"
  $totalProvisioningMs = [math]::Round(([double]$t4Point.elapsed_ms) - ([double]$t0Point.elapsed_ms))
  Write-StageNotice -Message @(
    "[T5 done] CLOUD(GKE) connectivity succeeded between the first and last worker.",
    "T0~T4 provisioning measurements are complete. (T0_to_T4 = $totalProvisioningMs ms; T5 is validation only)",
    "Subsequent output is post-T5 verification outside the measurement (TERMINATE, ops VM, sanity)."
  )

  # -- post-T5: outside the measured window ---------------------------------

  Set-Step "post-T5: list GKE node instances"
  $nodeInstances = @(Get-GcloudValueLines -Arguments @(
    "compute", "instances", "list",
    "--project", $projectId,
    "--zones", $zone,
    "--filter", "labels.goog-k8s-cluster-name=$clusterName",
    "--format", "value(name)"
  ))
  if ($nodeInstances.Count -ne $script:ActualNodeCount) {
    throw "Expected $($script:ActualNodeCount) GKE node instances, found $($nodeInstances.Count): $($nodeInstances -join ', ')"
  }

  Set-Step "post-T5: disable live migration (set-scheduling TERMINATE) on all node VMs"
  # The GKE API does not expose onHostMaintenance, but the nodes are ordinary
  # Compute VMs, so it is applied at instance level. With auto-repair and
  # auto-upgrade off it persists unless a node is recreated.
  foreach ($nodeInstance in $nodeInstances) {
    Invoke-Native -File "gcloud" `
      -Arguments @("compute", "instances", "set-scheduling", $nodeInstance, "--project", $projectId, "--zone", $zone, "--maintenance-policy", "TERMINATE") `
      -WorkingDirectory $script:OutDirFull `
      -LogPath (Join-Path $script:OutDirFull "set-scheduling-$nodeInstance.log") `
      -TimingName "set-scheduling $nodeInstance"
  }

  Set-Step "post-T5: verify GKE compact placement on both node pools"
  # Of the two options in the GKE compact-placement documentation this uses
  # --placement-policy (a user-defined policy). --placement-type=COMPACT makes
  # GKE generate a separate policy per node pool, which would put the bench pool
  # and the worker pool in different collocation groups and stop guaranteeing
  # proximity on the Benchmark pod (bench) <-> Server pod (worker-0) path. The
  # documentation names "multiple node pools with the same placement policy" as
  # the purpose of a user-defined policy, so both pools share one policy. This
  # step asserts that configuration really landed, at node pool level.
  $expectedPolicyName = "$resourcePrefix-compact"
  foreach ($poolName in @("bench", "worker")) {
    $poolJsonRaw = (& gcloud container node-pools describe $poolName --cluster $clusterName --zone $zone --project $projectId --format json | Out-String)
    if ($LASTEXITCODE -ne 0) {
      throw "gcloud container node-pools describe failed for '$poolName'."
    }
    $pool = $poolJsonRaw | ConvertFrom-Json
    $poolPlacement = $null
    if ($pool.PSObject.Properties.Name -contains "placementPolicy") {
      $poolPlacement = $pool.placementPolicy
    }
    if ($null -eq $poolPlacement) {
      throw "Node pool '$poolName' has no placementPolicy; compact placement was not applied."
    }
    # Careful: on PS 5.1 [type](if ...) parses but fails at runtime because 'if'
    # is then treated as a command. Use a statement assignment or $(...) only.
    $poolPlacementType = ""
    if ($poolPlacement.PSObject.Properties.Name -contains "type") {
      $poolPlacementType = [string]$poolPlacement.type
    }
    $poolPolicyName = ""
    if ($poolPlacement.PSObject.Properties.Name -contains "policyName") {
      $poolPolicyName = [string]$poolPlacement.policyName
    }
    if ($poolPlacementType -ne "COMPACT") {
      throw "Node pool '$poolName' placementPolicy.type is '$poolPlacementType', expected COMPACT."
    }
    if ($poolPolicyName -ne $expectedPolicyName) {
      throw "Node pool '$poolName' placementPolicy.policyName is '$poolPolicyName', expected the shared custom policy '$expectedPolicyName'. Both pools must share one policy so the bench and worker nodes are colocated."
    }
    Write-Host "  compact placement verified on pool '$poolName': type=COMPACT, policyName=$poolPolicyName"
  }

  Set-Step "post-T5: control variable checks (GKE profile)"
  # Physical placement check: a GKE policy cannot use max_distance (see
  # infra/gke/main.tf), so only collocation applies. Whether the nodes really
  # landed on one rack is therefore measured through resourceStatus.physicalHost,
  # exactly like check-control-vars.ps1 does for the kubeadm methods.
  $describeByName = @{}
  foreach ($nodeInstance in $nodeInstances) {
    $describeJsonRaw = (& gcloud compute instances describe $nodeInstance --project $projectId --zone $zone --format json | Out-String)
    if ($LASTEXITCODE -ne 0) {
      throw "gcloud describe failed for $nodeInstance."
    }
    $describeByName[$nodeInstance] = $describeJsonRaw | ConvertFrom-Json
  }
  $rackIdByName = @{}
  foreach ($nodeInstance in $nodeInstances) {
    $vmForRack = $describeByName[$nodeInstance]
    $physicalHostValue = ""
    if ($vmForRack.PSObject.Properties.Name -contains "resourceStatus" -and $null -ne $vmForRack.resourceStatus -and
        $vmForRack.resourceStatus.PSObject.Properties.Name -contains "physicalHost") {
      $physicalHostValue = [string]$vmForRack.resourceStatus.physicalHost
    }
    $rackParts = @($physicalHostValue -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $rackIdByName[$nodeInstance] = if ($rackParts.Count -lt 2) { "" } else { "$($rackParts[0])/$($rackParts[1])" }
  }
  $observedRackIds = @($rackIdByName.Values | Where-Object { $_ })
  $sameRack = ($observedRackIds.Count -eq $nodeInstances.Count) -and
              (@($observedRackIds | Select-Object -Unique).Count -eq 1)
  # The GKE documentation calls compact placement best effort ("it might not be
  # possible to create a large node pool using a compact placement policy"). If
  # the policy is attached but the placement crossed racks, the iteration fails
  # as a control-variable violation by default, because max_distance=1 is not
  # available and this measurement is the only guarantee. -AllowRackSpread
  # records the deviation and continues instead.
  if (-not $sameRack) {
    $rackSummary = ($nodeInstances | ForEach-Object { "$_=$($rackIdByName[$_])" }) -join ", "
    if ($AllowRackSpread) {
      Write-Warning "GKE nodes are not all on the same rack ($rackSummary). Continuing because -AllowRackSpread was set; record this deviation with the round's results."
    }
    else {
      Write-Host "Node rack placement: $rackSummary" -ForegroundColor Yellow
    }
  }

  $controlRows = @()
  foreach ($nodeInstance in $nodeInstances) {
    $vm = $describeByName[$nodeInstance]
    $aliasRanges = @()
    foreach ($nic in @($vm.networkInterfaces)) {
      if ($nic.PSObject.Properties.Name -contains "aliasIpRanges" -and $null -ne $nic.aliasIpRanges) {
        $aliasRanges += @($nic.aliasIpRanges | ForEach-Object { [string]$_.ipCidrRange })
      }
    }
    $resourcePolicies = @()
    if ($vm.PSObject.Properties.Name -contains "resourcePolicies" -and $null -ne $vm.resourcePolicies) {
      $resourcePolicies = @($vm.resourcePolicies)
    }
    $vmMachineType = ([string]$vm.machineType -split "/")[-1]
    $onHostMaintenance = [string]$vm.scheduling.onHostMaintenance
    $physicalHost = ""
    if ($vm.PSObject.Properties.Name -contains "resourceStatus" -and $null -ne $vm.resourceStatus -and
        $vm.resourceStatus.PSObject.Properties.Name -contains "physicalHost") {
      $physicalHost = [string]$vm.resourceStatus.physicalHost
    }
    $passed = (
      $vmMachineType -eq $machineType -and
      ([string]$vm.cpuPlatform) -match "Cascade Lake" -and
      $onHostMaintenance -eq "TERMINATE" -and
      $resourcePolicies.Count -gt 0 -and
      ($sameRack -or $AllowRackSpread) -and
      $aliasRanges.Count -gt 0
    )
    $controlRows += [pscustomobject]@{
      Name                  = $nodeInstance
      MachineType           = $vmMachineType
      CpuPlatform           = [string]$vm.cpuPlatform
      OnHostMaintenance     = $onHostMaintenance
      CompactPolicyAttached = ($resourcePolicies.Count -gt 0)
      PhysicalHost          = $physicalHost
      RackId                = $rackIdByName[$nodeInstance]
      SameRack              = $sameRack
      AliasIpRanges         = ($aliasRanges -join ";")
      Passed                = $passed
    }
  }
  $controlVarsIteration = if ($null -eq $script:RunIteration) { 0 } else { [int]$script:RunIteration }
  $controlVarsPath = Join-Path $script:OutDirFull ("control-vars-{0}_{1}_iter{2}.csv" -f $script:ResultMethodLabel, $script:ExpectedNodeCount, $controlVarsIteration)
  $controlRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $controlVarsPath
  $failedControl = @($controlRows | Where-Object { -not $_.Passed })
  if ($failedControl.Count -gt 0) {
    $controlRows | Format-Table -AutoSize | Out-String | Write-Host
    $hint = if (-not $sameRack -and -not $AllowRackSpread) {
      " Nodes did not all land on one rack. GKE compact placement is best-effort and max_distance cannot be used on GKE, so this is treated as a control-variable violation. Re-run to get a new placement, or pass -AllowRackSpread to accept and record the deviation."
    }
    else {
      ""
    }
    throw "One or more GKE control variable checks failed. See $controlVarsPath.$hint"
  }
  Write-Host "GKE control variable checks passed. Wrote $controlVarsPath"

  Set-Step "post-T5: cluster sanity via ops VM (nodes/anetd/taint/versions)"
  $sanityTemplate = @'
#!/usr/bin/env bash
set -euo pipefail

EXPECTED_NODES=__EXPECTED_NODES__

test "$(kubectl get nodes --no-headers | wc -l)" -eq "$EXPECTED_NODES"
kubectl wait --for=condition=Ready node --all --timeout=5m >/dev/null
kubectl -n kube-system rollout status ds/anetd --timeout=5m >/dev/null

# day-1 sanity: the GKE DPv2 shape the CLI depends on
kubectl get ds -n kube-system anetd \
  -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -w cilium-agent >/dev/null
kubectl get pods -n kube-system -l k8s-app=cilium -o name | grep -q pod/
kubectl get cm -n kube-system cilium-config -o name >/dev/null
kubectl exec -n kube-system ds/anetd -c cilium-agent -- sh -c \
  'cilium status -o json >/dev/null && cat /var/run/cilium/state/agent-runtime-config.json >/dev/null'

# bench pool taint (applied from creation time by the node pool definition)
BENCH_NODE="$(kubectl get nodes -l cloud.google.com/gke-nodepool=bench \
  -o jsonpath='{.items[0].metadata.name}')"
test -n "$BENCH_NODE"
kubectl get node "$BENCH_NODE" -o jsonpath='{.spec.taints[*].key}' | grep -qw benchmark-only

# Per-iteration record: a managed CP can be patched, so keep the version and the anetd image
echo "SERVER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion')"
echo "ANETD_IMAGE=$(kubectl get ds -n kube-system anetd -o jsonpath='{.spec.template.spec.containers[?(@.name=="cilium-agent")].image}')"
echo "BENCH_NODE=$BENCH_NODE"
echo "GKE_SANITY_OK"
'@
  $sanityScript = $sanityTemplate.Replace("__EXPECTED_NODES__", [string]$script:ActualNodeCount)
  $sanityLog = Join-Path $script:OutDirFull "ops-sanity.log"
  Invoke-OpsVmScript `
    -ScriptContent $sanityScript `
    -RemoteName "gke-sanity.sh" `
    -LogPath $sanityLog `
    -TimingName "ops vm sanity"
  if ((Get-Content -LiteralPath $sanityLog -Raw) -notmatch "GKE_SANITY_OK") {
    throw "Post-T5 sanity checks did not report GKE_SANITY_OK. See $sanityLog"
  }

  Set-Step "post-T5: connectivity namespace cleanup via ops VM"
  Invoke-Native -File "ssh" `
    -Arguments ((Get-OpsSshArguments) + @($script:OpsSshTarget, 'export PATH="/usr/local/bin:$PATH" && cilium connectivity test --cleanup --test-namespace cilium-cloud-connectivity --agent-daemonset-name anetd')) `
    -WorkingDirectory $script:OutDirFull `
    -LogPath (Join-Path $script:OutDirFull "connectivity-cleanup.log") `
    -TimingName "connectivity cleanup"

  Set-Step "post-T5: ops VM placement verification and experiment 2 asset install"
  # The ops VM was already created by the measured apply and later hosts T5.
  # depends_on makes it the last resource created, after the GKE nodes fixed
  # their sub-blocks. Here its placement/maintenance policy is verified and the
  # experiment 2 assets are installed.
  if ([string]$opsVm.scheduling.onHostMaintenance -ne "TERMINATE") {
    throw "ops VM onHostMaintenance must be TERMINATE, found '$($opsVm.scheduling.onHostMaintenance)'."
  }
  $opsPolicies = @()
  if ($opsVm.PSObject.Properties.Name -contains "resourcePolicies" -and $null -ne $opsVm.resourcePolicies) {
    $opsPolicies = @($opsVm.resourcePolicies)
  }
  if ($opsPolicies.Count -eq 0) {
    throw "ops VM must have the compact placement policy attached at creation."
  }
  $opsPhysicalHost = ""
  if ($opsVm.PSObject.Properties.Name -contains "resourceStatus" -and $null -ne $opsVm.resourceStatus -and
      $opsVm.resourceStatus.PSObject.Properties.Name -contains "physicalHost") {
    $opsPhysicalHost = [string]$opsVm.resourceStatus.physicalHost
  }
  $opsRackParts = @($opsPhysicalHost -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $opsRackId = if ($opsRackParts.Count -lt 2) { "" } else { "$($opsRackParts[0])/$($opsRackParts[1])" }
  $nodeRackId = if ($observedRackIds.Count -gt 0) { $observedRackIds[0] } else { "" }
  if ($sameRack -and $opsRackId -ne $nodeRackId) {
    Write-Warning "ops VM landed on a different rack than the GKE nodes (ops=$opsRackId, nodes=$nodeRackId). Compact placement is collocation-only on GKE (no max_distance), so co-location is best-effort."
  }
  [pscustomobject]@{
    Name              = $opsName
    MachineType       = ([string]$opsVm.machineType -split "/")[-1]
    OnHostMaintenance = [string]$opsVm.scheduling.onHostMaintenance
    PhysicalHost      = $opsPhysicalHost
    RackId            = $opsRackId
    NodeRackId        = $nodeRackId
    SameRackAsNodes   = ($opsRackId -ne "" -and $opsRackId -eq $nodeRackId)
  } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $script:OutDirFull "ops-vm-placement.csv")
  Write-Host "ops VM $opsName verified: TERMINATE + compact placement (rack=$opsRackId, nodes=$nodeRackId)."

  Install-OpsVmExperimentAssets -LogDirectory $script:OutDirFull

  Set-Step "post-T5: load experiment 2 tool image onto Benchmark/Server nodes"
  # The image has to exist where the pods run - on the nodes, not the ops VM.
  # Benchmark pod = bench node, Server pod = first name-sorted worker (the same
  # rule as experiment 1 T5).
  $benchInstances = @($nodeInstances | Where-Object { $_ -match "-bench-" } | Sort-Object)
  $workerInstances = @($nodeInstances | Where-Object { $_ -match "-worker-" } | Sort-Object)
  if ($benchInstances.Count -ne 1 -or $workerInstances.Count -lt 1) {
    throw "Could not identify the bench node and first worker from: $($nodeInstances -join ', ')"
  }
  $imageTargets = @($benchInstances[0], $workerInstances[0])

  $exp2ToolImageArchive = Join-Path $script:OutDirFull "exp2-tools-image.tar"
  Invoke-Native -File "docker" -Arguments @("save", $script:Exp2ToolImageTag, "-o", $exp2ToolImageArchive) `
    -WorkingDirectory $script:OutDirFull `
    -LogPath (Join-Path $script:OutDirFull "exp2-tool-image-save.log") `
    -TimingName "exp2 tool image save"
  if (-not (Test-Path -LiteralPath $exp2ToolImageArchive -PathType Leaf)) {
    throw "docker save did not produce the image archive: $exp2ToolImageArchive"
  }
  try {
    Install-Exp2ToolImageOnGkeNodes `
      -ProjectId $projectId -Zone $zone -SshUser $sshUser `
      -ArchivePath $exp2ToolImageArchive -Tag $script:Exp2ToolImageTag `
      -TargetInstances $imageTargets -LogDirectory $script:OutDirFull
  }
  finally {
    if (Test-Path -LiteralPath $exp2ToolImageArchive) {
      Remove-Item -LiteralPath $exp2ToolImageArchive -Force
    }
  }

  Write-ProvisioningSummary -Status "SUCCESS"
  Release-RunResultClaim
  Write-StageNotice -Message @(
    "[SUCCESS] CLOUD(GKE) provisioning is completed (label $($script:ExpectedNodeCount) nodes / actual $($script:ActualNodeCount) GKE nodes).",
    "output: $script:OutDirFull"
  )
  $script:RunCompleted = $true
}
catch {
  $caught = $_
  $failedStep = $script:CurrentStep
  $script:RunStatus = "FAILED"
  Write-Host "FAILED at '$failedStep': $($caught.Exception.Message)" -ForegroundColor Red

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
    Write-Host "Failure cleanup: destroying the CLOUD(GKE) experiment resources..."
    try {
      & (Join-Path $PSScriptRoot "destroy-gke.ps1") `
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
  $script:RunCompleted = $true
  throw $caught
}
finally {
  # Safety net for an abnormal abort such as Ctrl+C (same pattern as provision.ps1).
  if (-not $script:RunCompleted -and $script:ApplyStarted) {
    $interruptDestroyScript = Join-Path $PSScriptRoot "destroy-gke.ps1"
    $interruptDestroyOut = Join-Path $script:OutDirFull "interrupt-destroy"
    $interruptCommand = "Start-Sleep -Seconds 5; & '$interruptDestroyScript' -TfDir '$TfDirFull' -VarFile '$VarFileFull' -OutDir '$interruptDestroyOut'; Read-Host 'Interrupt destroy finished. Press Enter to close'"
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $interruptCommand
    ) | Out-Null
  }
}
