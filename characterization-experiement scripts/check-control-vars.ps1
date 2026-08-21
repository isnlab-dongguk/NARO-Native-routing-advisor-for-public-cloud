[CmdletBinding()]
param(
  [string]$InventoryPath,
  [string]$TfDir,
  [string]$OutDir = "",
  [string]$SshUser,

  # Private key for OpenSSH (ssh.exe). Empty uses the default identity.
  [string]$SshKeyFile,

  # Firewall target tag the Terraform module applies to every experiment VM
  # (for example vxlan-node). Empty skips the tag check.
  [string]$RequiredTag,

  # Used in the result filename: control-vars-<experiment>_<nodes>[_iter<n>].csv
  [string]$ExperimentName = "vxlan",

  # Provisioning iteration number. Greater than 0 appends "_iterN" to the result
  # filename so it maps 1:1 to the timeline CSV and iterations never overwrite
  # each other. 0 keeps the fixed name (for standalone runs).
  [int]$Iteration = 0,

  # Control-variable baselines.
  [string]$ExpectedMachineType = "c2-standard-4",

  # Expected CPU platform (the min_cpu_platform value). A vendor prefix such as
  # "Intel Cascade Lake" or "AMD Milan" is fine; a substring match against the
  # real cpuPlatform string passes.
  [string]$ExpectedMinCpuPlatform = "Intel Cascade Lake",

  # Expected GCP network tier of each VM access_config.
  [string]$ExpectedNetworkTier = "PREMIUM",

  # Expected revision recorded in the bootstrap marker
  # (/var/lib/k8s-node-bootstrap.done). Empty skips the exact-revision check but
  # still requires every node to agree on one revision.
  [string]$ExpectedBootstrapRevision,

  # Exact image Terraform resolved for the first 4 nodes and reused on expansion.
  [string]$ExpectedSourceImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Invoke-GcloudJson {
  param([string[]]$Arguments)
  $output = & gcloud @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud command failed: gcloud $($Arguments -join ' ')"
  }
  return ($output | Out-String | ConvertFrom-Json)
}

function Invoke-RemoteCommand {
  param(
    [object]$Node,
    [string]$Command,
    [string]$SshUserValue,
    [string]$SshKeyFileValue
  )
  # gcloud compute ssh requires PuTTY (.ppk) on Windows and fails with an
  # OpenSSH-format key. Same as provision.ps1: connect straight to the external
  # IP with the built-in Windows OpenSSH and the key Terraform injected into the
  # instance metadata.
  if ([string]::IsNullOrWhiteSpace($SshUserValue)) {
    throw "SshUser is required for direct OpenSSH access."
  }
  $address = [string](Get-OptionalProperty -Object $Node -Name "external_ip" -Default "")
  if ([string]::IsNullOrWhiteSpace($address)) {
    throw "Node $($Node.name) has no external IP in the inventory; direct OpenSSH access requires allow_external_ip = true."
  }
  # base64 wrapper so PS 5.1 native quoting cannot corrupt a multi-line command.
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))
  $sshArgs = @(
    "-n",
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "LogLevel=ERROR"
  )
  if (-not [string]::IsNullOrWhiteSpace($SshKeyFileValue)) {
    $sshArgs += @("-i", $SshKeyFileValue)
  }
  $sshArgs += @("$SshUserValue@$address", "echo $encoded | base64 -d | bash")
  $output = & ssh @sshArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Remote command failed on $($Node.name): $Command"
  }
  return ($output | Out-String).Trim()
}

function Get-RackId {
  param([string]$PhysicalHost)
  if ([string]::IsNullOrWhiteSpace($PhysicalHost)) {
    return ""
  }
  $parts = @($PhysicalHost -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($parts.Count -lt 2) {
    return ""
  }
  return "$($parts[0])/$($parts[1])"
}

function Get-OptionalProperty {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )
  if ($null -eq $Object) {
    return $Default
  }
  if ($Object.PSObject.Properties.Name -contains $Name) {
    return $Object.$Name
  }
  return $Default
}

