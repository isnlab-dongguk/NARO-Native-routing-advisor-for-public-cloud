[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("static", "dynamic")]
  [string]$Method,
  [Parameter(Mandatory = $true)][string]$ProjectId,
  [Parameter(Mandatory = $true)][string]$Region,
  [Parameter(Mandatory = $true)][string]$NetworkName,
  [Parameter(Mandatory = $true)][string]$SubnetworkName,
  [Parameter(Mandatory = $true)][string]$ResourcePrefix,
  [ValidateRange(0, 10000)][int]$NewNodeCount,
  [ValidateRange(2, 10000)][int]$TargetRoutingNodeCount,
  [ValidateRange(0, 10000)][int]$AdditionalRoutingNodeCount,
  [string]$ClusterPodCidr = "10.244.0.0/16",
  [string]$OutDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Method = $Method.ToLowerInvariant()

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Get-ObjectPropertyValue {
  param([object]$Object, [string]$Name, [object]$Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  return $property.Value
}

function Get-ObjectPropertyArray {
  param([object]$Object, [string]$Name)
  $value = Get-ObjectPropertyValue -Object $Object -Name $Name
  if ($null -eq $value) { return @() }
  return @($value)
}

function Get-ResourceTail {
  param([object]$Value)
  if ($null -eq $Value) { return "" }
  $text = ([string]$Value).TrimEnd("/")
  if ([string]::IsNullOrWhiteSpace($text)) { return "" }
  return ($text -split "/")[-1]
}

function Invoke-GcloudJson {
  param([string[]]$Arguments)
  $raw = @(& gcloud @Arguments --quiet --format=json)
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud command failed: gcloud $($Arguments -join ' ')"
  }
  $text = ($raw | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return @() }
  $parsed = $text | ConvertFrom-Json
  if ($null -eq $parsed) { return @() }
  return $parsed
}

function Get-CloudQuotaCatalog {
  param([string]$Service, [string]$AccessToken)
  $headers = @{ Authorization = "Bearer $AccessToken" }
  $baseUri = "https://cloudquotas.googleapis.com/v1/projects/$ProjectId/locations/global/services/$Service/quotaInfos"
  $pageToken = ""
  $items = @()
  do {
    $uri = "${baseUri}?pageSize=1000"
    if (-not [string]::IsNullOrWhiteSpace($pageToken)) {
      $uri += "&pageToken=$([uri]::EscapeDataString($pageToken))"
    }
    try {
      $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    }
    catch {
      throw "Failed to read Cloud Quotas for service '$Service'. The active account needs cloudquotas.quotas.get. $($_.Exception.Message)"
    }
    $items += @(Get-ObjectPropertyArray -Object $response -Name "quotaInfos")
    $pageToken = [string](Get-ObjectPropertyValue -Object $response -Name "nextPageToken" -Default "")
  } while (-not [string]::IsNullOrWhiteSpace($pageToken))
  return @($items)
}

function Get-EffectiveQuotaLimit {
  param([object[]]$Catalog, [string]$Metric, [hashtable]$Dimensions, [string]$Location)
  $matches = @($Catalog | Where-Object { [string]$_.metric -eq $Metric })
  if ($matches.Count -ne 1) { return $null }

  $candidates = @()
  foreach ($info in @(Get-ObjectPropertyArray -Object $matches[0] -Name "dimensionsInfos")) {
    $locations = @(Get-ObjectPropertyArray -Object $info -Name "applicableLocations")
    if ($locations.Count -gt 0 -and $locations -notcontains $Location -and $locations -notcontains "global") {
      continue
    }
    $candidateDimensions = Get-ObjectPropertyValue -Object $info -Name "dimensions"
    $specificity = 0
    $dimensionMatch = $true
    if ($null -ne $candidateDimensions) {
      foreach ($property in @($candidateDimensions.PSObject.Properties)) {
        if (-not $Dimensions.ContainsKey($property.Name) -or
            [string]$Dimensions[$property.Name] -ne [string]$property.Value) {
          $dimensionMatch = $false
          break
        }
        $specificity++
      }
    }
    if (-not $dimensionMatch) { continue }
    $details = Get-ObjectPropertyValue -Object $info -Name "details"
    $value = Get-ObjectPropertyValue -Object $details -Name "value"
    if ($null -eq $value) { continue }
    $candidates += [pscustomobject]@{ Specificity = $specificity; Value = [double]([string]$value) }
  }
  if ($candidates.Count -eq 0) { return $null }
  return [double](@($candidates | Sort-Object Specificity -Descending)[0].Value)
}

