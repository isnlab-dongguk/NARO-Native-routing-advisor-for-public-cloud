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
  [ValidateRange(30, 7200)] [int]$LossTimeoutSeconds = 600,
  [ValidateRange(30, 7200)] [int]$ConvergenceTimeoutSeconds = 900,
  [switch]$RestoreOnly
)

# ============================================================================
# exp3-cloud-gke.ps1 - experiment 3 (N-Cloud on GKE): withdraw the Alias IPs,
#                      restore them and measure the convergence time.
#
# Removes only the Alias IP range registered on nic0 of the benchmark and
# worker-0 node VMs. The subnet secondary range and the Alias IPs of every other
# node are untouched.
#
# GKE assigns the Alias IP when the node is created and its guest agent does not
# fight the CNI for the PodCIDR route, so withdrawing and restoring the Alias IP
# only changes the VPC dataplane route.
#
# Measurement: T0 re-registers both Alias IPs with
# `gcloud compute instances network-interfaces update --aliases` (T1 =
# finished), and T2-T0 is recorded up to the first successful TCP probe (T2).
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "exp3-context-gke.ps1")

$scriptsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($TfDir)) { $TfDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "infra\gke" }
$ctx = Initialize-Exp3ContextGke -ScriptsRoot $scriptsRoot -TfDir $TfDir -VarFile $VarFile `
  -OutDir $OutDir -Namespace $Namespace -ProbePort $ProbePort `
  -ProbeIntervalSeconds $ProbeIntervalSeconds -ProbeTimeoutSeconds $ProbeTimeoutSeconds `
  -RestoreOnly ([bool]$RestoreOnly)

# GKE generates the secondary range as 'gke-<cluster>-pods-<hash>', so the
# kubeadm '<prefix>-pods' assumption cannot be used: the real name resolved by
# Pod CIDR during context construction is used instead.
function Get-Exp3CloudRangeName { param([object]$Ctx) return [string]$Ctx.GkeSecondaryRangeName }

function Get-Exp3CloudAliasRanges {
  # Returns the aliasIpRanges array of nic0 on the given VM.
  param([object]$Ctx, [object]$Node)
  $instance = Get-Exp3GcloudJson -Arguments @(
    "compute", "instances", "describe", [string]$Node.node_name,
    "--zone", [string]$Node.zone,
    "--project", $Ctx.ProjectId
  )
  $networkInterfaces = @(Get-Exp3PropertyArray -Object $instance -Name "networkInterfaces")
  if ($networkInterfaces.Count -lt 1) {
    throw "Instance '$($Node.node_name)' has no nic0."
  }
  return @(Get-Exp3PropertyArray -Object $networkInterfaces[0] -Name "aliasIpRanges")
}

function Assert-Exp3CloudNodeAdvertised {
  param([object]$Ctx, [object]$Node, [string]$Because)
  $rangeName = Get-Exp3CloudRangeName -Ctx $Ctx
  $aliases = @(Get-Exp3CloudAliasRanges -Ctx $Ctx -Node $Node)
  if ($aliases.Count -ne 1 -or
      [string]$aliases[0].subnetworkRangeName -ne $rangeName -or
      [string]$aliases[0].ipCidrRange -ne [string]$Node.pod_cidr) {
    throw "Instance '$($Node.node_name)' does not carry exactly one Alias IP $rangeName=$($Node.pod_cidr) ($Because)."
  }
}

function Assert-Exp3CloudOwnedAliasesOnly {
  # If an alias not owned by the experiment exists, nothing is withdrawn or restored.
  param([object]$Ctx, [object]$Node, [object[]]$Aliases)
  $rangeName = Get-Exp3CloudRangeName -Ctx $Ctx
  $foreign = @($Aliases | Where-Object { [string]$_.subnetworkRangeName -ne $rangeName })
  if ($foreign.Count -gt 0) {
    throw "Instance '$($Node.node_name)' has an alias range not owned by this experiment; aborting."
  }
}

$assertAdvertised = {
  param($Ctx)
  # The subnet secondary range is shared cluster state: only checked, never touched.
  $rangeName = Get-Exp3CloudRangeName -Ctx $Ctx
  $subnet = Get-Exp3GcloudJson -Arguments @(
    "compute", "networks", "subnets", "describe", $Ctx.SubnetworkName,
    "--region", $Ctx.Region, "--project", $Ctx.ProjectId
  )
  $ranges = @(Get-Exp3PropertyArray -Object $subnet -Name "secondaryIpRanges")
  $matching = @($ranges | Where-Object { $_.rangeName -eq $rangeName })
  if ($matching.Count -ne 1 -or [string]$matching[0].ipCidrRange -ne $Ctx.ClusterPodCidr) {
    throw "Subnet secondary range '$rangeName' does not exist as $($Ctx.ClusterPodCidr)."
  }
  foreach ($node in $Ctx.MarkerNodes) {
    Assert-Exp3CloudNodeAdvertised -Ctx $Ctx -Node $node -Because "advertisement state of every node before the experiment"
  }
  Write-Host "    the secondary range and the Alias IPs of all $($Ctx.MarkerNodes.Count) nodes are correct."
}

$withdraw = {
  param($Ctx)
  # Removes the Alias IP of the two VMs only (--aliases= empties it). They are
  # different VMs and therefore independent resources, so both run in one stage.
  # It runs as an ops VM timed task so the teardown boundaries are on the VM
  # clock too. The ownership check (describe) happens locally beforehand.
  $commands = @()
  foreach ($node in $Ctx.TargetNodes) {
    $aliases = @(Get-Exp3CloudAliasRanges -Ctx $Ctx -Node $node)
    Assert-Exp3CloudOwnedAliasesOnly -Ctx $Ctx -Node $node -Aliases $aliases
    if ($aliases.Count -eq 0) {
      throw "Instance '$($node.node_name)' has no Alias IP to remove (already withdrawn)."
    }
    Write-Host "    removing alias: $($node.node_name) ($($node.pod_cidr))"
    $commands += @{
      name      = "withdraw-alias-$($node.node_name)"
      arguments = @(
        "compute", "instances", "network-interfaces", "update", [string]$node.node_name,
        "--project", $Ctx.ProjectId,
        "--zone", [string]$node.zone,
        "--network-interface", "nic0",
        "--aliases=",
        "--quiet"
      )
    }
  }
  $stages = @()
  $stages += , $commands
  return (Invoke-Exp3TimedControlPlaneGcloud -Ctx $Ctx -Name "withdraw" -Stages $stages)
}

$readvertise = {
  param($Ctx)
  # Re-registers the Alias IPs with the same arguments. The two VMs are
  # independent resources, so both run concurrently in one stage (the highest
  # concurrency the method allows). T0/T1 come from the ops VM clock.
  $rangeName = Get-Exp3CloudRangeName -Ctx $Ctx
  $commands = @()
  foreach ($node in $Ctx.TargetNodes) {
    $commands += @{
      name      = "readvertise-alias-$($node.node_name)"
      arguments = @(
        "compute", "instances", "network-interfaces", "update", [string]$node.node_name,
        "--project", $Ctx.ProjectId,
        "--zone", [string]$node.zone,
        "--network-interface", "nic0",
        "--aliases", ("{0}:{1}" -f $rangeName, [string]$node.pod_cidr),
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
  # Idempotent restore: re-registers only on a VM whose alias is empty.
  $rangeName = Get-Exp3CloudRangeName -Ctx $Ctx
  foreach ($node in $Ctx.TargetNodes) {
    $aliases = @(Get-Exp3CloudAliasRanges -Ctx $Ctx -Node $node)
    Assert-Exp3CloudOwnedAliasesOnly -Ctx $Ctx -Node $node -Aliases $aliases
    $alreadyDesired = ($aliases.Count -eq 1 -and
      [string]$aliases[0].subnetworkRangeName -eq $rangeName -and
      [string]$aliases[0].ipCidrRange -eq [string]$node.pod_cidr)
    if ($alreadyDesired) {
      continue
    }
    if ($aliases.Count -gt 0) {
      throw "The existing alias of instance '$($node.node_name)' differs from the expected value; aborting the restore."
    }
    $null = Invoke-Exp3Gcloud -Ctx $Ctx -Name "restore-alias-$($node.node_name)" -Arguments @(
      "compute", "instances", "network-interfaces", "update", [string]$node.node_name,
      "--project", $Ctx.ProjectId,
      "--zone", [string]$node.zone,
      "--network-interface", "nic0",
      "--aliases", ("{0}:{1}" -f $rangeName, [string]$node.pod_cidr),
      "--quiet"
    )
  }
}

$verifyRestored = {
  param($Ctx)
  # Re-verifies both targets are restored and the other node aliases are unchanged.
  foreach ($node in $Ctx.MarkerNodes) {
    Assert-Exp3CloudNodeAdvertised -Ctx $Ctx -Node $node -Because "restore check after re-advertisement"
  }
  Write-Host "    Alias IP restore verified."
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