function Test-AllSameNonEmpty {
  param(
    [string[]]$Values,
    [int]$ExpectedCount
  )

  if ($Values.Count -ne $ExpectedCount -or $Values.Count -eq 0) {
    return $false
  }
  if (@($Values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    return $false
  }

  $first = $Values[0]
  return @(
    $Values | Where-Object {
      -not [string]::Equals($_, $first, [System.StringComparison]::Ordinal)
    }
  ).Count -eq 0
}

function Normalize-GcpImageReference {
  param([string]$Reference)

  if ([string]::IsNullOrWhiteSpace($Reference)) {
    return ""
  }
  $trimmed = $Reference.Trim().TrimEnd("/")
  $match = [regex]::Match($trimmed, "projects/([^/]+)/global/images/([^/]+)$")
  if ($match.Success) {
    return "projects/$($match.Groups[1].Value)/global/images/$($match.Groups[2].Value)"
  }
  return $trimmed
}

function Convert-InventoryToNodes {
  param([object]$Inventory)
  return @(
    $Inventory.PSObject.Properties | ForEach-Object {
      $value = $_.Value
      [pscustomobject]@{
        key         = $_.Name
        name        = $value.name
        role        = $value.role
        project_id  = $value.project_id
        zone        = $value.zone
        # Target address for direct OpenSSH (requires allow_external_ip = true).
        external_ip = (Get-OptionalProperty -Object $value -Name "external_ip" -Default "")
      }
    }
  )
}

Assert-Command "gcloud"
# Remote commands use the built-in Windows OpenSSH, not gcloud compute ssh.
Assert-Command "ssh"
if ([string]::IsNullOrWhiteSpace($ExpectedNetworkTier)) {
  throw "ExpectedNetworkTier must not be empty."
}
if ([string]::IsNullOrWhiteSpace($ExpectedMinCpuPlatform)) {
  throw "ExpectedMinCpuPlatform must not be empty."
}
# "Intel Cascade Lake" -> "Cascade Lake", "AMD Milan" -> "Milan".
# Matched as a substring of the GCP cpuPlatform string.
$expectedCpuPlatformPattern = [regex]::Escape(($ExpectedMinCpuPlatform -replace "^(Intel|AMD)\s+", ""))

if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) {
  if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "Inventory file not found: $InventoryPath"
  }
  $inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
}
elseif (-not [string]::IsNullOrWhiteSpace($TfDir)) {
  Assert-Command "terraform"
  $inventoryJson = & terraform -chdir="$TfDir" output -json inventory
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read terraform output inventory from $TfDir."
  }
  $inventory = $inventoryJson | Out-String | ConvertFrom-Json
}
else {
  throw "Provide either -InventoryPath or -TfDir."
}

$nodes = Convert-InventoryToNodes -Inventory $inventory

# The node count is not pinned to 4 (both 4-node and 8-node runs are supported).
# Instead the role mix is checked against the experiment premise
# (CP 1 + benchmark 1 + at least 2 workers).
$cpNodes = @($nodes | Where-Object { $_.role -eq "control-plane" })
$benchNodes = @($nodes | Where-Object { $_.role -eq "benchmark" })
$workerNodes = @($nodes | Where-Object { $_.role -eq "worker" })
if ($cpNodes.Count -ne 1 -or $benchNodes.Count -ne 1 -or $workerNodes.Count -lt 2) {
  throw "Inventory must contain 1 control-plane, 1 benchmark, and at least 2 workers (found cp=$($cpNodes.Count), bench=$($benchNodes.Count), worker=$($workerNodes.Count))."
}

# The provisioning engines always pass -OutDir; this default only serves a
# standalone run and stays inside the script tree.
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $PSScriptRoot "results\standalone\control-vars" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$describeByName = @{}
foreach ($node in $nodes) {
  $describeByName[$node.name] = Invoke-GcloudJson -Arguments @(
    "compute", "instances", "describe", $node.name,
    "--project", $node.project_id,
    "--zone", $node.zone,
    "--format", "json"
  )
}

$rackIds = @(
  $describeByName.Values | ForEach-Object {
    $resourceStatus = Get-OptionalProperty -Object $_ -Name "resourceStatus"
    $physicalHost = [string](Get-OptionalProperty -Object $resourceStatus -Name "physicalHost" -Default "")
    Get-RackId -PhysicalHost $physicalHost
  } | Where-Object { $_ }
)
$sameRack = $rackIds.Count -eq $nodes.Count -and (@($rackIds | Select-Object -Unique).Count -eq 1)

# OS/package/bootstrap revision is collected from every node first, then judged
# cluster-wide for equality before the per-row Passed flag is computed.
$runtimeByName = @{}
$sourceImageByName = @{}
foreach ($node in $nodes) {
  $vm = $describeByName[$node.name]
  $disks = @(Get-OptionalProperty -Object $vm -Name "disks" -Default @())
  $bootDisks = @($disks | Where-Object { $_.boot -eq $true })
  if ($bootDisks.Count -ne 1) {
    throw "Expected exactly one boot disk on $($node.name), found $($bootDisks.Count)."
  }
  $diskName = ([string]$bootDisks[0].source -split "/")[-1]
  $disk = Invoke-GcloudJson -Arguments @(
    "compute", "disks", "describe", $diskName,
    "--project", $node.project_id,
    "--zone", $node.zone,
    "--format", "json"
  )
  $sourceImageByName[$node.name] = Normalize-GcpImageReference -Reference ([string](Get-OptionalProperty -Object $disk -Name "sourceImage" -Default ""))

  $runtimeByName[$node.name] = [pscustomobject]@{
    KernelRelease     = Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "uname -r"
    ContainerdVersion = Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "containerd --version"
    KubeletVersion    = Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "kubelet --version"
    BootstrapRevision = Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "cat /var/lib/k8s-node-bootstrap.done 2>/dev/null || true"
  }
}

