[CmdletBinding()]
param(
  [string]$TfDir = "",
  [string]$VarFile = "",
  [string]$OutDir = ".\results\gke\destroy"
)

# Destroys the whole N-Cloud (GKE) experiment environment and verifies that
# nothing is left behind. Design: infra/gke/README.md
#
# 1. terraform destroy -auto-approve (duration is measured)
#    - -var=create_ops_vm=true is always passed. Destroying with false sets the
#      count to 0 and the ops VM in the state risks being planned as "already
#      gone".
# 2. Verify directly against GCP that all of the following are gone:
#    - resources left in the Terraform state
#    - GKE clusters
#    - GKE node VMs (labels.goog-k8s-cluster-name)
#    - the ops VM (cloud-ops-0) instance and its boot disk
#    - gke-<cluster>-* node disks
#    - '<prefix>-allow-*' and 'gke-<cluster>-*' firewall rules
#    - the '<prefix>-compact' placement policy (also a signal that the ops VM
#      is still around)
#    - the GKE-generated secondary range on the subnet
# 3. Write destroy-report.json / destroy-verification.csv and exit non-zero if
#    any leftover is found.
#
# This deletes immediately, without confirmation (-auto-approve).
# The ops VM may still hold experiment 2 and 3 results
# (/var/lib/experiment/results): make sure they were fetched with
# gke/exp2/fetch_exp2_results_gke.ps1 first, or destroying loses them.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($TfDir))   { $TfDir = Join-Path $PSScriptRoot "infra\gke" }
if ([string]::IsNullOrWhiteSpace($VarFile)) { $VarFile = Join-Path $TfDir "terraform.tfvars" }

. (Join-Path $PSScriptRoot "provision-common.ps1")

$terraformWorkspace = "default"

function Invoke-NativeLogged {
  param(
    [string]$File,
    [string[]]$Arguments,
    [string]$WorkingDirectory,
    [string]$LogPath
  )
  Push-Location $WorkingDirectory
  try {
    $ErrorActionPreference = "Continue"
    & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() } |
      Out-File -FilePath $LogPath -Encoding utf8
  }
  finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
  }
  if ($LASTEXITCODE -ne 0) {
    if (Test-Path -LiteralPath $LogPath) {
      Get-Content -LiteralPath $LogPath -Tail 80 | Write-Host
    }
    throw "Command failed: $File $($Arguments -join ' ')"
  }
}

function Get-StateSummary {
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
    return [pscustomobject]@{ total = 0; cluster = 0; ops = 0 }
  }
  $resourceLines = @($lines | Where-Object { $_ -match '^\S' })
  return [pscustomobject]@{
    total   = $resourceLines.Count
    cluster = @($resourceLines | Where-Object { $_ -eq "google_container_cluster.cluster" }).Count
    ops     = @($resourceLines | Where-Object { $_ -match '^google_compute_instance\.ops(\[|$)' }).Count
  }
}

function Get-GcloudNames {
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

function Select-DestroyTerraformWorkspace {
  param(
    [string]$TfDirFull,
    [string]$Workspace
  )
  $raw = @(& terraform -chdir="$TfDirFull" workspace list)
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to list Terraform workspaces in $TfDirFull."
  }
  $names = @($raw | ForEach-Object { ([string]$_ -replace '^\s*\*?\s*', '').Trim() } | Where-Object { $_ })
  if ($names -notcontains $Workspace) {
    if ($Workspace -eq "default") {
      throw "Terraform default workspace is unavailable in $TfDirFull."
    }
    Write-Warning "Terraform workspace '$Workspace' does not exist. GCP leftover verification will still run."
    return $false
  }
  & terraform -chdir="$TfDirFull" workspace select $Workspace | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to select Terraform workspace '$Workspace'."
  }
  return $true
}

Assert-Command "terraform"
Assert-Command "gcloud"

# Every relative path (infra/, results/) is resolved against this directory, so
# the tree can be copied anywhere and still runs.
$WorkspaceRoot = $PSScriptRoot
$TfDirFull = Resolve-WorkspacePath -Path $TfDir -BasePath $WorkspaceRoot
$VarFileFull = Resolve-TfvarsPath -Path $VarFile -BasePath $WorkspaceRoot
$OutDirFull = Join-WorkspacePath -Path $OutDir -BasePath $WorkspaceRoot
New-Item -ItemType Directory -Force -Path $OutDirFull | Out-Null

$reportJsonPath = Join-Path $OutDirFull "destroy-report.json"
$verificationCsvPath = Join-Path $OutDirFull "destroy-verification.csv"
$destroyLogPath = Join-Path $OutDirFull "terraform-destroy.jsonl"

