[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PlanJson,

  # Total nodes = control plane 1 + benchmark 1 + worker_count.
  # 4-node plan = 4; 8-node expansion plan = 8 (4 existing no-op + 4 new).
  [int]$ExpectedNodeCount = 4,

  # -1 skips the creation check. The provisioning engine passes the number of
  # VMs this apply must really create (initial build = 4, 4->8 expansion = 4).
  [ValidateRange(-1, 9999)]
  [int]$ExpectedInstanceCreates = -1,

  # Extra resource types a method-specific module is allowed to change:
  # N-Static needs "google_compute_route"; N-Dynamic needs
  # "google_compute_router", "google_compute_router_peer",
  # "google_network_connectivity_hub", "google_network_connectivity_spoke".
  # VXLAN/Host leave it empty.
  [string[]]$AllowExtraTypes = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlanJson)) {
  throw "Plan JSON not found: $PlanJson"
}

$plan = Get-Content -LiteralPath $PlanJson -Raw | ConvertFrom-Json
$changes = @($plan.resource_changes)

$writeActions = @("create", "update", "delete", "replace")
$activeChanges = @(
  $changes | Where-Object {
    $actions = @($_.change.actions)
    @($actions | Where-Object { $writeActions -contains $_ }).Count -gt 0
  }
)

# Firewall rules are created by the experiment module itself, so they are not on
# the denylist; their name/direction/target tag are validated below instead.
$blockedTypes = @(
  "google_compute_network",
  "google_compute_subnetwork",
  "google_compute_route",
  "google_compute_router",
  "google_compute_router_peer",
  "google_network_connectivity_hub",
  "google_network_connectivity_spoke"
)
$blockedTypes = @($blockedTypes | Where-Object { $AllowExtraTypes -notcontains $_ })

$blocked = @(
  $activeChanges | Where-Object {
    ($blockedTypes -contains $_.type) -or
    ($_.type -like "google_network_connectivity_*" -and $AllowExtraTypes -notcontains $_.type)
  }
)

if ($blocked.Count -gt 0) {
  $blockedList = ($blocked | ForEach-Object { "$($_.type).$($_.name)" }) -join ", "
  throw "Blocked VPC/routing/NCC resource change detected: $blockedList"
}

$allowedTypes = @(
  "google_compute_instance",
  "google_compute_resource_policy",
  "google_compute_firewall"
) + $AllowExtraTypes

$unexpected = @(
  $activeChanges | Where-Object { $allowedTypes -notcontains $_.type }
)

if ($unexpected.Count -gt 0) {
  $unexpectedList = ($unexpected | ForEach-Object { "$($_.type).$($_.name)" }) -join ", "
  throw "Unexpected resource change detected. The plan may only mutate experiment VMs, the compact resource policy, and the experiment firewall rules: $unexpectedList"
}

$instances = @($changes | Where-Object { $_.type -eq "google_compute_instance" })
if ($instances.Count -ne $ExpectedNodeCount) {
  throw "Expected exactly $ExpectedNodeCount google_compute_instance resources in plan, found $($instances.Count)."
}
$instanceCreates = @(
  $instances | Where-Object {
    $instanceActions = @($_.change.actions)
    $instanceActions -contains "create" -and $instanceActions -notcontains "delete"
  }
)
if ($ExpectedInstanceCreates -ge 0 -and $instanceCreates.Count -ne $ExpectedInstanceCreates) {
  throw "Expected exactly $ExpectedInstanceCreates new google_compute_instance creations, found $($instanceCreates.Count). Refusing a no-op or incorrectly based provisioning measurement."
}
if ($ExpectedInstanceCreates -ge 0) {
  $unexpectedExistingChanges = @(
    $instances | Where-Object {
      $instanceActions = @($_.change.actions)
      $instanceActions -notcontains "create" -and
        -not ($instanceActions.Count -eq 1 -and $instanceActions[0] -eq "no-op")
    }
  )
  if ($unexpectedExistingChanges.Count -gt 0) {
    $changedList = ($unexpectedExistingChanges | ForEach-Object { $_.address }) -join ", "
    throw "Existing experiment instances must remain no-op during a measured expansion; unexpected changes: $changedList"
  }
}

