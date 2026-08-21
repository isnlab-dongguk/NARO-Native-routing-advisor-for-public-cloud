[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectId,

  [Parameter(Mandatory = $true)]
  [string]$Region,

  [string]$MachineType = "c2-standard-4",

  # Number of VMs to create. Existing nodes are already counted in the GCP quota
  # usage, so a 4->8 expansion must pass 4 (the new ones), not 8.
  [int]$NodeCount = 4,

  # Control variable shared by every method: pd-balanced 25GB per node.
  [int]$DiskSizeGb = 25,

  # Boot disk type. pd-balanced/pd-ssd/pd-extreme consume the SSD_TOTAL_GB
  # quota, not DISKS_TOTAL_GB (standard PD).
  [string]$DiskType = "pd-balanced",

  [bool]$AllowExternalIp = $true,
  [string]$OutDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Get-VcpuCount {
  param([string]$Type)
  if ($Type -match "-(\d+)$") {
    return [int]$Matches[1]
  }
  throw "Cannot infer vCPU count from machine type: $Type"
}

function Get-DiskQuotaMetric {
  param([string]$Type)
  switch ($Type) {
    "pd-standard" { return "DISKS_TOTAL_GB" }
    # Despite the name, pd-balanced consumes the SSD quota (SSD_TOTAL_GB).
    "pd-balanced" { return "SSD_TOTAL_GB" }
    "pd-ssd" { return "SSD_TOTAL_GB" }
    "pd-extreme" { return "SSD_TOTAL_GB" }
    default { return $null }
  }
}

function Get-FamilyCpuQuotaMetric {
  param([string]$Type)
  switch -Regex ($Type) {
    "^c2-" { return "C2_CPUS" }
    "^c2d-" { return "C2D_CPUS" }
    "^c3-" { return "C3_CPUS" }
    "^c3d-" { return "C3D_CPUS" }
    "^n2-" { return "N2_CPUS" }
    "^n2d-" { return "N2D_CPUS" }
    "^n4-" { return "N4_CPUS" }
    "^e2-" { return "E2_CPUS" }
    default { return $null }
  }
}

function Get-QuotaByMetric {
  param(
    [hashtable]$QuotaMap,
    [string]$Metric
  )
  if ($QuotaMap.ContainsKey($Metric)) {
    return $QuotaMap[$Metric]
  }
  return $null
}

function New-QuotaRow {
  param(
    [string]$Metric,
    [string]$Description,
    [double]$Required,
    [object]$Quota,
    [bool]$RequiredMetric = $true
  )

  if ($null -eq $Quota) {
    return [pscustomobject]@{
      Metric              = $Metric
      Description         = $Description
      Required            = $Required
      Limit               = $null
      Usage               = $null
      Available           = $null
      RequiredLimit       = $null
      Status              = if ($RequiredMetric) { "MISSING" } else { "NOT_FOUND_OPTIONAL" }
      Message             = "Quota metric was not returned by gcloud compute regions describe."
    }
  }

  $limit = [double]$Quota.limit
  $usage = [double]$Quota.usage

  if ($limit -lt 0) {
    return [pscustomobject]@{
      Metric              = $Metric
      Description         = $Description
      Required            = $Required
      Limit               = $limit
      Usage               = $usage
      Available           = "UNLIMITED"
      RequiredLimit       = $null
      Status              = "PASS"
      Message             = "Quota is unlimited."
    }
  }

  $available = $limit - $usage
  $requiredLimit = [math]::Ceiling($usage + $Required)
  $pass = $available -ge $Required

  return [pscustomobject]@{
    Metric              = $Metric
    Description         = $Description
    Required            = $Required
    Limit               = $limit
    Usage               = $usage
    Available           = [math]::Round($available, 3)
    RequiredLimit       = $requiredLimit
    Status              = if ($pass) { "PASS" } else { "INSUFFICIENT" }
    Message             = if ($pass) { "Enough remaining quota." } else { "Request at least $requiredLimit for this metric before provisioning." }
  }
}

Assert-Command "gcloud"

# The provisioning engines always pass -OutDir; this default only serves a
# standalone run and stays inside the script tree.
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $PSScriptRoot "results\standalone\quota" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$regionJson = & gcloud compute regions describe $Region --project $ProjectId --format json
if ($LASTEXITCODE -ne 0) {
  throw "Failed to describe region quota: project=$ProjectId region=$Region"
}

$regionInfo = $regionJson | Out-String | ConvertFrom-Json
$quotaMap = @{}
foreach ($quota in @($regionInfo.quotas)) {
  $quotaMap[[string]$quota.metric] = $quota
}

$vcpuPerNode = Get-VcpuCount -Type $MachineType
$requiredVcpus = $vcpuPerNode * $NodeCount
$requiredDiskGb = $DiskSizeGb * $NodeCount
$familyMetric = Get-FamilyCpuQuotaMetric -Type $MachineType

$rows = @()
$rows += New-QuotaRow -Metric "CPUS" -Description "Regional total vCPU quota for $NodeCount new x $MachineType" -Required $requiredVcpus -Quota (Get-QuotaByMetric -QuotaMap $quotaMap -Metric "CPUS")

if ($familyMetric) {
  $rows += New-QuotaRow -Metric $familyMetric -Description "Regional machine-family vCPU quota for $MachineType" -Required $requiredVcpus -Quota (Get-QuotaByMetric -QuotaMap $quotaMap -Metric $familyMetric)
}

$rows += New-QuotaRow -Metric "INSTANCES" -Description "Regional VM instance quota for $NodeCount new VMs" -Required $NodeCount -Quota (Get-QuotaByMetric -QuotaMap $quotaMap -Metric "INSTANCES")

if ($AllowExternalIp) {
  $rows += New-QuotaRow -Metric "IN_USE_ADDRESSES" -Description "Regional external IPv4 addresses for ephemeral access_config" -Required $NodeCount -Quota (Get-QuotaByMetric -QuotaMap $quotaMap -Metric "IN_USE_ADDRESSES")
}

$diskMetric = Get-DiskQuotaMetric -Type $DiskType
if ($diskMetric) {
  $rows += New-QuotaRow -Metric $diskMetric -Description "Regional persistent disk capacity quota for $NodeCount new x $DiskSizeGb GB $DiskType" -Required $requiredDiskGb -Quota (Get-QuotaByMetric -QuotaMap $quotaMap -Metric $diskMetric) -RequiredMetric $false
}
else {
  Write-Warning "Unknown disk type '$DiskType'; skipping disk capacity quota check."
}

$jsonPath = Join-Path $OutDir "quota-check.json"
$csvPath = Join-Path $OutDir "quota-check.csv"
$rows | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $jsonPath
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath

$blocking = @($rows | Where-Object { $_.Status -eq "INSUFFICIENT" -or $_.Status -eq "MISSING" })
if ($blocking.Count -gt 0) {
  $rows | Format-Table -AutoSize | Out-String | Write-Host
  throw "Quota preflight failed. See $csvPath. Quota increases can be requested, but approval may be manual/reviewed."
}

Write-Host "Quota preflight passed. Wrote $csvPath"
