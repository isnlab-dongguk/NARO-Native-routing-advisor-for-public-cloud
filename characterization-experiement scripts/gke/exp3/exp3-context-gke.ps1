# =============================================================================
# exp3-context-gke.ps1 - experiment 3 context for GKE
#
# Dot-sources the original exp3/exp3-common.ps1 unchanged and reuses its prober,
# clock offset, measurement driver, CSV and restore checks. Building the context
# is the only thing GKE needs written differently:
#
#   what the original wants     | GKE reality           | what this file does
#   ------------------------------------------------------------------------
#   T4 ownership marker         | there is no T4 task   | discover from GKE directly
#   Terraform inventory output  | not in infra/gke      | build from kubectl + gcloud
#   ControlPlane = CP VM        | managed (no node)     | ops VM (<prefix>-ops-0)
#   node name <prefix>-worker-N | generated             | experiment-role label + name sort
#   role_index                  | absent                | assigned by name sort order
#
# Like the kubeadm build it runs on the local Windows machine. The ops VM is
# only the place the timed gcloud runs; the node SSH (clock offset) also goes
# out from the local machine. The prerequisites are verified:
#   - node SSH + sudo (node pool ssh-keys injection works)
#   - a removed alias IP is not restored by GKE (auto_repair=false)
#   - gcloud/kubectl work on the ops VM
# =============================================================================

Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "exp3\exp3-common.ps1")

function Get-Exp3GkeSecondaryRangeName {
  # GKE generates the subnet secondary range as 'gke-<cluster>-pods-<hash>', so
  # the kubeadm '<prefix>-pods' assumption cannot be used and the real name is
  # looked up by Pod CIDR (observed example: gke-cloud-pods-a63509da).
  param(
    [string]$ProjectId,
    [string]$Region,
    [string]$SubnetworkName,
    [string]$ClusterPodCidr
  )
  $subnet = Get-Exp3GcloudJson -Arguments @(
    "compute", "networks", "subnets", "describe", $SubnetworkName,
    "--region", $Region, "--project", $ProjectId
  )
  $ranges = @(Get-Exp3PropertyArray -Object $subnet -Name "secondaryIpRanges")
  $matched = @($ranges | Where-Object { [string]$_.ipCidrRange -eq $ClusterPodCidr })
  if ($matched.Count -ne 1) {
    $seen = ($ranges | ForEach-Object { "$($_.rangeName)=$($_.ipCidrRange)" }) -join ", "
    throw "Could not find exactly one secondary range with Pod CIDR $ClusterPodCidr on subnet '$SubnetworkName' (found: ${seen})."
  }
  return [string]$matched[0].rangeName
}