$kernelReleases = @($nodes | ForEach-Object { [string]$runtimeByName[$_.name].KernelRelease })
$containerdVersions = @($nodes | ForEach-Object { [string]$runtimeByName[$_.name].ContainerdVersion })
$kubeletVersions = @($nodes | ForEach-Object { [string]$runtimeByName[$_.name].KubeletVersion })
$bootstrapRevisions = @($nodes | ForEach-Object { [string]$runtimeByName[$_.name].BootstrapRevision })
$sourceImages = @($nodes | ForEach-Object { [string]$sourceImageByName[$_.name] })

$kernelReleaseIdentical = Test-AllSameNonEmpty -Values $kernelReleases -ExpectedCount $nodes.Count
$containerdVersionIdentical = Test-AllSameNonEmpty -Values $containerdVersions -ExpectedCount $nodes.Count
$kubeletVersionIdentical = Test-AllSameNonEmpty -Values $kubeletVersions -ExpectedCount $nodes.Count
$bootstrapRevisionIdentical = Test-AllSameNonEmpty -Values $bootstrapRevisions -ExpectedCount $nodes.Count
$sourceImageIdentical = Test-AllSameNonEmpty -Values $sourceImages -ExpectedCount $nodes.Count
$normalizedExpectedSourceImage = Normalize-GcpImageReference -Reference $ExpectedSourceImage