$projectId = Get-TfVarString -Path $VarFileFull -Name "project_id"
if ([string]::IsNullOrWhiteSpace($projectId)) {
  throw "Could not parse project_id from $VarFileFull."
}
$experimentName = Get-TfVarString -Path $VarFileFull -Name "experiment_name"
if ([string]::IsNullOrWhiteSpace($experimentName)) { $experimentName = "cloud" }
$experimentName = $experimentName.ToLowerInvariant()
$prefix = Get-TfVarString -Path $VarFileFull -Name "prefix"
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = $experimentName }
$clusterName = $prefix
$subnetworkName = Get-TfVarString -Path $VarFileFull -Name "subnetwork_name"
if ([string]::IsNullOrWhiteSpace($subnetworkName)) {
  throw "subnetwork_name must be set for secondary-range leftover verification."
}
$region = Get-TfVarString -Path $VarFileFull -Name "region"
if ([string]::IsNullOrWhiteSpace($region)) { $region = "asia-northeast3" }
$zone = Get-TfVarString -Path $VarFileFull -Name "zone"
if ([string]::IsNullOrWhiteSpace($zone)) { $zone = "asia-northeast3-a" }
$opsVmName = "$prefix-ops-0"

Write-Warning "The ops VM ($opsVmName) may still hold experiment 2 and 3 results. If you have not fetched them with fetch_exp2_results_gke.ps1 yet, stop now (Ctrl+C): destroying before the fetch loses the results."

Write-Host "==> terraform init"
Invoke-NativeLogged -File "terraform" -Arguments @("init", "-upgrade=false") -WorkingDirectory $TfDirFull -LogPath (Join-Path $OutDirFull "terraform-init.log")
$workspaceExists = Select-DestroyTerraformWorkspace -TfDirFull $TfDirFull -Workspace $terraformWorkspace

$before = if ($workspaceExists) { Get-StateSummary -TfDirFull $TfDirFull } else { [pscustomobject]@{ total = 0; cluster = 0; ops = 0 } }
Write-Host "State before destroy: cluster=$($before.cluster), opsVm=$($before.ops), resources=$($before.total)"
if ($before.total -eq 0) {
  Write-Warning "Terraform state is already empty. Running GCP leftover verification only."
}

$destroyStartedAt = Get-Date
$destroyClock = [System.Diagnostics.Stopwatch]::StartNew()
if ($workspaceExists -and $before.total -gt 0) {
  Write-Host "==> terraform destroy (auto-approve)"
  # create_ops_vm=true is explicit so an ops VM in the state is always planned for destroy.
  $destroyArguments = @(
    "destroy", "-auto-approve", "-input=false",
    "-var-file=$VarFileFull",
    "-var=create_ops_vm=true",
    "-json"
  )
  Invoke-NativeLogged -File "terraform" -Arguments $destroyArguments -WorkingDirectory $TfDirFull -LogPath $destroyLogPath
}
$destroyClock.Stop()
$destroyEndedAt = Get-Date
$destroyDurationMilliseconds = [math]::Round($destroyClock.Elapsed.TotalMilliseconds, 3)
$destroyDuration = [math]::Round($destroyDurationMilliseconds / 1000.0, 6)

Write-Host "==> verify complete deletion"
$after = if ($workspaceExists) { Get-StateSummary -TfDirFull $TfDirFull } else { [pscustomobject]@{ total = 0; cluster = 0; ops = 0 } }

$leftoverClusters = @(
  Get-GcloudNames -Arguments @(
    "container", "clusters", "list",
    "--project", $projectId,
    "--filter", "name=$clusterName",
    "--format", "value(name)"
  )
)
$leftoverNodeInstances = @(
  Get-GcloudNames -Arguments @(
    "compute", "instances", "list",
    "--project", $projectId,
    "--filter", "labels.goog-k8s-cluster-name=$clusterName",
    "--format", "value(name)"
  )
)
$leftoverOpsInstances = @(
  Get-GcloudNames -Arguments @(
    "compute", "instances", "list",
    "--project", $projectId,
    "--filter", "name=$opsVmName",
    "--format", "value(name)"
  )
)
# ops VM boot disk: auto_delete=true, but a mid-destroy failure can orphan it.
$leftoverOpsDisks = @(
  Get-GcloudNames -Arguments @(
    "compute", "disks", "list",
    "--project", $projectId,
    "--filter", "name~^$opsVmName",
    "--format", "value(name)"
  )
)
$leftoverNodeDisks = @(
  Get-GcloudNames -Arguments @(
    "compute", "disks", "list",
    "--project", $projectId,
    "--filter", "name~^gke-$clusterName-",
    "--format", "value(name)"
  )
)
$leftoverExperimentFirewalls = @(
  Get-GcloudNames -Arguments @(
    "compute", "firewall-rules", "list",
    "--project", $projectId,
    "--filter", "name~^$prefix-allow-",
    "--format", "value(name)"
  )
)
$leftoverGkeFirewalls = @(
  Get-GcloudNames -Arguments @(
    "compute", "firewall-rules", "list",
    "--project", $projectId,
    "--filter", "name~^gke-$clusterName-",
    "--format", "value(name)"
  )
)
# compact policy: deleting it fails while the ops VM exists, so it also signals a leftover.
$leftoverPolicies = @(
  Get-GcloudNames -Arguments @(
    "compute", "resource-policies", "list",
    "--project", $projectId,
    "--filter", "name=$prefix-compact",
    "--format", "value(name)"
  )
)