function Initialize-Exp3ContextGke {
  param(
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
  Assert-Exp3Command "kubectl"
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
  $projectId      = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "project_id"
  $region         = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "region"
  $zone           = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "zone"
  $networkName    = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "network_name"
  $subnetworkName = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "subnetwork_name"
  $resourcePrefix = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "resource_prefix"
  $clusterName    = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "cluster_name"
  $clusterPodCidr = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "pod_cidr"
  $sshUser        = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "ssh_user"
  $sshKeyRaw      = Get-Exp3TerraformOutputRaw -TfDirFull $tfDirFull -Name "ssh_private_key_path"

  $sshKeyFile = if ([System.IO.Path]::IsPathRooted($sshKeyRaw)) {
    $sshKeyRaw
  }
  else {
    Join-Path $tfDirFull $sshKeyRaw
  }
  if (-not (Test-Path -LiteralPath $sshKeyFile -PathType Leaf)) {
    throw "SSH private key not found: $sshKeyFile"
  }

  # -- ControlPlane = ops VM (stands in for the managed CP, runs timed gcloud) --
  # Resolved before node discovery because, as in the original, kubectl runs on
  # the ops VM (Invoke-Exp3Kubectl -> SSH). A local kubectl would read whatever
  # cluster the current kubeconfig context points at - once a local kind cluster
  # was picked up and its 'kind-control-plane' node was returned. In the worst
  # case that would attempt an alias removal on a different cluster, so the
  # local kubeconfig is never trusted here.
  $opsName = "$resourcePrefix-ops-0"
  $opsRows = @(Get-Exp3GcloudJson -Arguments @(
    "compute", "instances", "describe", $opsName,
    "--zone", $zone, "--project", $projectId
  ))
  if ($opsRows.Count -lt 1) {
    throw "ops VM '$opsName' not found. Complete the experiment 1 provisioning first."
  }
  $opsVm = $opsRows[0]
  $opsNics = @(Get-Exp3PropertyArray -Object $opsVm -Name "networkInterfaces")
  $opsAcs = @(Get-Exp3PropertyArray -Object $opsNics[0] -Name "accessConfigs")
  $controlPlane = [pscustomobject]@{
    node_name   = $opsName
    role        = "control-plane"
    role_index  = 0
    zone        = $zone
    private_ip  = [string]$opsNics[0].networkIP
    external_ip = [string]$opsAcs[0].natIP
    pod_cidr    = ""   # the ops VM is not a cluster member and has no PodCIDR
  }

  # -- Node discovery: read Kubernetes + GCE directly instead of a T4 marker --
  # Calls the ops VM kubectl with the minimum context needed for SSH (the full
  # ctx does not exist yet).
  $sshCtx = [pscustomobject]@{
    SshUser      = $sshUser
    SshKeyFile   = $sshKeyFile
    ControlPlane = $controlPlane
  }
  Write-Host "==> discovering GKE nodes (ops VM kubectl, experiment-role label + PodCIDR)"
  $nodeJson = Invoke-Exp3Kubectl -Ctx $sshCtx -Script 'kubectl get nodes -o json'
  $nodeDoc = ($nodeJson | Out-String) | ConvertFrom-Json
  if (@($nodeDoc.items).Count -eq 0) {
    throw "The ops VM kubectl returned no node. Check that 'gcloud container clusters get-credentials $clusterName --zone $zone --project $projectId' was run on the ops VM."
  }
  # Assert these are nodes of the target cluster (GKE node names start with gke-<cluster>-).
  foreach ($item in @($nodeDoc.items)) {
    if ([string]$item.metadata.name -notlike "gke-$clusterName-*") {
      throw "A node of an unexpected cluster was returned: '$($item.metadata.name)' (expected prefix: gke-$clusterName-). Check the kubectl context of the ops VM."
    }
  }

  $discovered = @()
  foreach ($item in @($nodeDoc.items)) {
    $labels = $item.metadata.labels
    $role = ""
    if ($labels.PSObject.Properties.Name -contains "experiment-role") {
      $role = [string]$labels."experiment-role"
    }
    if ($role -ne "benchmark" -and $role -ne "worker") {
      throw "Node '$($item.metadata.name)' has no experiment-role label (benchmark|worker)."
    }
    $podCidr = [string]$item.spec.podCIDR
    if ([string]::IsNullOrWhiteSpace($podCidr)) {
      throw "Node '$($item.metadata.name)' has no spec.podCIDR."
    }
    # On GKE the Kubernetes node name equals the GCE instance name; the zone
    # comes from providerID, formatted gce://<project>/<zone>/<instance>.
    $providerId = [string]$item.spec.providerID
    if ($providerId -notmatch '^gce://[^/]+/([^/]+)/(.+)$') {
      throw "Could not parse the providerID of node '$($item.metadata.name)': $providerId"
    }
    $nodeZone = $Matches[1]
    $instanceName = $Matches[2]
    if ($instanceName -ne [string]$item.metadata.name) {
      throw "Node name and GCE instance name differ: $($item.metadata.name) vs $instanceName"
    }
    $internalIp = ""
    foreach ($addr in @($item.status.addresses)) {
      if ([string]$addr.type -eq "InternalIP") { $internalIp = [string]$addr.address }
    }
    $discovered += [pscustomobject]@{
      node_name  = [string]$item.metadata.name
      role       = $role
      zone       = $nodeZone
      private_ip = $internalIp
      pod_cidr   = $podCidr
    }
  }

  # role_index: kubeadm encodes it in the name, GKE does not. It is assigned by
  # name sort order, exactly as in experiment 1 T5, so the Server pod lands on
  # the node T5 verified.
  $markerNodes = @()
  foreach ($role in @("benchmark", "worker")) {
    $sorted = @($discovered | Where-Object { $_.role -eq $role } | Sort-Object node_name)
    for ($i = 0; $i -lt $sorted.Count; $i++) {
      $markerNodes += [pscustomobject]@{
        node_name   = $sorted[$i].node_name
        role        = $role
        role_index  = $i
        zone        = $sorted[$i].zone
        private_ip  = $sorted[$i].private_ip
        external_ip = ""   # filled in below from the GCE lookup
        pod_cidr    = $sorted[$i].pod_cidr
      }
    }
  }

  # External IP: needed to SSH from the local machine (clock offset).
  $instanceRows = @(Get-Exp3GcloudJson -Arguments @(
    "compute", "instances", "list",
    "--project", $projectId,
    "--filter", "labels.goog-k8s-cluster-name=$clusterName",
    "--zones", $zone
  ))
  $externalByName = @{}
  foreach ($row in $instanceRows) {
    $nics = @(Get-Exp3PropertyArray -Object $row -Name "networkInterfaces")
    if ($nics.Count -lt 1) { continue }
    $acs = @(Get-Exp3PropertyArray -Object $nics[0] -Name "accessConfigs")
    if ($acs.Count -lt 1) { continue }
    $externalByName[[string]$row.name] = [string]$acs[0].natIP
  }
  foreach ($node in $markerNodes) {
    if (-not $externalByName.ContainsKey($node.node_name)) {
      throw "Could not find the GCE instance of node '$($node.node_name)'."
    }
    $node.external_ip = $externalByName[$node.node_name]
    if ([string]::IsNullOrWhiteSpace($node.external_ip)) {
      throw "Node '$($node.node_name)' has no external IP, so SSH (clock offset measurement) is impossible."
    }
  }

  # The node count check uses the real GKE node count (3/7), not the CSV label.
  $actualNodeCount = $markerNodes.Count
  if ($actualNodeCount -ne 3 -and $actualNodeCount -ne 7) {
    throw "Experiment 3 only runs on 3 real GKE nodes (label 4) or 7 (label 8) (found $actualNodeCount)."
  }
  # The node_count in the filename/CSV stays 4/8 so it compares with other methods.
  $nodeCount = $actualNodeCount + 1

  $benchMatches = @($markerNodes | Where-Object { $_.role -eq "benchmark" -and $_.role_index -eq 0 })
  $workerZeroMatches = @($markerNodes | Where-Object { $_.role -eq "worker" -and $_.role_index -eq 0 })
  if ($benchMatches.Count -ne 1 -or $workerZeroMatches.Count -ne 1) {
    throw "Could not find exactly one benchmark and one worker-0 node."
  }
  $benchNode = $benchMatches[0]
  $workerZeroNode = $workerZeroMatches[0]
  $targetNodes = @($benchNode, $workerZeroNode)
  $otherNodes = @($markerNodes | Where-Object {
      $_.node_name -ne $benchNode.node_name -and $_.node_name -ne $workerZeroNode.node_name
    })

  # (ControlPlane = ops VM was resolved before node discovery, because kubectl
  #  has to run on the ops VM.)

  $secondaryRangeName = Get-Exp3GkeSecondaryRangeName -ProjectId $projectId -Region $region `
    -SubnetworkName $subnetworkName -ClusterPodCidr $clusterPodCidr
  Write-Host "    secondary range: $secondaryRangeName ($clusterPodCidr)"
  Write-Host "    benchmark=$($benchNode.node_name) ($($benchNode.pod_cidr))"
  Write-Host "    worker-0 =$($workerZeroNode.node_name) ($($workerZeroNode.pod_cidr))"
  Write-Host "    ops VM   =$opsName"

  $ctx = [pscustomobject]@{
    Method               = "cloud"
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
    # GKE only: the generated secondary range name
    GkeSecondaryRangeName = $secondaryRangeName
    GkeClusterName        = $clusterName
  }

  # -- Experiment 2 pod checks (same criteria as the original) ---------------
  Write-Host "==> verifying the experiment 2 pods"
  $clusterScript = @'
printf 'POD_SERVER %s\n' "$(kubectl -n __NS__ get pod __SERVER_POD__ -o jsonpath='{.spec.nodeName}|{.status.podIP}|{.spec.hostNetwork}|{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
printf 'POD_BENCH %s\n' "$(kubectl -n __NS__ get pod __BENCH_POD__ -o jsonpath='{.spec.nodeName}|{.status.podIP}|{.spec.hostNetwork}|{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
'@
  $clusterScript = $clusterScript.Replace("__NS__", $Namespace).
    Replace("__SERVER_POD__", $script:Exp3ServerPodName).
    Replace("__BENCH_POD__", $script:Exp3BenchPodName)
  $clusterOutput = Invoke-Exp3Kubectl -Ctx $ctx -Script $clusterScript

  $serverPodLine = $null
  $benchPodLine = $null
  foreach ($line in ($clusterOutput -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^POD_SERVER (.+)$') { $serverPodLine = $Matches[1] }
    elseif ($trimmed -match '^POD_BENCH (.+)$') { $benchPodLine = $Matches[1] }
  }
  if ([string]::IsNullOrWhiteSpace($serverPodLine) -or [string]::IsNullOrWhiteSpace($benchPodLine)) {
    throw "Could not read the experiment 2 pods ($($script:Exp3BenchPodName)/$($script:Exp3ServerPodName)). Run 'bash /opt/experiment/scripts/exp2_create_normal_min.sh -m Cloud' on the ops VM first."
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
    throw "PodCIDR route convergence cannot be measured with hostNetwork pods."
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

  Write-Host "==> ops VM gcloud preflight (hybrid measurement: T0/T1 on the ops VM clock)"
  Assert-Exp3ControlPlaneGcloudReady -Ctx $ctx

  $resultFile = Initialize-Exp3ResultFile -OutDirFull $outDirFull -Method "GKE" -NodeCount $nodeCount
  $ctx.Iteration = $resultFile.iteration
  $ctx.ResultCsvPath = $resultFile.csv_path
  $ctx.RawDir = $resultFile.raw_dir
  Write-Host "==> result iteration $($resultFile.iteration): $($resultFile.csv_path)"

  return $ctx
}