function Get-ProjectQuota {
  param([object]$ProjectInfo, [string]$Metric)
  $matches = @(Get-ObjectPropertyArray -Object $ProjectInfo -Name "quotas" | Where-Object {
    [string]$_.metric -eq $Metric
  })
  if ($matches.Count -ne 1) { return $null }
  return $matches[0]
}

function New-CapacityRow {
  param(
    [string]$Check, [string]$Metric, [string]$Scope, [object]$CurrentUsage,
    [double]$AdditionalRequired, [object]$Limit, [string]$Source, [string]$Details = ""
  )
  $status = "PASS"
  $projected = $null
  $availableBefore = $null
  $availableAfter = $null
  if ($null -eq $CurrentUsage) {
    $status = "UNVERIFIED"
  }
  elseif ($null -eq $Limit) {
    $status = "MISSING_LIMIT"
    $projected = [double]$CurrentUsage + $AdditionalRequired
  }
  else {
    $current = [double]$CurrentUsage
    $limitValue = [double]$Limit
    $projected = $current + $AdditionalRequired
    if ($limitValue -ge 0) {
      $availableBefore = $limitValue - $current
      $availableAfter = $limitValue - $projected
      if ($projected -gt $limitValue) { $status = "INSUFFICIENT" }
    }
    else {
      $availableBefore = "UNLIMITED"
      $availableAfter = "UNLIMITED"
    }
  }
  return [pscustomobject]@{
    Method = $Method; Check = $Check; Metric = $Metric; Scope = $Scope
    CurrentUsage = $CurrentUsage; AdditionalRequired = $AdditionalRequired
    ProjectedUsage = $projected; Limit = $Limit
    AvailableBefore = $availableBefore; AvailableAfter = $availableAfter
    Status = $status; Source = $Source; Details = $Details
  }
}

function Get-DesiredRoutingNodeNames {
  param([string]$Prefix, [int]$RoutingNodeCount)
  if ($RoutingNodeCount -lt 2) {
    throw "Native routing requires at least the Control Plane and Benchmark nodes."
  }
  $names = @("$Prefix-cp-0", "$Prefix-bench-0")
  for ($index = 0; $index -lt ($RoutingNodeCount - 2); $index++) {
    $names += "$Prefix-worker-$index"
  }
  return @($names)
}

function Get-DesiredInstanceNames {
  param([string]$Prefix, [int]$RoutingNodeCount)
  return @(Get-DesiredRoutingNodeNames -Prefix $Prefix -RoutingNodeCount $RoutingNodeCount)
}

function Get-DesiredStaticRouteNames {
  param([string]$Prefix, [int]$RoutingNodeCount)
  $routeNames = @()
  foreach ($nodeName in @(Get-DesiredRoutingNodeNames -Prefix $Prefix -RoutingNodeCount $RoutingNodeCount)) {
    if ($nodeName -eq "$Prefix-cp-0") {
      $routeNames += "$Prefix-pod-control-plane-0"
    }
    elseif ($nodeName -eq "$Prefix-bench-0") {
      $routeNames += "$Prefix-pod-benchmark-0"
    }
    elseif ($nodeName.StartsWith("$Prefix-worker-", [System.StringComparison]::Ordinal)) {
      $workerIndex = $nodeName.Substring(("$Prefix-worker-").Length)
      $routeNames += "$Prefix-pod-worker-$workerIndex"
    }
    else {
      throw "Unexpected native-routing node name: $nodeName"
    }
  }
  return @($routeNames)
}

function Convert-IPv4ToNumber {
  param([string]$Address)
  $parsed = $null
  if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
      $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "Invalid IPv4 address: $Address"
  }
  [uint64]$value = 0
  foreach ($byte in $parsed.GetAddressBytes()) { $value = ($value * 256) + $byte }
  return $value
}

function Get-IPv4CidrBounds {
  param([string]$Cidr)
  $parts = $Cidr -split "/"
  if ($parts.Count -ne 2) { throw "Invalid IPv4 CIDR: $Cidr" }
  $prefixLength = [int]$parts[1]
  if ($prefixLength -lt 0 -or $prefixLength -gt 32) { throw "Invalid IPv4 CIDR: $Cidr" }
  [uint64]$address = Convert-IPv4ToNumber -Address $parts[0]
  [uint64]$blockSize = [uint64][math]::Pow(2, (32 - $prefixLength))
  [uint64]$start = [uint64]([math]::Floor($address / $blockSize) * $blockSize)
  return [pscustomobject]@{ Start = $start; End = $start + $blockSize - 1 }
}