$rows = @()
foreach ($node in $nodes) {
  $vm = $describeByName[$node.name]
  $vmTags = Get-OptionalProperty -Object $vm -Name "tags"
  $tags = @(Get-OptionalProperty -Object $vmTags -Name "items" -Default @())
  $machineType = ([string]$vm.machineType -split "/")[-1]
  $resourcePolicies = @(Get-OptionalProperty -Object $vm -Name "resourcePolicies" -Default @())
  $resourceStatus = Get-OptionalProperty -Object $vm -Name "resourceStatus"
  $physicalHost = [string](Get-OptionalProperty -Object $resourceStatus -Name "physicalHost" -Default "")
  $rackId = Get-RackId -PhysicalHost $physicalHost
  $scheduling = Get-OptionalProperty -Object $vm -Name "scheduling"
  $onHostMaintenance = Get-OptionalProperty -Object $scheduling -Name "onHostMaintenance" -Default ""

  $accessConfigNetworkTiers = @(
    $networkInterfaces = @(Get-OptionalProperty -Object $vm -Name "networkInterfaces" -Default @())
    foreach ($networkInterface in $networkInterfaces) {
      $accessConfigs = @(Get-OptionalProperty -Object $networkInterface -Name "accessConfigs" -Default @())
      foreach ($accessConfig in $accessConfigs) {
        $networkTier = [string](Get-OptionalProperty -Object $accessConfig -Name "networkTier" -Default "")
        if (-not [string]::IsNullOrWhiteSpace($networkTier)) {
          $networkTier
        }
      }
    }
  )
  $uniqueAccessConfigNetworkTiers = @($accessConfigNetworkTiers | Select-Object -Unique)
  $accessConfigNetworkTier = $uniqueAccessConfigNetworkTiers -join ","
  $networkTierMatchesExpected = (
    $accessConfigNetworkTiers.Count -gt 0 -and
    $uniqueAccessConfigNetworkTiers.Count -eq 1 -and
    [string]::Equals(
      $uniqueAccessConfigNetworkTiers[0],
      $ExpectedNetworkTier.Trim(),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  )

  $runtime = $runtimeByName[$node.name]
  $kernelRelease = [string]$runtime.KernelRelease
  $containerdVersion = [string]$runtime.ContainerdVersion
  $kubeletVersion = [string]$runtime.KubeletVersion
  $bootstrapRevision = [string]$runtime.BootstrapRevision
  $bootstrapRevisionMatchesExpected = if ([string]::IsNullOrWhiteSpace($ExpectedBootstrapRevision)) {
    $true
  }
  else {
    [string]::Equals(
      $bootstrapRevision,
      $ExpectedBootstrapRevision.Trim(),
      [System.StringComparison]::Ordinal
    )
  }
  $sourceImage = [string]$sourceImageByName[$node.name]
  $sourceImageMatchesExpected = if ([string]::IsNullOrWhiteSpace($normalizedExpectedSourceImage)) {
    $true
  }
  else {
    [string]::Equals(
      $sourceImage,
      $normalizedExpectedSourceImage,
      [System.StringComparison]::Ordinal
    )
  }

  $requiredTagOk = if ([string]::IsNullOrWhiteSpace($RequiredTag)) { $true } else { $tags -contains $RequiredTag }

  $iface = Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "ip route show default | awk '{print `$5; exit}'"

  # NIC MTU is recorded for reference only (it does not affect Passed).
  # The VPC MTU (expected 1500) is already verified by the Terraform
  # precondition (expected_network_mtu).
  $nicMtu = if ([string]::IsNullOrWhiteSpace($iface)) {
    ""
  }
  else {
    Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "cat /sys/class/net/$iface/mtu"
  }

  # vCPU count is recorded for reference only (it does not affect Passed).
  # threads_per_core is not set, so c2-standard-4 must report its default of 4.
  $vcpuCount = Invoke-RemoteCommand -Node $node -SshUserValue $SshUser -SshKeyFileValue $SshKeyFile -Command "nproc"

  $passed = (
    $vm.canIpForward -eq $true -and
    $requiredTagOk -and
    $machineType -eq $ExpectedMachineType -and
    ([string]$vm.cpuPlatform -match $expectedCpuPlatformPattern) -and
    $onHostMaintenance -eq "TERMINATE" -and
    $resourcePolicies.Count -gt 0 -and
    $sameRack -and
    $networkTierMatchesExpected -and
    $kernelReleaseIdentical -and
    $containerdVersionIdentical -and
    $kubeletVersionIdentical -and
    $bootstrapRevisionIdentical -and
    $bootstrapRevisionMatchesExpected -and
    $sourceImageIdentical -and
    $sourceImageMatchesExpected
  )

  $rows += [pscustomobject]@{
    Name                             = $node.name
    Role                             = $node.role
    MachineType                      = $machineType
    CanIpForward                     = $vm.canIpForward
    RequiredTag                      = $RequiredTag
    RequiredTagPresent               = $requiredTagOk
    CpuPlatform                      = $vm.cpuPlatform
    OnHostMaintenance                = $onHostMaintenance
    CompactPolicyAttached            = ($resourcePolicies.Count -gt 0)
    PhysicalHost                     = $physicalHost
    RackId                           = $rackId
    SameRack                         = $sameRack
    DefaultInterface                 = $iface
    NicMtu                           = $nicMtu
    VcpuCount                        = $vcpuCount
    AccessConfigNetworkTier          = $accessConfigNetworkTier
    ExpectedNetworkTier              = $ExpectedNetworkTier
    NetworkTierMatchesExpected       = $networkTierMatchesExpected
    KernelRelease                    = $kernelRelease
    KernelReleaseIdentical           = $kernelReleaseIdentical
    ContainerdVersion                = $containerdVersion
    ContainerdVersionIdentical       = $containerdVersionIdentical
    KubeletVersion                   = $kubeletVersion
    KubeletVersionIdentical          = $kubeletVersionIdentical
    BootstrapRevision                = $bootstrapRevision
    BootstrapRevisionIdentical       = $bootstrapRevisionIdentical
    ExpectedBootstrapRevision        = $ExpectedBootstrapRevision
    BootstrapRevisionMatchesExpected = $bootstrapRevisionMatchesExpected
    SourceImage                       = $sourceImage
    SourceImageIdentical              = $sourceImageIdentical
    ExpectedSourceImage               = $normalizedExpectedSourceImage
    SourceImageMatchesExpected        = $sourceImageMatchesExpected
    Passed                           = $passed
  }
}

$suffix = "$($ExperimentName)_$($nodes.Count)"
if ($Iteration -gt 0) {
  $suffix = "{0}_iter{1}" -f $suffix, $Iteration
}
$csvPath = Join-Path $OutDir "control-vars-$suffix.csv"
$jsonPath = Join-Path $OutDir "control-vars-$suffix.json"
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
ConvertTo-Json -InputObject @($rows) -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $jsonPath

if (@($rows | Where-Object { -not $_.Passed }).Count -gt 0) {
  $rows | Format-Table -AutoSize | Out-String | Write-Host
  throw "One or more control variable checks failed. See $csvPath"
}

Write-Host "Control variable checks passed. Wrote $csvPath"
