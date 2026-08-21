Set-StrictMode -Version Latest

# Dot-sourced by destroy.ps1.  The ownership marker is mandatory before
# any destructive T4 cleanup: a name collision found before T4 was claimed must
# never cause an unrelated pre-existing GCP resource to be deleted.

function Get-NativeT4StatePath {
  param(
    [string]$TfDirFull,
    [string]$Method
  )
  return (Join-Path $TfDirFull ".native-routing-t4-$Method.json")
}

function Test-CleanupGcloudResource {
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

function Invoke-T4CleanupCommand {
  param(
    [string[]]$Arguments,
    [string]$TfDirFull,
    [string]$OutDirFull,
    [string]$Name
  )

  $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-')
  Invoke-NativeLogged -File "gcloud" -Arguments ($Arguments + @("--quiet")) `
    -WorkingDirectory $TfDirFull -LogPath (Join-Path $OutDirFull "t4-cleanup-$safeName.log")
}

function Remove-NativeRoutingT4 {
  param(
    [ValidateSet("static", "dynamic")]
    [string]$Method,
    [string]$ProjectId,
    [string]$Region,
    [string]$SubnetworkName,
    [string]$ResourcePrefix,
    [string]$TfDirFull,
    [string]$OutDirFull
  )

  $statePath = Get-NativeT4StatePath -TfDirFull $TfDirFull -Method $Method
  if (-not (Test-Path -LiteralPath $statePath)) {
    Write-Warning "No T4 ownership marker exists at '$statePath'. Method-specific resources will be verified but not deleted."
    return
  }
  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if ([int]$state.schema_version -ne 1 -or
      [string]$state.method -ne $Method -or
      [string]$state.project_id -ne $ProjectId -or
      [string]$state.resource_prefix -ne $ResourcePrefix) {
    throw "Refusing T4 cleanup because ownership state does not match this destroy: $statePath"
  }

  switch ($Method) {
    "static" {
      $routes = @(Get-GcloudNames -Arguments @(
        "compute", "routes", "list",
        "--project", $ProjectId,
        "--filter", "name~^$ResourcePrefix-pod-",
        "--format", "value(name)"
      ))
      foreach ($route in $routes) {
        Invoke-T4CleanupCommand -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "static-route-$route" -Arguments @(
          "compute", "routes", "delete", $route, "--project", $ProjectId
        )
      }
    }
    "dynamic" {
      $spokeName = "$ResourcePrefix-spoke"
      $routerName = "$ResourcePrefix-router"
      $hubName = "$ResourcePrefix-hub"
      $claimedProperty = $state.PSObject.Properties["resources_claimed"]
      $resourcesClaimed = $null -ne $claimedProperty -and [bool]$claimedProperty.Value
      if ($resourcesClaimed) {
        if (Test-CleanupGcloudResource -Arguments @("network-connectivity", "spokes", "describe", $spokeName, "--region", $Region, "--project", $ProjectId)) {
          Invoke-T4CleanupCommand -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-spoke" -Arguments @(
            "network-connectivity", "spokes", "delete", $spokeName,
            "--region", $Region, "--project", $ProjectId
          )
        }
        if (Test-CleanupGcloudResource -Arguments @("compute", "routers", "describe", $routerName, "--region", $Region, "--project", $ProjectId)) {
          Invoke-T4CleanupCommand -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-router" -Arguments @(
            "compute", "routers", "delete", $routerName,
            "--region", $Region, "--project", $ProjectId
          )
        }
        if (Test-CleanupGcloudResource -Arguments @("network-connectivity", "hubs", "describe", $hubName, "--project", $ProjectId)) {
          Invoke-T4CleanupCommand -TfDirFull $TfDirFull -OutDirFull $OutDirFull -Name "dynamic-hub" -Arguments @(
            "network-connectivity", "hubs", "delete", $hubName, "--project", $ProjectId
          )
        }
      }

      # Service activation is project-scoped shared state, not an experiment-owned
      # resource. Keep networkconnectivity.googleapis.com enabled after cleanup;
      # only the NCC/Cloud Router resources claimed by this marker are removed.
    }
  }

  # Keep the marker until the caller's independent post-destroy GCP checks pass.
  # This preserves retryable ownership if an API reports success before a
  # resource has fully disappeared.
}

function Get-NativeRoutingT4VerificationChecks {
  param(
    [ValidateSet("static", "dynamic")]
    [string]$Method,
    [string]$ProjectId,
    [string]$Region,
    [string]$SubnetworkName,
    [string]$ResourcePrefix
  )

  $checks = @()
  switch ($Method) {
    "static" {
      $names = @(Get-GcloudNames -Arguments @(
        "compute", "routes", "list", "--project", $ProjectId,
        "--filter", "name~^$ResourcePrefix-pod-", "--format", "value(name)"
      ))
      $checks += [pscustomobject]@{
        check = "gcp_static_routes_prefix_$ResourcePrefix-pod-"
        found = $names.Count
        names = ($names -join ";")
        passed = ($names.Count -eq 0)
      }
    }
    "dynamic" {
      $resourceSpecs = @(
        [pscustomobject]@{ Type = "ncc_hub"; Name = "$ResourcePrefix-hub"; Args = @("network-connectivity", "hubs", "describe", "$ResourcePrefix-hub", "--project", $ProjectId) },
        [pscustomobject]@{ Type = "ncc_spoke"; Name = "$ResourcePrefix-spoke"; Args = @("network-connectivity", "spokes", "describe", "$ResourcePrefix-spoke", "--region", $Region, "--project", $ProjectId) },
        [pscustomobject]@{ Type = "cloud_router"; Name = "$ResourcePrefix-router"; Args = @("compute", "routers", "describe", "$ResourcePrefix-router", "--region", $Region, "--project", $ProjectId) }
      )
      foreach ($spec in $resourceSpecs) {
        $exists = Test-CleanupGcloudResource -Arguments $spec.Args
        $checks += [pscustomobject]@{
          check = "gcp_$($spec.Type)_$($spec.Name)"
          found = if ($exists) { 1 } else { 0 }
          names = if ($exists) { $spec.Name } else { "" }
          passed = (-not $exists)
        }
      }
    }
  }
  return $checks
}
