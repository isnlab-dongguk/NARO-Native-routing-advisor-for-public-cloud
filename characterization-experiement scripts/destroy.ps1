[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("vxlan", "host", "static", "dynamic")]
  [string]$Mode,
  [string]$TfDir = "",
  [string]$VarFile = "",
  [string]$OutDir = ""
)

# Destroys one experiment environment and verifies that nothing is left behind.
#
# 1. terraform destroy -auto-approve (duration is measured)
# 2. Verify directly against GCP that all of the following are gone:
#    - resources left in the Terraform state
#    - VM instances labelled experiment=<mode>
#    - disks labelled experiment=<mode> (proves boot-disk auto_delete)
#    - '<prefix>-allow-*' firewall rules
#    - '<prefix>-compact' placement policy
#    - method-specific T4 resources (N-Static routes, N-Dynamic NCC/Cloud Router)
# 3. Write destroy-report.json / destroy-verification.csv and exit non-zero if
#    any leftover is found.
#
# This deletes immediately, without confirmation (-auto-approve). Run against an
# 8-node cluster it removes all 8 VMs, including the control plane and the
# benchmark node, plus the firewall rules and the placement policy.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$NetworkMode = $Mode.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($TfDir))   { $TfDir = Join-Path $PSScriptRoot "infra\$NetworkMode" }
if ([string]::IsNullOrWhiteSpace($VarFile)) { $VarFile = Join-Path $TfDir "terraform.tfvars" }
if ([string]::IsNullOrWhiteSpace($OutDir))  { $OutDir = ".\results\$NetworkMode\destroy" }

. (Join-Path $PSScriptRoot "provision-common.ps1")

$isMethodSpecificNative = $NetworkMode -in @("static", "dynamic")
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
    # PS 5.1: EAP=Stop plus native stderr redirection dies with NativeCommandError.
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
    # No state at all means nothing is left either.
    return [pscustomobject]@{ total = 0; instances = 0 }
  }
  $resourceLines = @($lines | Where-Object { $_ -match '^\S' })
  return [pscustomobject]@{
    total     = $resourceLines.Count
    instances = @($resourceLines | Where-Object { $_ -match '^google_compute_instance\.node\[' }).Count
  }
}

function Get-GcloudNames {
  param([string[]]$Arguments)
  # Leftover verification asks a question whose right answer is "zero", so the
  # gcloud "filter keys were not present in any resource" WARNING is only
  # confusing. The verdict comes from the number of names returned.
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
    Write-Warning "Terraform workspace '$Workspace' does not exist. GCP T4 leftovers will still be verified."
    return $false
  }
  & terraform -chdir="$TfDirFull" workspace select $Workspace | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to select Terraform workspace '$Workspace'."
  }
  return $true
}

function Remove-RenderedRemoteScripts {
  # Removes the *.sh files the provisioning step rendered into the result
  # directory for upload. They are regenerated from templates on every run, so
  # they are not a record worth keeping. Measurement artifacts (.log, CSV,
  # reports) are left untouched.
  param([string]$ResultsModeRoot)

  if ([string]::IsNullOrWhiteSpace($ResultsModeRoot) -or -not (Test-Path -LiteralPath $ResultsModeRoot)) {
    return
  }
  $scripts = @(Get-ChildItem -LiteralPath $ResultsModeRoot -Recurse -File -Filter "*.sh" -ErrorAction SilentlyContinue)
  if ($scripts.Count -eq 0) {
    return
  }
  $removed = 0
  foreach ($renderedScript in $scripts) {
    try {
      Remove-Item -LiteralPath $renderedScript.FullName -Force
      $removed++
    }
    catch {
      Write-Warning "Could not remove rendered remote script '$($renderedScript.FullName)': $($_.Exception.Message)"
    }
  }
  Write-Host "Removed $removed rendered remote script(s) (*.sh) under $ResultsModeRoot"
}

. (Join-Path $PSScriptRoot "cleanup-native-routing-t4.ps1")

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
if ([string]::IsNullOrWhiteSpace($experimentName)) { $experimentName = $NetworkMode }
$experimentName = $experimentName.ToLowerInvariant()
if ($experimentName -ne $NetworkMode) {
  throw "experiment_name '$experimentName' does not match NetworkMode '$NetworkMode'."
}
$prefix = Get-TfVarString -Path $VarFileFull -Name "prefix"
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = $experimentName }
$subnetworkName = Get-TfVarString -Path $VarFileFull -Name "subnetwork_name"
$region = Get-TfVarString -Path $VarFileFull -Name "region"
if ([string]::IsNullOrWhiteSpace($region)) { $region = "asia-northeast3" }
if ($isMethodSpecificNative -and [string]::IsNullOrWhiteSpace($subnetworkName)) {
  throw "subnetwork_name must be set for $NetworkMode T4 cleanup."
}

Write-Host "==> terraform init"
Invoke-NativeLogged -File "terraform" -Arguments @("init", "-upgrade=false") -WorkingDirectory $TfDirFull -LogPath (Join-Path $OutDirFull "terraform-init.log")
$workspaceExists = Select-DestroyTerraformWorkspace -TfDirFull $TfDirFull -Workspace $terraformWorkspace

$before = if ($workspaceExists) { Get-StateSummary -TfDirFull $TfDirFull } else { [pscustomobject]@{ total = 0; instances = 0 } }
Write-Host "State before destroy: $($before.instances) instances / $($before.total) resources"
if ($before.total -eq 0) {
  Write-Warning "Terraform state is already empty. Running GCP leftover verification only."
}