function Test-IPv4CidrInside {
  param([string]$Child, [string]$Parent)
  try {
    $childBounds = Get-IPv4CidrBounds -Cidr $Child
    $parentBounds = Get-IPv4CidrBounds -Cidr $Parent
    return $childBounds.Start -ge $parentBounds.Start -and $childBounds.End -le $parentBounds.End
  }
  catch { return $false }
}

function Test-StaticRoute {
  param([object]$Route)
  # routes list excludes dynamic routes; subnet and peering routes have their
  # own next-hop fields. The remainder are custom static routes.
  return $null -eq (Get-ObjectPropertyValue -Object $Route -Name "nextHopNetwork") -and
    $null -eq (Get-ObjectPropertyValue -Object $Route -Name "nextHopPeering")
}

function Get-NetworkNicInventory {
  param([object[]]$Instances, [string]$Network)
  $items = @()
  foreach ($instance in $Instances) {
    foreach ($nic in @(Get-ObjectPropertyArray -Object $instance -Name "networkInterfaces")) {
      if ((Get-ResourceTail (Get-ObjectPropertyValue -Object $nic -Name "network")) -eq $Network) {
        $items += [pscustomobject]@{ Instance = $instance; Nic = $nic }
      }
    }
  }
  return @($items)
}

Assert-Command "gcloud"
# The provisioning engines always pass -OutDir; this default only serves a
# standalone run and stays inside the script tree.
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $PSScriptRoot "results\standalone\native-routing-quota" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$tokenRaw = @(& gcloud auth print-access-token --quiet)
if ($LASTEXITCODE -ne 0) { throw "Failed to obtain a gcloud access token for the Cloud Quotas API." }
$accessToken = (($tokenRaw | Out-String).Trim())
if ([string]::IsNullOrWhiteSpace($accessToken)) { throw "gcloud returned an empty access token." }

$computeCatalog = @(Get-CloudQuotaCatalog -Service "compute.googleapis.com" -AccessToken $accessToken)
$networkInfo = Invoke-GcloudJson -Arguments @("compute", "networks", "describe", $NetworkName, "--project", $ProjectId)
$networkId = [string](Get-ObjectPropertyValue -Object $networkInfo -Name "id")
if ([string]::IsNullOrWhiteSpace($networkId)) { throw "Network '$NetworkName' did not return a numeric network id." }
$dimensions = @{ network_id = $networkId; region = $Region }
$projectInfo = Invoke-GcloudJson -Arguments @("compute", "project-info", "describe", "--project", $ProjectId)
$instances = @(Invoke-GcloudJson -Arguments @("compute", "instances", "list", "--project", $ProjectId))
$networkNics = @(Get-NetworkNicInventory -Instances $instances -Network $NetworkName)
$desiredInstanceNames = @(Get-DesiredInstanceNames -Prefix $ResourcePrefix -RoutingNodeCount $TargetRoutingNodeCount)
$existingDesiredInstanceNames = @($networkNics | Where-Object {
  $desiredInstanceNames -contains [string]$_.Instance.name
} | ForEach-Object { [string]$_.Instance.name } | Sort-Object -Unique)
$missingDesiredInstances = [math]::Max(0, $desiredInstanceNames.Count - $existingDesiredInstanceNames.Count)

