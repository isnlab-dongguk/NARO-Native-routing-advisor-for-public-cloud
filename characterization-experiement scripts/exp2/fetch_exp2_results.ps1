<#
.SYNOPSIS
Copies completed experiment-2 results from the Control Plane VM to a new local snapshot folder.

.EXAMPLE
.\exp2\fetch_exp2_results.ps1 -TfvarsPath .\infra\vxlan\terraform.tfvars

.EXAMPLE
.\exp2\fetch_exp2_results.ps1 -ControlPlane vxlan-cp-0 -Zone asia-northeast3-a -Project my-gcp-project -SshUser myuser -SshKeyFile $HOME\.ssh\experiment_ed25519 -RemoteResultsDir /var/lib/experiment/results/exp2 -LocalRoot .\results\exp2-from-cp
#>
[CmdletBinding()]
param(
  [string]$TfvarsPath = "",

  [ValidatePattern('^$|^[a-z]([-a-z0-9]*[a-z0-9])?$')]
  [string]$ControlPlane = "",

  [ValidatePattern('^$|^[a-z0-9]+(?:-[a-z0-9]+)+$')]
  [string]$Zone = "",

  [ValidateScript({ [string]::IsNullOrWhiteSpace($_) -or $_ -notmatch "[\r\n]" })]
  [string]$RemoteResultsDir = "",

  [string]$LocalRoot = "",
  [string]$Project = "",

  [ValidatePattern('^$|^[a-z_][a-z0-9_-]*$')]
  [string]$SshUser = "",

  [string]$SshKeyFile = "",
  [switch]$TunnelThroughIap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TfVarString {
  param(
    [string]$Path,
    [string]$Name
  )
  $pattern = "^\s*$([regex]::Escape($Name))\s*=\s*`"([^`"]+)`""
  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    if ($line -match $pattern) {
      return $Matches[1]
    }
  }
  return $null
}

function Get-TfVariableDefaultString {
  param(
    [string]$Path,
    [string]$Name
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  $insideTarget = $false
  $variablePattern = '^\s*variable\s+"([^"]+)"\s*\{'
  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    if ($line -match $variablePattern) {
      if ($insideTarget) {
        break
      }
      $insideTarget = $Matches[1] -eq $Name
      continue
    }
    if ($insideTarget -and $line -match '^\s*default\s*=\s*"([^"]+)"') {
      return $Matches[1]
    }
  }
  return $null
}

function Resolve-TfInputPath {
  param(
    [string]$Path,
    [string]$TfDirectory
  )
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $TfDirectory $Path))
}

