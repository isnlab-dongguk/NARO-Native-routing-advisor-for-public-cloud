Set-StrictMode -Version Latest

# This file is dot-sourced by provision.ps1 after its SSH, gcloud, and
# command-timing helpers have been defined.  It deliberately contains only T4
# functions so VXLAN and Host keep their existing no-op boundary.

function Get-T4StatePath {
  param(
    [string]$TfDirFull,
    [string]$Method
  )
  return (Join-Path $TfDirFull ".native-routing-t4-$Method.json")
}

function Write-T4State {
  param(
    [string]$Path,
    [object]$State
  )
  ConvertTo-Json -InputObject $State -Depth 12 |
    Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-T4State {
  param(
    [string]$Path,
    [string]$Method,
    [string]$ProjectId,
    [string]$ResourcePrefix
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ([int]$state.schema_version -ne 1 -or
      [string]$state.method -ne $Method -or
      [string]$state.project_id -ne $ProjectId -or
      [string]$state.resource_prefix -ne $ResourcePrefix) {
    throw "T4 ownership state does not match this run: $Path"
  }
  return $state
}

function Test-T4GcloudResource {
  param([string[]]$Arguments)

  $output = @()
  $exitCode = -1
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& gcloud @Arguments --format="value(name)" --verbosity=error 2>$null)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  return ($exitCode -eq 0 -and @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
}

function Get-T4GcloudJson {
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

function Get-T4ResourceMapByName {
  # One list call replaces the per-node describe pattern for existence,
  # collision, and verification checks: the results are indexed by name and
  # every decision happens in memory, so the gcloud cold-start cost is paid
  # once instead of once per node.
  param([string[]]$Arguments)

  $items = @(Get-T4GcloudJson -Arguments $Arguments)
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

function Get-T4PropertyArray {
  param(
    [object]$Object,
    [string]$Name
  )
  if ($null -eq $Object) {
    return @()
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return @()
  }
  return @($property.Value)
}

function Invoke-T4Gcloud {
  param(
    [string[]]$Arguments,
    [string]$TfDirFull,
    [string]$OutDirFull,
    [string]$Name
  )

  $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-')
  Invoke-Native `
    -File "gcloud" `
    -Arguments ($Arguments + @("--quiet")) `
    -WorkingDirectory $TfDirFull `
    -LogPath (Join-Path $OutDirFull "t4-$safeName.log") `
    -TimingName "T4 $Name"
}

function Test-NetworkConnectivityApiEnabled {
  param([string]$ProjectId)

  $output = @()
  $exitCode = -1
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& gcloud services list --enabled --project $ProjectId `
      --filter "config.name=networkconnectivity.googleapis.com" --format "value(config.name)")
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($exitCode -ne 0) {
    throw "Failed to query whether networkconnectivity.googleapis.com is enabled."
  }
  return (@($output | Where-Object { $_ -eq "networkconnectivity.googleapis.com" }).Count -eq 1)
}

function Get-NativeRoutingTargets {
  param(
    [object]$ControlPlane,
    [object[]]$RoutingNodes,
    [string]$SshUser,
    [string]$SshKeyFile
  )

  # Kubernetes owns the per-node PodCIDR allocation.  Never derive it from a
  # worker index: kube-controller-manager is the source of truth.
  $nodeJson = Invoke-NodeSshCapture `
    -Node $ControlPlane `
    -SshUser $SshUser `
    -SshKeyFile $SshKeyFile `
    -Command "kubectl get nodes -o json"
  $kubernetesNodes = @((ConvertFrom-Json -InputObject $nodeJson).items)
  $targets = @()

  foreach ($node in $RoutingNodes) {
    $matches = @($kubernetesNodes | Where-Object { $_.metadata.name -eq $node.name })
    if ($matches.Count -ne 1) {
      throw "Expected exactly one Kubernetes Node for '$($node.name)', found $($matches.Count)."
    }
    $podCidr = [string]$matches[0].spec.podCIDR
    if ([string]::IsNullOrWhiteSpace($podCidr)) {
      throw "Kubernetes has not assigned a PodCIDR to '$($node.name)'."
    }
    $targets += [pscustomobject]@{
      name       = [string]$node.name
      node_name  = [string]$node.name
      role       = [string]$node.role
      role_index = [int]$node.role_index
      zone       = [string]$node.zone
      private_ip = [string]$node.private_ip
      external_ip = [string]$node.external_ip
      pod_cidr   = $podCidr
    }
  }

  $duplicateCidrs = @($targets | Group-Object pod_cidr | Where-Object { $_.Count -ne 1 })
  if ($duplicateCidrs.Count -gt 0) {
    throw "Duplicate PodCIDRs detected for native-routing targets: $($duplicateCidrs.Name -join ', ')"
  }
  return $targets
}

function New-T4OwnershipState {
  param(
    [string]$Method,
    [string]$ProjectId,
    [string]$NetworkName,
    [string]$SubnetworkName,
    [string]$Region,
    [string]$ResourcePrefix,
    [object[]]$Targets
  )

  return [ordered]@{
    schema_version  = 1
    method          = $Method
    project_id      = $ProjectId
    network_name    = $NetworkName
    subnetwork_name = $SubnetworkName
    region          = $Region
    resource_prefix = $ResourcePrefix
    claimed_at      = (Get-Date).ToUniversalTime().ToString("o")
    # Every Kubernetes node is included. CoreDNS can tolerate the control-plane
    # taint and uses a regular Pod IP, so the CP PodCIDR must remain reachable.
    nodes            = @($Targets)
  }
}

function Invoke-StaticRoutingT4 {
  param(
    [object[]]$Targets,
    [string]$ProjectId,
    [string]$NetworkName,
    [string]$SubnetworkName,
    [string]$Region,
    [string]$ResourcePrefix,
    [string]$TfDirFull,
    [string]$OutDirFull
  )

  $statePath = Get-T4StatePath -TfDirFull $TfDirFull -Method "static"
  $state = Read-T4State -Path $statePath -Method "static" -ProjectId $ProjectId -ResourcePrefix $ResourcePrefix

  # Route names only ever contain [-a-z0-9] (GCE naming rules), so the anchored
  # regex filter is safe. One list snapshot answers every collision/existence
  # question that previously cost one describe per node.
  $routeListArguments = @(
    "compute", "routes", "list",
    "--project", $ProjectId,
    "--filter", "name~^$ResourcePrefix-pod-"
  )
  $routeMap = Get-T4ResourceMapByName -Arguments $routeListArguments

  if ($null -eq $state) {
    foreach ($target in $Targets) {
      $routeName = "$ResourcePrefix-pod-$($target.role)-$($target.role_index)"
      if ($routeMap.ContainsKey($routeName)) {
        throw "Refusing to claim pre-existing static route '$routeName'."
      }
    }
    $state = New-T4OwnershipState -Method "static" -ProjectId $ProjectId -NetworkName $NetworkName `
      -SubnetworkName $SubnetworkName -Region $Region -ResourcePrefix $ResourcePrefix -Targets $Targets
  }
  else {
    $previousNodes = @(Get-T4PropertyArray -Object $state -Name "nodes")
    $previousRouteNames = @($previousNodes | ForEach-Object { "$ResourcePrefix-pod-$($_.role)-$($_.role_index)" })
    foreach ($target in $Targets) {
      $routeName = "$ResourcePrefix-pod-$($target.role)-$($target.role_index)"
      if ($previousRouteNames -notcontains $routeName -and $routeMap.ContainsKey($routeName)) {
        throw "Refusing to claim pre-existing expansion route '$routeName'."
      }
    }
    $state.nodes = @($Targets)
  }
  # Claim ownership before the first mutation so partial T4 failures are safe
  # for the automatic destroy path.
  Write-T4State -Path $statePath -State $state

  foreach ($target in $Targets) {
    $routeName = "$ResourcePrefix-pod-$($target.role)-$($target.role_index)"
    if (-not $routeMap.ContainsKey($routeName)) {
      Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "static-route-$routeName" -Arguments @(
        "compute", "routes", "create", $routeName,
        "--project", $ProjectId,
        "--network", $NetworkName,
        "--destination-range", [string]$target.pod_cidr,
        "--next-hop-address", [string]$target.private_ip,
        "--priority", "900",
        "--description", "Cilium PodCIDR for $($target.node_name)"
      )
    }
  }

  # Re-list once after the creates and verify every route in memory (this
  # replaces the former one-describe-per-node verification pass).
  $verifiedRouteMap = Get-T4ResourceMapByName -Arguments $routeListArguments
  foreach ($target in $Targets) {
    $routeName = "$ResourcePrefix-pod-$($target.role)-$($target.role_index)"
    $route = if ($verifiedRouteMap.ContainsKey($routeName)) { $verifiedRouteMap[$routeName] } else { $null }
    if ($null -eq $route -or
        [string]$route.destRange -ne [string]$target.pod_cidr -or
        [string]$route.nextHopIp -ne [string]$target.private_ip) {
      throw "Static route '$routeName' does not map $($target.pod_cidr) to $($target.private_ip)."
    }
  }
}

function Invoke-DynamicRoutingT4 {
  param(
    [object[]]$Targets,
    [object]$ControlPlane,
    [string]$SshUser,
    [string]$SshKeyFile,
    [string]$ProjectId,
    [string]$NetworkName,
    [string]$SubnetworkName,
    [string]$Region,
    [string]$ResourcePrefix,
    [string]$TfDirFull,
    [string]$OutDirFull
  )

  $routerAsn = 64514
  $nodeAsn = 64512
  $hubName = "$ResourcePrefix-hub"
  $spokeName = "$ResourcePrefix-spoke"
  $routerName = "$ResourcePrefix-router"
  $interfaceNames = @("$ResourcePrefix-if-0", "$ResourcePrefix-if-1")
  $statePath = Get-T4StatePath -TfDirFull $TfDirFull -Method "dynamic"
  $state = Read-T4State -Path $statePath -Method "dynamic" -ProjectId $ProjectId -ResourcePrefix $ResourcePrefix

  if ($null -eq $state) {
    if (-not (Test-NetworkConnectivityApiEnabled -ProjectId $ProjectId)) {
      throw "Dynamic T4 requires networkconnectivity.googleapis.com to be enabled before provisioning. Run 'gcloud services enable networkconnectivity.googleapis.com --project $ProjectId' and retry."
    }
    $state = New-T4OwnershipState -Method "dynamic" -ProjectId $ProjectId -NetworkName $NetworkName `
      -SubnetworkName $SubnetworkName -Region $Region -ResourcePrefix $ResourcePrefix -Targets $Targets
    $state["resources_claimed"] = $false
    # The API is project-scoped shared state and an explicit prerequisite. The
    # marker owns only NCC resources; provisioning and destroy never change it.
    Write-T4State -Path $statePath -State $state

    $collisions = @()
    if (Test-T4GcloudResource -Arguments @("network-connectivity", "hubs", "describe", $hubName, "--project", $ProjectId)) { $collisions += $hubName }
    if (Test-T4GcloudResource -Arguments @("network-connectivity", "spokes", "describe", $spokeName, "--region", $Region, "--project", $ProjectId)) { $collisions += $spokeName }
    if (Test-T4GcloudResource -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId)) { $collisions += $routerName }
    if ($collisions.Count -gt 0) {
      throw "Refusing to claim pre-existing Dynamic T4 resources: $($collisions -join ', ')"
    }
    $state["resources_claimed"] = $true
  }
  else {
    if ($null -eq $state.PSObject.Properties["resources_claimed"] -or
        -not [bool]$state.resources_claimed) {
      throw "Dynamic T4 ownership state is incomplete or has not claimed its resources: $statePath"
    }
    $state.nodes = @($Targets)
  }
  Write-T4State -Path $statePath -State $state

  if (-not (Test-T4GcloudResource -Arguments @("network-connectivity", "hubs", "describe", $hubName, "--project", $ProjectId))) {
    Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-hub-create" -Arguments @(
      "network-connectivity", "hubs", "create", $hubName,
      "--project", $ProjectId,
      "--description", "Cilium native-routing experiment NCC hub",
      "--labels", "experiment=dynamic"
    )
  }

  # Keep the requested control-plane sequence explicit: NCC hub, Cloud Router,
  # then registration of the target VMs in the Router Appliance spoke.
  if (-not (Test-T4GcloudResource -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId))) {
    Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-router-create" -Arguments @(
      "compute", "routers", "create", $routerName,
      "--project", $ProjectId,
      "--region", $Region,
      "--network", $NetworkName,
      "--asn", [string]$routerAsn
    )
  }

  $applianceArguments = @()
  foreach ($target in $Targets) {
    $instanceUri = "https://www.googleapis.com/compute/v1/projects/$ProjectId/zones/$($target.zone)/instances/$($target.node_name)"
    $applianceArguments += "--router-appliance=instance=$instanceUri,ip=$($target.private_ip)"
  }
  if (-not (Test-T4GcloudResource -Arguments @("network-connectivity", "spokes", "describe", $spokeName, "--region", $Region, "--project", $ProjectId))) {
    Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-spoke-create" -Arguments (@(
      "network-connectivity", "spokes", "linked-router-appliances", "create", $spokeName,
      "--project", $ProjectId,
      "--region", $Region,
      "--hub", $hubName,
      "--description", "Cilium nodes registered as NCC router appliances",
      "--labels", "experiment=dynamic"
    ) + $applianceArguments)
  }
  else {
    Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-spoke-update" -Arguments (@(
      "network-connectivity", "spokes", "linked-router-appliances", "update", $spokeName,
      "--project", $ProjectId,
      "--region", $Region
    ) + $applianceArguments)
  }

  $router = Get-T4GcloudJson -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId)
  if ([int]$router.bgp.asn -ne $routerAsn) {
    throw "Cloud Router '$routerName' ASN is $($router.bgp.asn), expected $routerAsn."
  }
  $routerInterfaces = @(Get-T4PropertyArray -Object $router -Name "interfaces")
  $existingInterfaceNames = @($routerInterfaces | ForEach-Object { [string]$_.name })
  if ($existingInterfaceNames -notcontains $interfaceNames[0]) {
    Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-interface-0" -Arguments @(
      "compute", "routers", "add-interface", $routerName,
      "--project", $ProjectId,
      "--region", $Region,
      "--interface-name", $interfaceNames[0],
      "--subnetwork", $SubnetworkName
    )
  }

  $router = Get-T4GcloudJson -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId)
  $routerInterfaces = @(Get-T4PropertyArray -Object $router -Name "interfaces")
  $existingInterfaceNames = @($routerInterfaces | ForEach-Object { [string]$_.name })
  if ($existingInterfaceNames -notcontains $interfaceNames[1]) {
    Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-interface-1" -Arguments @(
      "compute", "routers", "add-interface", $routerName,
      "--project", $ProjectId,
      "--region", $Region,
      "--interface-name", $interfaceNames[1],
      "--subnetwork", $SubnetworkName,
      "--redundant-interface", $interfaceNames[0]
    )
  }

  $router = Get-T4GcloudJson -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId)
  $routerInterfaces = @(Get-T4PropertyArray -Object $router -Name "interfaces")
  $interfaceIps = @()
  foreach ($interfaceName in $interfaceNames) {
    $matches = @($routerInterfaces | Where-Object { $_.name -eq $interfaceName })
    if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$matches[0].privateIpAddress)) {
      throw "Cloud Router interface '$interfaceName' has no RFC1918 privateIpAddress."
    }
    $interfaceIps += [string]$matches[0].privateIpAddress
  }

  $routerPeers = @(Get-T4PropertyArray -Object $router -Name "bgpPeers")
  $existingPeerNames = @($routerPeers | ForEach-Object { [string]$_.name })
  foreach ($target in $Targets) {
    for ($index = 0; $index -lt 2; $index++) {
      $peerName = "peer-$($target.node_name)-$index"
      if ($existingPeerNames -contains $peerName) {
        continue
      }
      Invoke-T4Gcloud -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-$peerName" -Arguments @(
        "compute", "routers", "add-bgp-peer", $routerName,
        "--project", $ProjectId,
        "--region", $Region,
        "--peer-name", $peerName,
        "--interface", $interfaceNames[$index],
        "--peer-ip-address", [string]$target.private_ip,
        "--peer-asn", [string]$nodeAsn,
        "--instance", [string]$target.node_name,
        "--instance-zone", [string]$target.zone
      )
    }
  }

  $router = Get-T4GcloudJson -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId)
  $configuredPeers = @(Get-T4PropertyArray -Object $router -Name "bgpPeers")
  foreach ($target in $Targets) {
    for ($index = 0; $index -lt 2; $index++) {
      $peerName = "peer-$($target.node_name)-$index"
      $matches = @($configuredPeers | Where-Object { $_.name -eq $peerName })
      if ($matches.Count -ne 1 -or
          [string]$matches[0].interfaceName -ne $interfaceNames[$index] -or
          [string]$matches[0].peerIpAddress -ne [string]$target.private_ip -or
          [int]$matches[0].peerAsn -ne $nodeAsn) {
        throw "Cloud Router BGP peer '$peerName' does not match its node/interface/ASN contract."
      }
    }
  }

  $expectedSessions = $Targets.Count * 2
  $bgpScript = @'