foreach ($instance in $instances) {
  # A provisioning plan may only create or update nodes. A delete means a
  # scale-down (for example worker_count=2 against an 8-node state) or a
  # replacement, so it is blocked to protect the existing cluster. Full teardown
  # goes through destroy.ps1.
  $instanceActions = @($instance.change.actions)
  if ($instanceActions -contains "delete") {
    throw "Instance $($instance.address) is planned for delete/replace. Provisioning may only create or update nodes; tear down with .\destroy.ps1 instead."
  }

  $after = $instance.change.after
  if ($null -eq $after) {
    throw "Instance $($instance.address) has no planned after-state."
  }

  if ($after.can_ip_forward -ne $true) {
    throw "Instance $($instance.address) must set can_ip_forward = true."
  }

  # Every VM must carry the '<prefix>-node' target tag the module firewall uses.
  $tags = @($after.tags)
  if (@($tags | Where-Object { $_ -match "-node$" }).Count -eq 0) {
    throw "Instance $($instance.address) must include the experiment '-node' network tag used by the module firewall rules."
  }

  # Network control variable: regardless of the project default tier, each VM's
  # external IPv4 access config must be Premium Tier, blocked already at plan.
  $networkInterfaces = @($after.network_interface)
  if ($networkInterfaces.Count -ne 1) {
    throw "Instance $($instance.address) must have exactly one network interface."
  }
  $accessConfigs = @($networkInterfaces[0].access_config)
  if ($accessConfigs.Count -ne 1) {
    throw "Instance $($instance.address) must have exactly one external IPv4 access config for SSH."
  }
  if ([string]$accessConfigs[0].network_tier -ne "PREMIUM") {
    throw "Instance $($instance.address) must use network_tier = PREMIUM, found '$($accessConfigs[0].network_tier)'."
  }

  if ([string]$after.metadata."enable-oslogin" -ne "FALSE") {
    throw "Instance $($instance.address) must set metadata enable-oslogin=FALSE so the explicit experiment SSH key is honored."
  }
}

$policies = @($changes | Where-Object { $_.type -eq "google_compute_resource_policy" })
if ($policies.Count -ne 1) {
  throw "Expected exactly 1 google_compute_resource_policy in plan, found $($policies.Count)."
}

$policyAfter = $policies[0].change.after
$placement = @($policyAfter.group_placement_policy)[0]
if ($null -eq $placement) {
  throw "Compact placement resource policy is missing group_placement_policy."
}
if ($placement.collocation -ne "COLLOCATED") {
  throw "Compact placement policy must set collocation = COLLOCATED."
}
if ([int]$placement.max_distance -ne 1) {
  throw "Compact placement policy must set max_distance = 1 for same-rack placement."
}
# vm_count is not checked: pinning it would force a policy replacement during a
# 4->8 expansion and break node retention, so the module omits it on purpose.

$firewalls = @($changes | Where-Object { $_.type -eq "google_compute_firewall" })
if ($firewalls.Count -ne 2) {
  throw "Expected exactly 2 google_compute_firewall resources (allow-ssh, allow-internal), found $($firewalls.Count)."
}

foreach ($firewall in $firewalls) {
  $after = $firewall.change.after
  if ($null -eq $after) {
    throw "Firewall $($firewall.address) has no planned after-state."
  }
  if ($after.name -notmatch "-allow-(ssh|internal)$") {
    throw "Firewall $($firewall.address) has unexpected name '$($after.name)'. Only '<prefix>-allow-ssh' and '<prefix>-allow-internal' are allowed."
  }
  if ($after.direction -ne "INGRESS") {
    throw "Firewall $($firewall.address) must be INGRESS."
  }
  $targetTags = @($after.target_tags)
  if (@($targetTags | Where-Object { $_ -match "-node$" }).Count -eq 0) {
    throw "Firewall $($firewall.address) must target the experiment '-node' tag."
  }
}

Write-Host "Terraform plan guard passed: only experiment VM/placement/firewall resources will be changed ($ExpectedNodeCount instances expected)."