$tfvarsFull = ""
if (-not [string]::IsNullOrWhiteSpace($TfvarsPath)) {
  $tfvarsFull = [System.IO.Path]::GetFullPath($TfvarsPath)
  if (-not (Test-Path -LiteralPath $tfvarsFull -PathType Leaf)) {
    throw "Terraform tfvars file not found: $tfvarsFull"
  }

  $tfDirectory = Split-Path -Parent $tfvarsFull
  $variablesFile = Join-Path $tfDirectory "variables.tf"
  $tfProject = Get-TfVarString -Path $tfvarsFull -Name "project_id"
  $tfZone = Get-TfVarString -Path $tfvarsFull -Name "zone"
  if ([string]::IsNullOrWhiteSpace($tfZone)) {
    $tfZone = Get-TfVariableDefaultString -Path $variablesFile -Name "zone"
  }
  if ([string]::IsNullOrWhiteSpace($tfZone)) {
    $tfZone = "asia-northeast3-a"
  }
  $tfExperiment = Get-TfVarString -Path $tfvarsFull -Name "experiment_name"
  if ([string]::IsNullOrWhiteSpace($tfExperiment)) {
    $tfExperiment = Get-TfVariableDefaultString -Path $variablesFile -Name "experiment_name"
  }
  if ([string]::IsNullOrWhiteSpace($tfExperiment)) {
    throw "Could not resolve experiment_name from $tfvarsFull or $variablesFile."
  }
  $tfPrefix = Get-TfVarString -Path $tfvarsFull -Name "prefix"
  if ([string]::IsNullOrWhiteSpace($tfPrefix)) {
    $tfPrefix = $tfExperiment
  }
  $tfSshUser = Get-TfVarString -Path $tfvarsFull -Name "ssh_user"

  if ([string]::IsNullOrWhiteSpace($Project)) {
    if ([string]::IsNullOrWhiteSpace($tfProject)) {
      throw "Could not parse project_id from $tfvarsFull."
    }
    $Project = $tfProject
  }
  if ([string]::IsNullOrWhiteSpace($Zone)) {
    $Zone = $tfZone
  }
  if ([string]::IsNullOrWhiteSpace($ControlPlane)) {
    $ControlPlane = "$tfPrefix-cp-0"
  }
  if ([string]::IsNullOrWhiteSpace($SshUser)) {
    $SshUser = $tfSshUser
  }
  if ([string]::IsNullOrWhiteSpace($RemoteResultsDir)) {
    $RemoteResultsDir = "/var/lib/experiment/results/exp2"
  }
  if ([string]::IsNullOrWhiteSpace($SshKeyFile)) {
    $tfPrivateKey = Get-TfVarString -Path $tfvarsFull -Name "ssh_private_key_path"
    if ([string]::IsNullOrWhiteSpace($tfPrivateKey)) {
      $tfPublicKey = Get-TfVarString -Path $tfvarsFull -Name "ssh_public_key_path"
      if (-not [string]::IsNullOrWhiteSpace($tfPublicKey) -and
          $tfPublicKey.EndsWith(".pub", [System.StringComparison]::OrdinalIgnoreCase)) {
        $tfPrivateKey = $tfPublicKey.Substring(0, $tfPublicKey.Length - 4)
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($tfPrivateKey)) {
      $SshKeyFile = Resolve-TfInputPath -Path $tfPrivateKey -TfDirectory $tfDirectory
    }
  }
}

if ([string]::IsNullOrWhiteSpace($ControlPlane)) {
  throw "ControlPlane is required. Pass -TfvarsPath or -ControlPlane."
}
if ([string]::IsNullOrWhiteSpace($Zone)) {
  throw "Zone is required. Pass -TfvarsPath or -Zone."
}
if ([string]::IsNullOrWhiteSpace($RemoteResultsDir)) {
  throw "RemoteResultsDir is required. Pass -TfvarsPath or -RemoteResultsDir."
}
if ($RemoteResultsDir -notmatch '^/[\p{L}\p{Nd}._/-]+$') {
  throw "RemoteResultsDir must be an absolute Linux path containing only letters, digits, '/', '.', '_' or '-': $RemoteResultsDir"
}
$remotePathSegments = @($RemoteResultsDir.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries))
if ($remotePathSegments -contains "." -or $remotePathSegments -contains "..") {
  throw "RemoteResultsDir must not contain '.' or '..' path segments: $RemoteResultsDir"
}
if (-not [string]::IsNullOrWhiteSpace($SshUser) -and $SshUser -notmatch '^[a-z_][a-z0-9_-]*$') {
  throw "Invalid SSH user resolved from tfvars: $SshUser"
}

if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
  $LocalRoot = Join-Path $PSScriptRoot "..\results\exp2-from-cp"
}
if (-not [string]::IsNullOrWhiteSpace($SshKeyFile)) {
  $SshKeyFile = [System.IO.Path]::GetFullPath($SshKeyFile)
  if (-not (Test-Path -LiteralPath $SshKeyFile -PathType Leaf)) {
    throw "SSH key file not found: $SshKeyFile"
  }
}

if ([string]::IsNullOrWhiteSpace($SshUser)) {
  throw "SshUser is required. Pass -TfvarsPath or -SshUser."
}
if ([string]::IsNullOrWhiteSpace($SshKeyFile)) {
  throw "SshKeyFile is required. Pass -TfvarsPath or the experiment-1 OpenSSH private key with -SshKeyFile."
}
if ([System.IO.Path]::GetExtension($SshKeyFile) -ieq ".pub") {
  throw "SshKeyFile must be an OpenSSH private key, not a public key: $SshKeyFile"
}
if ([System.IO.Path]::GetExtension($SshKeyFile) -ieq ".ppk") {
  throw "PuTTY PPK keys are not supported. Pass the experiment-1 OpenSSH private key: $SshKeyFile"
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  throw "Project is required. Pass -TfvarsPath or -Project so the GCE and IAP target is deterministic."
}
if ($Project -notmatch '^[a-z0-9][a-z0-9:.-]*$') {
  throw "Invalid GCP project identifier: $Project"
}