#!/usr/bin/env bash
set -euo pipefail
cat >/tmp/cilium-dynamic-bgp.yaml <<'EOF_BGP'
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: dynamic-podcidr
  labels:
    advertise: dynamic-podcidr
spec:
  advertisements:
    - advertisementType: PodCIDR
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: dynamic-cloud-router
spec:
  timers:
    connectRetryTimeSeconds: 5
    holdTimeSeconds: 15
    keepAliveTimeSeconds: 5
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: dynamic-podcidr
---
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: dynamic-cloud-router
spec:
  nodeSelector:
    matchExpressions:
      - key: experiment-role
        operator: In
        values:
          - control-plane
          - benchmark
          - worker
  bgpInstances:
    - name: dynamic
      localASN: __NODE_ASN__
      peers:
        - name: cloud-router-0
          peerASN: __ROUTER_ASN__
          peerAddress: __PEER_0__
          peerConfigRef:
            name: dynamic-cloud-router
        - name: cloud-router-1
          peerASN: __ROUTER_ASN__
          peerAddress: __PEER_1__
          peerConfigRef:
            name: dynamic-cloud-router
EOF_BGP
kubectl apply -f /tmp/cilium-dynamic-bgp.yaml

# VM-local poll: 1s interval (kept consistent across methods); 600 iterations
# preserve the original ~10-minute window (was 120 x 5s).
for _ in $(seq 1 600); do
  established="$(cilium bgp peers 2>/dev/null | awk 'tolower($0) ~ /established/ {count++} END {print count+0}')"
  if [[ "$established" -eq __EXPECTED_SESSIONS__ ]]; then
    cilium bgp peers
    exit 0
  fi
  sleep 1