# subnet secondary range: check the GKE-generated range (gke-<cluster>-...) is gone.
$subnetJsonRaw = (& gcloud compute networks subnets describe $subnetworkName --project $projectId --region $region --format json | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "Failed to describe subnet '$subnetworkName' for secondary-range verification."
}
$subnet = $subnetJsonRaw | ConvertFrom-Json
$secondaryRanges = @()
if ($subnet.PSObject.Properties.Name -contains "secondaryIpRanges" -and $null -ne $subnet.secondaryIpRanges) {
  $secondaryRanges = @($subnet.secondaryIpRanges | ForEach-Object { [string]$_.rangeName })
}
$leftoverSecondaryRanges = @($secondaryRanges | Where-Object { $_ -match "^gke-$clusterName-" })

$checks = @(
  [pscustomobject]@{ check = "terraform_state_resources"; found = $after.total; names = ""; passed = ($after.total -eq 0) },
  [pscustomobject]@{ check = "gke_cluster_$clusterName"; found = $leftoverClusters.Count; names = ($leftoverClusters -join ";"); passed = ($leftoverClusters.Count -eq 0) },
  [pscustomobject]@{ check = "gke_node_instances"; found = $leftoverNodeInstances.Count; names = ($leftoverNodeInstances -join ";"); passed = ($leftoverNodeInstances.Count -eq 0) },
  [pscustomobject]@{ check = "ops_vm_instance_$opsVmName"; found = $leftoverOpsInstances.Count; names = ($leftoverOpsInstances -join ";"); passed = ($leftoverOpsInstances.Count -eq 0) },
  [pscustomobject]@{ check = "ops_vm_disks_$opsVmName"; found = $leftoverOpsDisks.Count; names = ($leftoverOpsDisks -join ";"); passed = ($leftoverOpsDisks.Count -eq 0) },
  [pscustomobject]@{ check = "gke_node_disks"; found = $leftoverNodeDisks.Count; names = ($leftoverNodeDisks -join ";"); passed = ($leftoverNodeDisks.Count -eq 0) },
  [pscustomobject]@{ check = "gcp_firewalls_prefix_$prefix-allow-"; found = $leftoverExperimentFirewalls.Count; names = ($leftoverExperimentFirewalls -join ";"); passed = ($leftoverExperimentFirewalls.Count -eq 0) },
  [pscustomobject]@{ check = "gcp_firewalls_prefix_gke-$clusterName-"; found = $leftoverGkeFirewalls.Count; names = ($leftoverGkeFirewalls -join ";"); passed = ($leftoverGkeFirewalls.Count -eq 0) },
  [pscustomobject]@{ check = "gcp_resource_policy_$prefix-compact"; found = $leftoverPolicies.Count; names = ($leftoverPolicies -join ";"); passed = ($leftoverPolicies.Count -eq 0) },
  [pscustomobject]@{ check = "subnet_secondary_ranges_gke-$clusterName-"; found = $leftoverSecondaryRanges.Count; names = ($leftoverSecondaryRanges -join ";"); passed = ($leftoverSecondaryRanges.Count -eq 0) }
)

$failedChecks = @($checks | Where-Object { -not $_.passed })
$status = if ($failedChecks.Count -eq 0) { "SUCCESS" } else { "LEFTOVERS_FOUND" }

$report = [pscustomobject]@{
  status                        = $status
  destroy_started_at            = $destroyStartedAt.ToUniversalTime().ToString("o")
  destroy_ended_at              = $destroyEndedAt.ToUniversalTime().ToString("o")
  destroy_duration_milliseconds = $destroyDurationMilliseconds
  destroy_duration_seconds      = $destroyDuration
  state_cluster_before          = $before.cluster
  state_ops_before              = $before.ops
  state_resources_before        = $before.total
  checks                        = $checks
}
ConvertTo-Json -InputObject $report -Depth 8 | Set-Content -Encoding UTF8 -Path $reportJsonPath
$checks | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $verificationCsvPath

$checks | Format-Table -AutoSize | Out-String | Write-Host

if ($failedChecks.Count -gt 0) {
  throw "terraform destroy left resources behind. See $reportJsonPath"
}

Write-Host "Destroy verified: cluster, node VMs, ops VM, disks, firewalls, placement policy, and GKE secondary ranges are all gone (destroy took $destroyDuration s). Report: $reportJsonPath"