function Get-RequiredApplication {
  param(
    [string]$Name,
    [string]$Description
  )
  $application = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $application) {
    throw "$Description is required on the local machine."
  }
  return $application
}

function Get-JsonPropertyValue {
  param(
    [AllowNull()]
    [object]$InputObject,
    [string]$Name
  )
  if ($null -eq $InputObject) {
    return $null
  }
  $property = $InputObject.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

$gcloud = Get-RequiredApplication -Name "gcloud" -Description "gcloud CLI"
$scp = Get-RequiredApplication -Name "scp" -Description "OpenSSH scp"

$describeArguments = @(
  "compute", "instances", "describe", $ControlPlane,
  "--zone", $Zone,
  "--format=json",
  "--quiet"
)
if (-not [string]::IsNullOrWhiteSpace($Project)) {
  $describeArguments += @("--project", $Project)
}

$describeOutput = @(& $gcloud.Source @describeArguments)
if ($LASTEXITCODE -ne 0) {
  throw "gcloud compute instances describe failed for $ControlPlane with exit code $LASTEXITCODE."
}
try {
  $instance = ($describeOutput -join [Environment]::NewLine) | ConvertFrom-Json
}
catch {
  throw "Could not parse gcloud instance metadata for $ControlPlane as JSON: $($_.Exception.Message)"
}

$instanceId = [string](Get-JsonPropertyValue -InputObject $instance -Name "id")
if ([string]::IsNullOrWhiteSpace($instanceId) -or $instanceId -notmatch '^\d+$') {
  throw "gcloud did not return a valid numeric instance ID for $ControlPlane."
}

$externalIp = ""
$networkInterfaces = @(Get-JsonPropertyValue -InputObject $instance -Name "networkInterfaces")
foreach ($networkInterface in $networkInterfaces) {
  $accessConfigs = @(Get-JsonPropertyValue -InputObject $networkInterface -Name "accessConfigs")
  foreach ($accessConfig in $accessConfigs) {
    $candidateIp = [string](Get-JsonPropertyValue -InputObject $accessConfig -Name "natIP")
    if (-not [string]::IsNullOrWhiteSpace($candidateIp)) {
      $externalIp = $candidateIp
      break
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($externalIp)) {
    break
  }
}

if (-not $TunnelThroughIap) {
  $parsedIp = $null
  if (-not [System.Net.IPAddress]::TryParse($externalIp, [ref]$parsedIp) -or
      $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "No valid external IPv4 address was found for $ControlPlane. Use -TunnelThroughIap when the CP has no external IP."
  }
}

$localRootFull = [System.IO.Path]::GetFullPath($LocalRoot)
New-Item -ItemType Directory -Path $localRootFull -Force | Out-Null

$keyDirectory = Split-Path -Parent $SshKeyFile
$knownHostsDirectory = Join-Path $keyDirectory "experiment-known-hosts"
New-Item -ItemType Directory -Path $knownHostsDirectory -Force | Out-Null
$knownHostIdentity = "{0}_{1}_{2}_{3}" -f $(if ([string]::IsNullOrWhiteSpace($Project)) { "default-project" } else { $Project }), $Zone, $ControlPlane, $instanceId
$knownHostIdentity = $knownHostIdentity -replace '[^a-zA-Z0-9._-]', '_'
$knownHostsFile = Join-Path $knownHostsDirectory "$knownHostIdentity.known_hosts"
if (-not (Test-Path -LiteralPath $knownHostsFile -PathType Leaf)) {
  [System.IO.File]::WriteAllText($knownHostsFile, "", [System.Text.UTF8Encoding]::new($false))
}
$knownHostsOpenSsh = $knownHostsFile.Replace('\', '/')

$safeControlPlane = $ControlPlane -replace '[^a-zA-Z0-9._-]', '_'
$snapshotName = "{0}_{1}_{2}" -f $safeControlPlane, (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$destination = Join-Path $localRootFull $snapshotName
New-Item -ItemType Directory -Path $destination | Out-Null

$connectionHost = if ($TunnelThroughIap) { $ControlPlane } else { $externalIp }
$remoteHost = "$SshUser@$connectionHost"
$remotePath = $RemoteResultsDir.TrimEnd('/')
$remoteSpec = "${remoteHost}:$remotePath"

$arguments = @(
  "-r",
  "-o", "IdentitiesOnly=yes",
  "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=30",
  "-o", "ServerAliveInterval=15",
  "-o", "ServerAliveCountMax=4",
  "-o", "StrictHostKeyChecking=accept-new",
  "-o", "HostKeyAlias=$ControlPlane",
  "-o", "UserKnownHostsFile=$knownHostsOpenSsh",
  "-i", $SshKeyFile
)
if ($TunnelThroughIap) {
  $gcloudForProxy = $gcloud.Source.Replace('\', '/')
  $quotedGcloudForProxy = '\"' + $gcloudForProxy + '\"'
  $proxyCommand = "$quotedGcloudForProxy compute start-iap-tunnel %h %p --listen-on-stdin --zone=$Zone"
  if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $proxyCommand += " --project=$Project"
  }
  $proxyCommand += " --verbosity=warning --quiet"
  $arguments += @("-o", "ProxyCommand=$proxyCommand")
}
$arguments += @($remoteSpec, $destination)

$completed = $false
try {
  $transport = if ($TunnelThroughIap) { "OpenSSH scp through IAP" } else { "OpenSSH scp to $externalIp" }
  Write-Host "Fetching $SshUser@$ControlPlane`:$remotePath -> $destination ($transport)"
  & $scp.Source @arguments
  if ($LASTEXITCODE -ne 0) {
    $iapHint = if ($TunnelThroughIap) { " Check roles/iap.tunnelResourceAccessor and TCP/22 from 35.235.240.0/20." } else { "" }
    throw "OpenSSH scp failed with exit code $LASTEXITCODE.$iapHint"
  }

  $inProgressFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -Force -File |
    Where-Object { $_.Name -like "*.inprogress.csv" })
  $claimDirectories = @(Get-ChildItem -LiteralPath $destination -Recurse -Force -Directory |
    Where-Object { $_.Name -like "*.claim" })
  if ($inProgressFiles.Count -gt 0 -or $claimDirectories.Count -gt 0) {
    throw "The copied directory contains an active/incomplete benchmark. Run this script after the CP benchmark completes."
  }

  $resultCsv = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter "*.csv" |
    Where-Object { $_.Name -notlike "*.inprogress.csv" })
  if ($resultCsv.Count -eq 0) {
    throw "No completed or failed experiment CSV was found under the copied directory."
  }

  $metadata = @(
    "fetched_at_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
    "control_plane=$ControlPlane",
    "instance_id=$instanceId",
    "zone=$Zone",
    "project=$Project",
    "tfvars_path=$tfvarsFull",
    "ssh_user=$SshUser",
    "ssh_key_file=$SshKeyFile",
    "transfer_client=openssh-scp",
    "tunnel_through_iap=$([bool]$TunnelThroughIap)",
    "external_ip=$externalIp",
    "known_hosts_file=$knownHostsFile",
    "remote_results_dir=$RemoteResultsDir",
    "result_csv_count=$($resultCsv.Count)"
  )
  [System.IO.File]::WriteAllLines(
    (Join-Path $destination "fetch-metadata.txt"),
    $metadata,
    [System.Text.UTF8Encoding]::new($false)
  )
  $completed = $true
  Write-Host "Fetch complete: $destination"
}
finally {
  if (-not $completed -and (Test-Path -LiteralPath $destination)) {
    Remove-Item -LiteralPath $destination -Recurse -Force
  }
}