done
cilium bgp peers || true
echo "Expected __EXPECTED_SESSIONS__ established Cilium BGP sessions." >&2
exit 1
'@
  $bgpScript = $bgpScript.Replace("__NODE_ASN__", [string]$nodeAsn).
    Replace("__ROUTER_ASN__", [string]$routerAsn).
    Replace("__PEER_0__", $interfaceIps[0]).
    Replace("__PEER_1__", $interfaceIps[1]).
    Replace("__EXPECTED_SESSIONS__", [string]$expectedSessions)
  Invoke-RemoteScript -Node $ControlPlane -SshUser $SshUser -SshKeyFile $SshKeyFile `
    -Name "dynamic-configure-cilium-bgp" -ScriptContent $bgpScript `
    -LogPath (Join-Path $OutDirFull "t4-dynamic-cilium-bgp.log")

  $expectedPeerNames = @()
  foreach ($target in $Targets) {
    $expectedPeerNames += "peer-$($target.node_name)-0"
    $expectedPeerNames += "peer-$($target.node_name)-1"
  }
  $deadline = (Get-Date).AddMinutes(10)
  do {
    $status = Get-T4GcloudJson -Arguments @("compute", "routers", "get-status", $routerName, "--region", $Region, "--project", $ProjectId)
    $resultProperty = $status.PSObject.Properties["result"]
    $allPeerStatuses = if ($null -eq $resultProperty) { @() } else { @(Get-T4PropertyArray -Object $resultProperty.Value -Name "bgpPeerStatus") }
    $peerStatuses = @($allPeerStatuses | Where-Object { $expectedPeerNames -contains $_.name })
    $established = @($peerStatuses | Where-Object {
      $statusProperty = $_.PSObject.Properties["status"]
      $stateProperty = $_.PSObject.Properties["state"]
      ($null -ne $statusProperty -and [string]$statusProperty.Value -eq "UP") -or
        ($null -ne $stateProperty -and [string]$stateProperty.Value -eq "Established")
    })
    $learned = @($established | Where-Object {
      $learnedProperty = $_.PSObject.Properties["numLearnedRoutes"]
      $null -ne $learnedProperty -and [int]$learnedProperty.Value -ge 1
    })
    if ($peerStatuses.Count -eq $expectedSessions -and $learned.Count -eq $expectedSessions) {
      break
    }
    # No artificial delay: the next probe is sent as soon as this response is
    # parsed. Each probe launches a fresh gcloud process (start + API round
    # trip, roughly 1-3s), which is the natural pacing, so this cannot become
    # a tight busy-loop. The 10-minute deadline above remains the only cap.
  } while ((Get-Date) -lt $deadline)

  if ($peerStatuses.Count -ne $expectedSessions -or $learned.Count -ne $expectedSessions) {
    throw "Cloud Router did not establish all $expectedSessions BGP sessions with at least one learned PodCIDR route each."
  }
}