$destroyStartedAt = Get-Date
$destroyClock = [System.Diagnostics.Stopwatch]::StartNew()
if ($isMethodSpecificNative) {
  Write-Host "==> remove $NetworkMode T4 resources before VM destruction"
  Remove-NativeRoutingT4 -Method $NetworkMode -ProjectId $projectId -Region $region `
    -SubnetworkName $subnetworkName -ResourcePrefix $prefix -TfDirFull $TfDirFull -OutDirFull $OutDirFull
}
if ($workspaceExists -and $before.total -gt 0) {
  Write-Host "==> terraform destroy (auto-approve)"
  $destroyArguments = @("destroy", "-auto-approve", "-var-file=$VarFileFull", "-json")
  # Reuse the exact image pinned during the 4->8 expansion for the destroy
  # refresh, so a newer image family cannot create a replacement diff.
  $lockedSourceImage = Get-TerraformOutputRawOptional -TfDirFull $TfDirFull -Name "resolved_source_image"
  if (-not [string]::IsNullOrWhiteSpace($lockedSourceImage)) {
    $destroyArguments += "-var=source_image=$lockedSourceImage"
  }
  Invoke-NativeLogged -File "terraform" -Arguments $destroyArguments -WorkingDirectory $TfDirFull -LogPath $destroyLogPath
}
$destroyClock.Stop()
$destroyEndedAt = Get-Date
$destroyDurationMilliseconds = [math]::Round($destroyClock.Elapsed.TotalMilliseconds, 3)
$destroyDuration = [math]::Round($destroyDurationMilliseconds / 1000.0, 6)

Write-Host "==> verify complete deletion"
$after = if ($workspaceExists) { Get-StateSummary -TfDirFull $TfDirFull } else { [pscustomobject]@{ total = 0; instances = 0 } }

# Instances and disks are looked up by the experiment label the module applies;
# firewall rules and the placement policy by name prefix.
$leftoverInstances = @(
  Get-GcloudNames -Arguments @(
    "compute", "instances", "list",
    "--project", $projectId,
    "--filter", "labels.experiment=$experimentName",
    "--format", "value(name)"
  )
)
$leftoverDisks = @(
  Get-GcloudNames -Arguments @(
    "compute", "disks", "list",
    "--project", $projectId,
    "--filter", "labels.experiment=$experimentName",
    "--format", "value(name)"
  )
)
$leftoverFirewalls = @(
  Get-GcloudNames -Arguments @(
    "compute", "firewall-rules", "list",
    "--project", $projectId,
    "--filter", "name~^$prefix-allow-",
    "--format", "value(name)"
  )
)
$leftoverPolicies = @(
  Get-GcloudNames -Arguments @(
    "compute", "resource-policies", "list",
    "--project", $projectId,
    "--filter", "name=$prefix-compact",
    "--format", "value(name)"
  )
)

$checks = @(
  [pscustomobject]@{ check = "terraform_state_resources"; found = $after.total; names = ""; passed = ($after.total -eq 0) },
  [pscustomobject]@{ check = "gcp_instances_label_experiment_$experimentName"; found = $leftoverInstances.Count; names = ($leftoverInstances -join ";"); passed = ($leftoverInstances.Count -eq 0) },
  [pscustomobject]@{ check = "gcp_disks_label_experiment_$experimentName"; found = $leftoverDisks.Count; names = ($leftoverDisks -join ";"); passed = ($leftoverDisks.Count -eq 0) },
  [pscustomobject]@{ check = "gcp_firewalls_prefix_$prefix-allow-"; found = $leftoverFirewalls.Count; names = ($leftoverFirewalls -join ";"); passed = ($leftoverFirewalls.Count -eq 0) },
  [pscustomobject]@{ check = "gcp_resource_policy_$prefix-compact"; found = $leftoverPolicies.Count; names = ($leftoverPolicies -join ";"); passed = ($leftoverPolicies.Count -eq 0) }
)
if ($isMethodSpecificNative) {
  $checks += @(Get-NativeRoutingT4VerificationChecks -Method $NetworkMode -ProjectId $projectId `
    -Region $region -SubnetworkName $subnetworkName -ResourcePrefix $prefix)
}

$failedChecks = @($checks | Where-Object { -not $_.passed })
$status = if ($failedChecks.Count -eq 0) { "SUCCESS" } else { "LEFTOVERS_FOUND" }

$report = [pscustomobject]@{
  status                   = $status
  destroy_started_at       = $destroyStartedAt.ToUniversalTime().ToString("o")
  destroy_ended_at         = $destroyEndedAt.ToUniversalTime().ToString("o")
  destroy_duration_milliseconds = $destroyDurationMilliseconds
  destroy_duration_seconds = $destroyDuration
  state_instances_before   = $before.instances
  state_resources_before   = $before.total
  checks                   = $checks
}
ConvertTo-Json -InputObject $report -Depth 8 | Set-Content -Encoding UTF8 -Path $reportJsonPath
$checks | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $verificationCsvPath

$checks | Format-Table -AutoSize | Out-String | Write-Host

if ($failedChecks.Count -gt 0) {
  throw "terraform destroy left resources behind. See $reportJsonPath"
}

if ($isMethodSpecificNative) {
  $nativeT4StatePath = Get-NativeT4StatePath -TfDirFull $TfDirFull -Method $NetworkMode
  if (Test-Path -LiteralPath $nativeT4StatePath) {
    Remove-Item -LiteralPath $nativeT4StatePath -Force
  }
}

# After deletion is verified, clean up the *.sh the provisioning step rendered
# for upload. The result root (results/<mode>) is the parent of the destroy
# OutDir (results/<mode>/destroy).
Remove-RenderedRemoteScripts -ResultsModeRoot (Split-Path -Parent $OutDirFull)

Write-Host "Destroy verified: all $($before.instances) node(s) and every module resource are gone (destroy took $destroyDuration s). Report: $reportJsonPath"