$rows = @()
$rows += New-CapacityRow -Check "VPC network VM NICs" `
  -Metric "compute.googleapis.com/instances_per_vpc_network" -Scope "vpc:$NetworkName" `
  -CurrentUsage $networkNics.Count -AdditionalRequired $missingDesiredInstances `
  -Limit (Get-EffectiveQuotaLimit -Catalog $computeCatalog -Metric "compute.googleapis.com/instances_per_vpc_network" -Dimensions $dimensions -Location "global") `
  -Source "gcloud compute instances list + Cloud Quotas API" `
  -Details "Counts NICs. Terraform-state VM delta=$NewNodeCount; actual desired VM names missing=$missingDesiredInstances."

switch ($Method) {
  "static" {
    $routes = @(Invoke-GcloudJson -Arguments @("compute", "routes", "list", "--project", $ProjectId))
    $staticRoutes = @($routes | Where-Object {
      (Get-ResourceTail (Get-ObjectPropertyValue -Object $_ -Name "network")) -eq $NetworkName -and
      (Test-StaticRoute -Route $_)
    })
    $desiredRouteNames = @(Get-DesiredStaticRouteNames -Prefix $ResourcePrefix -RoutingNodeCount $TargetRoutingNodeCount)
    $existingRouteNames = @($staticRoutes | ForEach-Object { [string]$_.name })
    $missingRoutes = @($desiredRouteNames | Where-Object { $existingRouteNames -notcontains $_ }).Count
    $rows += New-CapacityRow -Check "Static routes per VPC network" `
      -Metric "compute.googleapis.com/static_routes_per_vpc_network" -Scope "vpc:$NetworkName" `
      -CurrentUsage $staticRoutes.Count -AdditionalRequired $missingRoutes `
      -Limit (Get-EffectiveQuotaLimit -Catalog $computeCatalog -Metric "compute.googleapis.com/static_routes_per_vpc_network" -Dimensions $dimensions -Location "global") `
      -Source "gcloud compute routes list + Cloud Quotas API" `
      -Details "Target PodCIDR routes=$TargetRoutingNodeCount; missing experiment routes=$missingRoutes; CP included; state-derived routing delta=$AdditionalRoutingNodeCount."
  }

  "dynamic" {
    $enabledServices = @(Invoke-GcloudJson -Arguments @(
      "services", "list", "--enabled", "--project", $ProjectId,
      "--filter", "config.name=networkconnectivity.googleapis.com"
    ))
    $nccApiEnabled = $enabledServices.Count -gt 0
    if (-not $nccApiEnabled) {
      throw "Dynamic quota preflight requires networkconnectivity.googleapis.com to be enabled. Run 'gcloud services enable networkconnectivity.googleapis.com --project $ProjectId' and retry."
    }
    $nccCatalog = @(Get-CloudQuotaCatalog -Service "networkconnectivity.googleapis.com" -AccessToken $accessToken)
    $hubs = @(Invoke-GcloudJson -Arguments @("network-connectivity", "hubs", "list", "--project", $ProjectId))
    $spokes = @(Invoke-GcloudJson -Arguments @("network-connectivity", "spokes", "list", "--region", $Region, "--project", $ProjectId))

    $hubName = "$ResourcePrefix-hub"
    $spokeName = "$ResourcePrefix-spoke"
    $routerName = "$ResourcePrefix-router"
    $matchingHub = @($hubs | Where-Object { (Get-ResourceTail $_.name) -eq $hubName })
    $matchingSpoke = @($spokes | Where-Object { (Get-ResourceTail $_.name) -eq $spokeName })
    $routerApplianceSpokes = @($spokes | Where-Object {
      $null -ne (Get-ObjectPropertyValue -Object $_ -Name "linkedRouterApplianceInstances")
    })
    $needHub = if ($matchingHub.Count -eq 0) { 1 } else { 0 }
    $needSpoke = if ($matchingSpoke.Count -eq 0) { 1 } else { 0 }

    $rows += New-CapacityRow -Check "NCC hubs per project" `
      -Metric "networkconnectivity.googleapis.com/global-per-project-hubs" -Scope "project:$ProjectId" `
      -CurrentUsage $hubs.Count -AdditionalRequired $needHub `
      -Limit (Get-EffectiveQuotaLimit -Catalog $nccCatalog -Metric "networkconnectivity.googleapis.com/global-per-project-hubs" -Dimensions @{} -Location "global") `
      -Source "gcloud network-connectivity hubs list + Cloud Quotas API" `
      -Details "Network Connectivity API enabled=$nccApiEnabled; the API is an explicit prerequisite and is never changed by the experiment."

    $rows += New-CapacityRow -Check "NCC Router Appliance spokes per project/region" `
      -Metric "networkconnectivity.googleapis.com/regional-per-project-router-appliance-instance-spokes" `
      -Scope "project:$ProjectId/region:$Region" -CurrentUsage $routerApplianceSpokes.Count `
      -AdditionalRequired $needSpoke `
      -Limit (Get-EffectiveQuotaLimit -Catalog $nccCatalog -Metric "networkconnectivity.googleapis.com/regional-per-project-router-appliance-instance-spokes" -Dimensions @{ region = $Region } -Location $Region) `
      -Source "gcloud network-connectivity spokes list + Cloud Quotas API" `
      -Details "One regional Router Appliance spoke is shared by all experiment routing nodes."

    $routers = @(Invoke-GcloudJson -Arguments @("compute", "routers", "list", "--project", $ProjectId))
    $networkRouters = @($routers | Where-Object {
      (Get-ResourceTail (Get-ObjectPropertyValue -Object $_ -Name "network")) -eq $NetworkName -and
      (Get-ResourceTail (Get-ObjectPropertyValue -Object $_ -Name "region")) -eq $Region
    })
    $matchingRouter = @($networkRouters | Where-Object { [string]$_.name -eq $routerName })
    $needRouter = if ($matchingRouter.Count -eq 0) { 1 } else { 0 }
    $routerQuota = Get-ProjectQuota -ProjectInfo $projectInfo -Metric "ROUTERS"
    $routerQuotaUsage = if ($null -eq $routerQuota) { $null } else { [double]$routerQuota.usage }

    $rows += New-CapacityRow -Check "Cloud Routers per project" `
      -Metric "compute.googleapis.com/routers" -Scope "project:$ProjectId" `
      -CurrentUsage $routerQuotaUsage -AdditionalRequired $needRouter `
      -Limit (Get-EffectiveQuotaLimit -Catalog $computeCatalog -Metric "compute.googleapis.com/routers" -Dimensions @{} -Location "global") `
      -Source "gcloud compute project-info describe + Cloud Quotas API" `
      -Details "The Dynamic method creates one Cloud Router when its owned router is absent."

    $rows += New-CapacityRow -Check "Cloud Routers per VPC network/region" `
      -Metric "system-limit:cloud-routers-per-vpc-region" -Scope "vpc:$NetworkName/region:$Region" `
      -CurrentUsage $networkRouters.Count -AdditionalRequired $needRouter -Limit 5 `
      -Source "gcloud compute routers list + Cloud Router system limits" -Details "Fixed Google Cloud system limit."

    $currentPeers = @()
    if ($matchingRouter.Count -eq 1) {
      $currentPeers = @(Get-ObjectPropertyArray -Object $matchingRouter[0] -Name "bgpPeers")
    }
    $desiredRoutingNames = @(Get-DesiredRoutingNodeNames -Prefix $ResourcePrefix -RoutingNodeCount $TargetRoutingNodeCount)
    $desiredPeerNames = @()
    foreach ($nodeName in $desiredRoutingNames) {
      $desiredPeerNames += "peer-$nodeName-0"
      $desiredPeerNames += "peer-$nodeName-1"
    }
    $currentPeerNames = @($currentPeers | ForEach-Object { [string]$_.name })
    $missingPeers = @($desiredPeerNames | Where-Object { $currentPeerNames -notcontains $_ }).Count
    $rows += New-CapacityRow -Check "BGP peers on the experiment Cloud Router" `
      -Metric "system-limit:bgp-peers-per-cloud-router" -Scope "router:$routerName" `
      -CurrentUsage $currentPeers.Count -AdditionalRequired $missingPeers -Limit 128 `
      -Source "gcloud compute routers list + Cloud Router system limits" `
      -Details "Two BGP sessions per routed node; target peers=$($desiredPeerNames.Count); CP included."

    $currentAppliances = @()
    if ($matchingSpoke.Count -eq 1) {
      $linked = Get-ObjectPropertyValue -Object $matchingSpoke[0] -Name "linkedRouterApplianceInstances"
      $currentAppliances = @(Get-ObjectPropertyArray -Object $linked -Name "instances")
    }
    $additionalAppliances = [math]::Max(0, $TargetRoutingNodeCount - $currentAppliances.Count)
    $rows += New-CapacityRow -Check "Router Appliance instances linked to one spoke" `
      -Metric "system-limit:router-appliance-instances-per-spoke" -Scope "spoke:$spokeName" `
      -CurrentUsage $currentAppliances.Count -AdditionalRequired $additionalAppliances -Limit 8 `
      -Source "gcloud network-connectivity spokes list + NCC system limits" `
      -Details "The spoke is updated to the target set; target appliances=$TargetRoutingNodeCount."

    $allBgpRoutes = @()
    $experimentBgpRoutes = @()
    foreach ($router in $networkRouters) {
      $status = Invoke-GcloudJson -Arguments @(
        "compute", "routers", "get-status", [string]$router.name,
        "--region", $Region, "--project", $ProjectId
      )
      $result = Get-ObjectPropertyValue -Object $status -Name "result"
      $bestRoutes = @(Get-ObjectPropertyArray -Object $result -Name "bestRoutesForRouter" | Where-Object {
        [string](Get-ObjectPropertyValue -Object $_ -Name "routeType") -eq "BGP"
      })
      $allBgpRoutes += $bestRoutes
      if ([string]$router.name -eq $routerName) {
        $experimentBgpRoutes += @($bestRoutes | Where-Object {
          Test-IPv4CidrInside -Child ([string]$_.destRange) -Parent $ClusterPodCidr
        })
      }
    }
    $allUniquePrefixes = @($allBgpRoutes | ForEach-Object { [string]$_.destRange } | Sort-Object -Unique)
    $experimentUniquePrefixes = @($experimentBgpRoutes | ForEach-Object { [string]$_.destRange } | Sort-Object -Unique)
    $missingExperimentPrefixes = [math]::Max(0, $TargetRoutingNodeCount - $experimentUniquePrefixes.Count)
    $missingExperimentRoutePaths = [math]::Max(0, (2 * $TargetRoutingNodeCount) - $experimentBgpRoutes.Count)

    $rows += New-CapacityRow -Check "Unique Cloud Router prefixes from own region" `
      -Metric "compute.googleapis.com/cloud_router_prefixes_from_own_region_per_region_per_vpc_network" `
      -Scope "vpc:$NetworkName/region:$Region" -CurrentUsage $allUniquePrefixes.Count `
      -AdditionalRequired $missingExperimentPrefixes `
      -Limit (Get-EffectiveQuotaLimit -Catalog $computeCatalog -Metric "compute.googleapis.com/cloud_router_prefixes_from_own_region_per_region_per_vpc_network" -Dimensions $dimensions -Location $Region) `
      -Source "gcloud compute routers get-status + Cloud Quotas API" `
      -Details "Current unique learned BGP destinations plus missing experiment PodCIDRs; target experiment prefixes=$TargetRoutingNodeCount."

    $networkPeerings = @(Get-ObjectPropertyArray -Object $networkInfo -Name "peerings")
    $dynamicUsage = if ($networkPeerings.Count -eq 0) { $allBgpRoutes.Count } else { $null }
    $dynamicUsageSource = if ($networkPeerings.Count -eq 0) {
      "gcloud compute routers get-status"
    }
    else {
      "unverified: VPC peering exists"
    }
    $rows += New-CapacityRow -Check "Dynamic routes per region per peering group" `
      -Metric "compute.googleapis.com/dynamic_routes_per_region_per_peering_group" `
      -Scope "vpc:$NetworkName/region:$Region" -CurrentUsage $dynamicUsage `
      -AdditionalRequired $missingExperimentRoutePaths `
      -Limit (Get-EffectiveQuotaLimit -Catalog $computeCatalog -Metric "compute.googleapis.com/dynamic_routes_per_region_per_peering_group" -Dimensions $dimensions -Location $Region) `
      -Source "$dynamicUsageSource + Cloud Quotas API" `
      -Details "Two learned paths per PodCIDR. A peered VPC is blocked because local Router status cannot prove whole peering-group usage."

    $rows += New-CapacityRow -Check "Prefixes accepted from each BGP peer" `
      -Metric "system-limit:prefixes-per-bgp-peer" -Scope "each experiment BGP peer" `
      -CurrentUsage 0 -AdditionalRequired 1 -Limit 5000 `
      -Source "Cilium PodCIDR advertisement design + Cloud Router system limits" `
      -Details "Each experiment peer advertises exactly one Kubernetes PodCIDR."
  }
}

$jsonPath = Join-Path $OutDir "native-routing-quota-check.json"
$csvPath = Join-Path $OutDir "native-routing-quota-check.csv"
$rows | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $jsonPath
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath
$rows | Format-Table Check, CurrentUsage, AdditionalRequired, ProjectedUsage, Limit, AvailableAfter, Status -AutoSize | Out-String | Write-Host

$blocking = @($rows | Where-Object { $_.Status -ne "PASS" })
if ($blocking.Count -gt 0) {
  throw "Native-routing quota preflight failed for method '$Method'. See $csvPath."
}
Write-Host "Native-routing quota preflight passed for $Method. Wrote $csvPath"