function Invoke-NativeRoutingT4 {
  param(
    [ValidateSet("static", "dynamic")]
    [string]$Method,
    [object]$ControlPlane,
    [object[]]$RoutingNodes,
    [string]$SshUser,
    [string]$SshKeyFile,
    [string]$ProjectId,
    [string]$NetworkName,
    [string]$SubnetworkName,
    [string]$Region,
    [string]$ResourcePrefix,
    [string]$TfDirFull,
    [string]$OutDirFull
  )

  $targets = @(Get-NativeRoutingTargets -ControlPlane $ControlPlane -RoutingNodes $RoutingNodes `
    -SshUser $SshUser -SshKeyFile $SshKeyFile)
  if ($targets.Count -ne $RoutingNodes.Count) {
    throw "Native-routing target count mismatch: expected $($RoutingNodes.Count), found $($targets.Count)."
  }

  switch ($Method) {
    "static" {
      Invoke-StaticRoutingT4 -Targets $targets -ProjectId $ProjectId -NetworkName $NetworkName `
        -SubnetworkName $SubnetworkName -Region $Region -ResourcePrefix $ResourcePrefix `
        -TfDirFull $TfDirFull -OutDirFull $OutDirFull
    }
    "dynamic" {
      Invoke-DynamicRoutingT4 -Targets $targets -ControlPlane $ControlPlane -SshUser $SshUser `
        -SshKeyFile $SshKeyFile -ProjectId $ProjectId -NetworkName $NetworkName `
        -SubnetworkName $SubnetworkName -Region $Region -ResourcePrefix $ResourcePrefix `
        -TfDirFull $TfDirFull -OutDirFull $OutDirFull
    }
  }
}
