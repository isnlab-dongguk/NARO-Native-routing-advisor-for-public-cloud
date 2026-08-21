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
  [ValidateRange(30, 7200)] [int]$LossTimeoutSeconds = 300,
  [ValidateRange(30, 7200)] [int]$ConvergenceTimeoutSeconds = 300,
  [switch]$RestoreOnly
)

# ============================================================================
# exp3-static.ps1 - experiment 3 (N-Static): withdraw the static VPC routes,
#                   re-create them and measure the convergence time.
#
# The inverse of the T4 task (native-routing-t4.ps1, Invoke-StaticRoutingT4):
# only the two PodCIDR static routes of the benchmark and worker-0 nodes are
# deleted. The control plane and the remaining workers are untouched.
#
# Measurement: TCP probes run continuously between the Benchmark and Server pods
# created by the experiment 2 create profile. Once packet loss is confirmed, T0
# re-creates both routes with `gcloud compute routes create` (T1 = finished) and
# T2-T0 is recorded up to the first successful probe (T2).
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "exp3-common.ps1")

$scriptsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($TfDir)) { $TfDir = Join-Path (Split-Path -Parent $PSScriptRoot) "infra\static" }
$ctx = Initialize-Exp3Context -Method "static" -ScriptsRoot $scriptsRoot -TfDir $TfDir -VarFile $VarFile `
  -OutDir $OutDir -Namespace $Namespace -ProbePort $ProbePort `
  -ProbeIntervalSeconds $ProbeIntervalSeconds -ProbeTimeoutSeconds $ProbeTimeoutSeconds `
  -RestoreOnly ([bool]$RestoreOnly)

function Get-Exp3StaticRouteName {
  # Same naming rule as T4: <prefix>-pod-<role>-<role_index>
  param([object]$Ctx, [object]$Node)
  return "{0}-pod-{1}-{2}" -f $Ctx.ResourcePrefix, $Node.role, $Node.role_index
}

function Get-Exp3StaticRouteMap {
  param([object]$Ctx)
  return Get-Exp3ResourceMapByName -Arguments @(
    "compute", "routes", "list",
    "--project", $Ctx.ProjectId,
    "--filter", "name~^$($Ctx.ResourcePrefix)-pod-"
  )
}

function Assert-Exp3StaticAdvertised {
  param([object]$Ctx, [object[]]$Nodes, [string]$Because)
  $routeMap = Get-Exp3StaticRouteMap -Ctx $Ctx
  foreach ($node in $Nodes) {
    $routeName = Get-Exp3StaticRouteName -Ctx $Ctx -Node $node
    if (-not $routeMap.ContainsKey($routeName)) {
      throw "Static route '$routeName' does not exist ($Because). Restore it with -RestoreOnly or check the T4 state."
    }
    $route = $routeMap[$routeName]
    if ([string]$route.destRange -ne [string]$node.pod_cidr -or
        [string]$route.nextHopIp -ne [string]$node.private_ip) {
      throw "Static route '$routeName' does not match the mapping $($node.pod_cidr) -> $($node.private_ip) ($Because)."
    }
  }
}

$assertAdvertised = {
  param($Ctx)
  Assert-Exp3StaticAdvertised -Ctx $Ctx -Nodes $Ctx.MarkerNodes -Because "advertisement state of every node before the experiment"
  Write-Host "    all $($Ctx.MarkerNodes.Count) static routes are advertised."
}

$withdraw = {
  param($Ctx)
  # Deletes the routes of the two target nodes only, in one gcloud call. It runs
  # as a CP timed task so the teardown boundaries are on the VM clock too.
  $routeNames = @($Ctx.TargetNodes | ForEach-Object { Get-Exp3StaticRouteName -Ctx $Ctx -Node $_ })
  Write-Host "    routes delete: $($routeNames -join ', ')"
  $stages = @()
  $stages += , @(@{
    name      = "withdraw-static-routes"
    arguments = (@("compute", "routes", "delete") + $routeNames + @("--project", $Ctx.ProjectId, "--quiet"))
  })
  return (Invoke-Exp3TimedControlPlaneGcloud -Ctx $Ctx -Name "withdraw" -Stages $stages)
}

$readvertise = {
  param($Ctx)
  # Re-created with the same arguments as T4. The two static routes are
  # independent resources, so they are created concurrently in one stage (the
  # highest concurrency the method allows). T0/T1 come from the CP VM clock
  # (Invoke-Exp3TimedControlPlaneGcloud).
  $commands = @()
  foreach ($node in $Ctx.TargetNodes) {
    $routeName = Get-Exp3StaticRouteName -Ctx $Ctx -Node $node
    $commands += @{
      name      = "readvertise-$routeName"
      arguments = @(
        "compute", "routes", "create", $routeName,
        "--project", $Ctx.ProjectId,
        "--network", $Ctx.NetworkName,
        "--destination-range", [string]$node.pod_cidr,
        "--next-hop-address", [string]$node.private_ip,
        "--priority", "900",
        "--description", "Cilium PodCIDR for $($node.node_name)",
        "--quiet"
      )
    }
  }
  $stages = @()
  $stages += , $commands
  return (Invoke-Exp3TimedControlPlaneGcloud -Ctx $Ctx -Name "readvertise" -Stages $stages)
}

$ensureAdvertised = {
  param($Ctx)
  # Idempotent restore: re-creates only the missing routes (used after a failed
  # or interrupted measurement).
  $routeMap = Get-Exp3StaticRouteMap -Ctx $Ctx
  foreach ($node in $Ctx.TargetNodes) {
    $routeName = Get-Exp3StaticRouteName -Ctx $Ctx -Node $node
    if ($routeMap.ContainsKey($routeName)) {
      $route = $routeMap[$routeName]
      if ([string]$route.destRange -ne [string]$node.pod_cidr -or
          [string]$route.nextHopIp -ne [string]$node.private_ip) {
        throw "Existing static route '$routeName' does not match the expected mapping; aborting the restore."
      }
      continue
    }
    $null = Invoke-Exp3Gcloud -Ctx $Ctx -Name "restore-$routeName" -Arguments @(
      "compute", "routes", "create", $routeName,
      "--project", $Ctx.ProjectId,
      "--network", $Ctx.NetworkName,
      "--destination-range", [string]$node.pod_cidr,
      "--next-hop-address", [string]$node.private_ip,
      "--priority", "900",
      "--description", "Cilium PodCIDR for $($node.node_name)",
      "--quiet"
    )
  }
}

$verifyRestored = {
  param($Ctx)
  # Re-verifies everything: the two targets are restored and the other node
  # routes are unchanged.
  Assert-Exp3StaticAdvertised -Ctx $Ctx -Nodes $Ctx.MarkerNodes -Because "restore check after re-advertisement"
  Write-Host "    static route restore verified."
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
