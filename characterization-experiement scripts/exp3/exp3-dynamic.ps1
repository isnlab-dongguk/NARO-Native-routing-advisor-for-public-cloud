[CmdletBinding()]
param(
  [string]$TfDir = "",
  [string]$VarFile = "",
  [string]$OutDir = ".\results\exp3",
  [string]$Namespace = "exp2-bench",
  [ValidateRange(1, 20)] [int]$Repetitions = 3,
  [ValidateRange(1025, 65535)] [int]$ProbePort = 10002,
  # Parallel (stagger) probe pipeline: a new probe is fired every interval, so
  # the T2 resolution is about the interval (20ms by default). The timeout is
  # only a per-probe connect wait cap, unrelated to resolution, so it is kept
  # generous to avoid a spurious FAIL from a momentary delay.
  [ValidateRange(0.005, 5.0)] [double]$ProbeIntervalSeconds = 0.02,
  [ValidateRange(0.05, 5.0)] [double]$ProbeTimeoutSeconds = 0.5,
  [ValidateRange(3, 1000)] [int]$LossConfirmProbes = 10,
  [ValidateRange(1, 600)] [int]$LossConfirmSeconds = 5,
  [ValidateRange(1, 100)] [int]$StableOkProbes = 5,
  [ValidateRange(30, 7200)] [int]$LossTimeoutSeconds = 900,
  [ValidateRange(30, 7200)] [int]$ConvergenceTimeoutSeconds = 1200,
  [ValidateRange(60, 3600)] [int]$SessionWaitSeconds = 600,
  [switch]$RestoreOnly
)

# ============================================================================
# exp3-dynamic.ps1 - experiment 3 (N-Dynamic): withdraw the BGP sessions and
#                    the Router Appliance registration, restore them and measure
#                    the convergence time.
#
# The inverse of the T4 task (native-routing-t4.ps1, Invoke-DynamicRoutingT4).
# For the benchmark and worker-0 nodes only it
#   1) removes their 2 Cloud Router BGP peers each (4 in total) and
#   2) drops both VMs from the NCC Router Appliance spoke registration
#      (a spoke update replaces the whole list, so it is replaced with the list
#      of the remaining nodes; their registration and BGP sessions stay up).
# The Cilium BGP CRDs are never touched. Cilium keeps reconnecting with a 5s
# connectRetry, so after the restore (T0) the whole chain - session Established
# again, Cloud Router relearning the PodCIDR, VPC programming - is inside T2-T0.
#
# Restore (measured window): full spoke list, then add-bgp-peer x4. T1 is the
# end of the last gcloud command; BGP reconvergence happens between T1 and T2.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "exp3-common.ps1")

$scriptsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($TfDir)) { $TfDir = Join-Path (Split-Path -Parent $PSScriptRoot) "infra\dynamic" }
$ctx = Initialize-Exp3Context -Method "dynamic" -ScriptsRoot $scriptsRoot -TfDir $TfDir -VarFile $VarFile `
  -OutDir $OutDir -Namespace $Namespace -ProbePort $ProbePort `
  -ProbeIntervalSeconds $ProbeIntervalSeconds -ProbeTimeoutSeconds $ProbeTimeoutSeconds `
  -RestoreOnly ([bool]$RestoreOnly)

# Same fixed constants and naming rules as T4.
$script:Exp3DynRouterAsn = 64514
$script:Exp3DynNodeAsn = 64512
$script:Exp3DynSessionWaitSeconds = $SessionWaitSeconds

function Get-Exp3DynRouterName { param([object]$Ctx) return "$($Ctx.ResourcePrefix)-router" }
function Get-Exp3DynSpokeName { param([object]$Ctx) return "$($Ctx.ResourcePrefix)-spoke" }
function Get-Exp3DynInterfaceNames { param([object]$Ctx) return @("$($Ctx.ResourcePrefix)-if-0", "$($Ctx.ResourcePrefix)-if-1") }
function Get-Exp3DynPeerName { param([object]$Node, [int]$Index) return "peer-$($Node.node_name)-$Index" }

function Get-Exp3DynRouter {
  param([object]$Ctx)
  return Get-Exp3GcloudJson -Arguments @(
    "compute", "routers", "describe", (Get-Exp3DynRouterName -Ctx $Ctx),
    "--region", $Ctx.Region, "--project", $Ctx.ProjectId
  )
}

function Get-Exp3DynApplianceArguments {
  # --router-appliance arguments of a spoke update (same URI format as T4).
  param([object]$Ctx, [object[]]$Nodes)
  $arguments = @()
  foreach ($node in $Nodes) {
    $instanceUri = "https://www.googleapis.com/compute/v1/projects/$($Ctx.ProjectId)/zones/$($node.zone)/instances/$($node.node_name)"
    $arguments += "--router-appliance=instance=$instanceUri,ip=$($node.private_ip)"
  }
  return $arguments
}

function Assert-Exp3DynPeers {
  param([object]$Ctx, [object[]]$Nodes, [string]$Because)
  $router = Get-Exp3DynRouter -Ctx $Ctx
  if ([int]$router.bgp.asn -ne $script:Exp3DynRouterAsn) {
    throw "Cloud Router ASN is $($router.bgp.asn) (expected $($script:Exp3DynRouterAsn))."
  }
  $interfaceNames = Get-Exp3DynInterfaceNames -Ctx $Ctx
  $peers = @(Get-Exp3PropertyArray -Object $router -Name "bgpPeers")
  foreach ($node in $Nodes) {
    for ($index = 0; $index -lt 2; $index++) {
      $peerName = Get-Exp3DynPeerName -Node $node -Index $index
      $found = @($peers | Where-Object { $_.name -eq $peerName })
      if ($found.Count -ne 1) {
        throw "BGP peer '$peerName' does not exist ($Because). Restore it with -RestoreOnly."
      }
      if ([string]$found[0].interfaceName -ne $interfaceNames[$index] -or
          [string]$found[0].peerIpAddress -ne [string]$node.private_ip -or
          [int]$found[0].peerAsn -ne $script:Exp3DynNodeAsn) {
        throw "BGP peer '$peerName' does not match the interface/peer IP/ASN contract ($Because)."
      }
    }
  }
}

function Assert-Exp3DynSpokeMembers {
  param([object]$Ctx, [object[]]$RequiredNodes, [int]$ExpectedCount, [string]$Because)
  $spoke = Get-Exp3GcloudJson -Arguments @(
    "network-connectivity", "spokes", "describe", (Get-Exp3DynSpokeName -Ctx $Ctx),
    "--region", $Ctx.Region, "--project", $Ctx.ProjectId
  )
  $linkedProperty = $spoke.PSObject.Properties["linkedRouterApplianceInstances"]
  $instances = if ($null -eq $linkedProperty -or $null -eq $linkedProperty.Value) {
    @()
  }
  else {
    @(Get-Exp3PropertyArray -Object $linkedProperty.Value -Name "instances")
  }
  if ($instances.Count -ne $ExpectedCount) {
    throw "The NCC spoke has $($instances.Count) appliances (expected $ExpectedCount, $Because)."
  }
  foreach ($node in $RequiredNodes) {
    $found = @($instances | Where-Object {
      [string]$_.virtualMachine -like "*/zones/$($node.zone)/instances/$($node.node_name)" -and
      [string]$_.ipAddress -eq [string]$node.private_ip
    })
    if ($found.Count -ne 1) {
      throw "Appliance '$($node.node_name)' is not registered on the NCC spoke ($Because)."
    }
  }
}

function Wait-Exp3DynSessions {
  # Waits until Cloud Router get-status reports every BGP session of the given
  # nodes (2 per node) Established with at least one learned route - the same
  # verdict T4 uses.
  param([object]$Ctx, [object[]]$Nodes, [int]$TimeoutSeconds)

  $expectedPeerNames = @()
  foreach ($node in $Nodes) {
    $expectedPeerNames += Get-Exp3DynPeerName -Node $node -Index 0
    $expectedPeerNames += Get-Exp3DynPeerName -Node $node -Index 1
  }
  $expectedSessions = $expectedPeerNames.Count

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $peerStatuses = @()
  $learned = @()
  do {
    $status = Get-Exp3GcloudJson -Arguments @(
      "compute", "routers", "get-status", (Get-Exp3DynRouterName -Ctx $Ctx),
      "--region", $Ctx.Region, "--project", $Ctx.ProjectId
    )
    $resultProperty = $status.PSObject.Properties["result"]
    $allPeerStatuses = if ($null -eq $resultProperty) {
      @()
    }
    else {
      @(Get-Exp3PropertyArray -Object $resultProperty.Value -Name "bgpPeerStatus")
    }
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
      return
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "The Cloud Router did not complete $expectedSessions BGP sessions (Established + at least one learned route) within ${TimeoutSeconds}s (currently $($learned.Count)/$($peerStatuses.Count))."
}

$assertAdvertised = {
  param($Ctx)
  Assert-Exp3DynPeers -Ctx $Ctx -Nodes $Ctx.MarkerNodes -Because "before the experiment"
  Assert-Exp3DynSpokeMembers -Ctx $Ctx -RequiredNodes $Ctx.MarkerNodes -ExpectedCount $Ctx.MarkerNodes.Count -Because "before the experiment"
  Write-Host "    BGP peers and appliances registered. Waiting for every session to reach Established..."
  Wait-Exp3DynSessions -Ctx $Ctx -Nodes $Ctx.MarkerNodes -TimeoutSeconds $script:Exp3DynSessionWaitSeconds
  Write-Host "    all $($Ctx.MarkerNodes.Count * 2) BGP sessions are Established and have learned the PodCIDRs."
}

$withdraw = {
  param($Ctx)
  # Two sequential CP timed-task stages: peers are removed first, then the
  # appliances leave the spoke, so no appliance reference is left behind (the
  # reverse of the T4 creation order). All 4 peers go in one --peer-names call.
  $peerNames = @()
  foreach ($node in $Ctx.TargetNodes) {
    $peerNames += Get-Exp3DynPeerName -Node $node -Index 0
    $peerNames += Get-Exp3DynPeerName -Node $node -Index 1
  }
  Write-Host "    remove-bgp-peer: $($peerNames -join ', ')"
  Write-Host "    replacing the spoke appliance list (kept: $($Ctx.OtherNodes.node_name -join ', '))"
  $stages = @()
  $stages += , @(@{
    name      = "withdraw-bgp-peers"
    arguments = @(
      "compute", "routers", "remove-bgp-peer", (Get-Exp3DynRouterName -Ctx $Ctx),
      "--project", $Ctx.ProjectId,
      "--region", $Ctx.Region,
      "--peer-names", ($peerNames -join ","),
      "--quiet"
    )
  })
  $stages += , @(@{
    name      = "withdraw-spoke-appliances"
    arguments = (
      @(
        "network-connectivity", "spokes", "linked-router-appliances", "update", (Get-Exp3DynSpokeName -Ctx $Ctx),
        "--project", $Ctx.ProjectId,
        "--region", $Ctx.Region
      ) + (Get-Exp3DynApplianceArguments -Ctx $Ctx -Nodes $Ctx.OtherNodes) + @("--quiet")
    )
  })
  return (Invoke-Exp3TimedControlPlaneGcloud -Ctx $Ctx -Name "withdraw" -Stages $stages)
}

$readvertise = {
  param($Ctx)
  # Hybrid measurement: runs as a control plane timed task with T0/T1 on the CP
  # VM clock. N-Dynamic cannot be parallelized and uses sequential stages:
  #   1) add-bgp-peer only succeeds after the appliance is registered on the
  #      spoke (API dependency).
  #   2) Adding a Cloud Router peer is a read-modify-write of the whole router,
  #      so concurrent calls can lose peers - each of the 4 peers gets its own
  #      stage.
  # That serialization is inherent to applying N-Dynamic and is measured as is.
  $stages = @()

  # stage 1) restore the spoke appliance list to every node (T4 creation order).
  $stages += , @(@{
    name      = "readvertise-spoke-appliances"
    arguments = (
      @(
        "network-connectivity", "spokes", "linked-router-appliances", "update", (Get-Exp3DynSpokeName -Ctx $Ctx),
        "--project", $Ctx.ProjectId,
        "--region", $Ctx.Region
      ) + (Get-Exp3DynApplianceArguments -Ctx $Ctx -Nodes $Ctx.MarkerNodes) + @("--quiet")
    )
  })

  # stage 2..5) re-create the 4 BGP peers of both nodes (same arguments as T4,
  # sequential). The connectivity prerequisite is complete with the spoke plus
  # the first peer (index 0) of each node. The second peer (index 1) serves the
  # redundant interface, is marked essential=false and stays out of the T0
  # anchor, so in practice T0 = the moment the first worker-0 peer (the 4th
  # command) is fired.
  $interfaceNames = Get-Exp3DynInterfaceNames -Ctx $Ctx
  foreach ($node in $Ctx.TargetNodes) {
    for ($index = 0; $index -lt 2; $index++) {
      $peerName = Get-Exp3DynPeerName -Node $node -Index $index
      $stages += , @(@{
        name      = "readvertise-$peerName"
        essential = ($index -eq 0)
        arguments = @(
          "compute", "routers", "add-bgp-peer", (Get-Exp3DynRouterName -Ctx $Ctx),
          "--project", $Ctx.ProjectId,
          "--region", $Ctx.Region,
          "--peer-name", $peerName,
          "--interface", $interfaceNames[$index],
          "--peer-ip-address", [string]$node.private_ip,
          "--peer-asn", [string]$script:Exp3DynNodeAsn,
          "--instance", [string]$node.node_name,
          "--instance-zone", [string]$node.zone,
          "--quiet"
        )
      })
    }
  }
  return (Invoke-Exp3TimedControlPlaneGcloud -Ctx $Ctx -Name "readvertise" -Stages $stages)
}

$ensureAdvertised = {
  param($Ctx)
  # Idempotent restore: the spoke list is replaced with the full list (harmless
  # if already correct) and only missing peers are re-created.
  $null = Invoke-Exp3Gcloud -Ctx $Ctx -Name "restore-spoke-appliances" -Arguments (
    @(
      "network-connectivity", "spokes", "linked-router-appliances", "update", (Get-Exp3DynSpokeName -Ctx $Ctx),
      "--project", $Ctx.ProjectId,
      "--region", $Ctx.Region
    ) + (Get-Exp3DynApplianceArguments -Ctx $Ctx -Nodes $Ctx.MarkerNodes) + @("--quiet")
  )

  $router = Get-Exp3DynRouter -Ctx $Ctx
  $existingPeerNames = @(Get-Exp3PropertyArray -Object $router -Name "bgpPeers" | ForEach-Object { [string]$_.name })
  $interfaceNames = Get-Exp3DynInterfaceNames -Ctx $Ctx
  foreach ($node in $Ctx.TargetNodes) {
    for ($index = 0; $index -lt 2; $index++) {
      $peerName = Get-Exp3DynPeerName -Node $node -Index $index
      if ($existingPeerNames -contains $peerName) {
        continue
      }
      $null = Invoke-Exp3Gcloud -Ctx $Ctx -Name "restore-$peerName" -Arguments @(
        "compute", "routers", "add-bgp-peer", (Get-Exp3DynRouterName -Ctx $Ctx),
        "--project", $Ctx.ProjectId,
        "--region", $Ctx.Region,
        "--peer-name", $peerName,
        "--interface", $interfaceNames[$index],
        "--peer-ip-address", [string]$node.private_ip,
        "--peer-asn", [string]$script:Exp3DynNodeAsn,
        "--instance", [string]$node.node_name,
        "--instance-zone", [string]$node.zone,
        "--quiet"
      )
    }
  }
}

$verifyRestored = {
  param($Ctx)
  # A spoke update replaces the list, so everything - including the other nodes
  # - is re-verified, and every session must be Established again so the next
  # repetition starts from the same conditions.
  Assert-Exp3DynPeers -Ctx $Ctx -Nodes $Ctx.MarkerNodes -Because "restore check after re-advertisement"
  Assert-Exp3DynSpokeMembers -Ctx $Ctx -RequiredNodes $Ctx.MarkerNodes -ExpectedCount $Ctx.MarkerNodes.Count -Because "restore check after re-advertisement"
  Wait-Exp3DynSessions -Ctx $Ctx -Nodes $Ctx.MarkerNodes -TimeoutSeconds $script:Exp3DynSessionWaitSeconds
  Write-Host "    BGP peer/appliance/session restore verified."
}

Invoke-Exp3Experiment -Ctx $ctx `
  -AssertAdvertised $assertAdvertised `
  -Withdraw $withdraw `
  -Readvertise $readvertise `
  -EnsureAdvertised $ensureAdvertised `
  -VerifyRestored $verifyRestored `
  -Repetitions $Repetitions `
  -LossConfirmProbes $LossConfirmProbes `
  -LossConfirmSeconds $LossConfirmSeconds `
  -StableOkProbes $StableOkProbes `
  -LossTimeoutSeconds $LossTimeoutSeconds `
  -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
  -RestoreOnly:$RestoreOnly
