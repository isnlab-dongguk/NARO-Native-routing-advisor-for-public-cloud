Set-StrictMode -Version Latest

# Shared provisioning helpers, dot-sourced by provision.ps1 (kubeadm methods)
# and provision-gke.ps1. Dot-sourcing keeps every "$script:" reference bound to
# the calling script, so both engines own their own timeline/state variables.
#
# The caller must define before dot-sourcing:
#   $script:MonotonicClock        Stopwatch started at process start
#   $script:Timeline              @()
#   $script:CommandTimings        @()
#   $script:DurationRows          @()
#   $script:ResultMethodLabel     method token written to the CSV method column
#   $script:ExperimentLabel, $script:ExpectedNodeCount, $script:RunIteration
#   $script:RunStatus, $script:ApplyAttempted, $script:LastNativeTiming
# and after resolving its output directory:
#   $script:OutDirFull, $script:CommandTimingsJsonPath, $script:CommandTimingsCsvPath

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Resolve-TfvarsPath {
  # terraform.tfvars holds per-user values (project id, SSH key path) and is not
  # shipped, so a missing file gets a message naming the template to copy
  # instead of a bare path-resolution error.
  param(
    [string]$Path,
    [string]$BasePath
  )
  $full = Join-WorkspacePath -Path $Path -BasePath $BasePath
  if (Test-Path -LiteralPath $full -PathType Leaf) {
    return (Resolve-Path -LiteralPath $full).Path
  }
  if (Test-Path -LiteralPath "$full.example" -PathType Leaf) {
    throw "terraform.tfvars not found: $full`nCopy the template next to it and fill it in:`n  copy `"$full.example`" `"$full`""
  }
  throw "terraform.tfvars not found: $full"
}

function Set-Step {
  # Tracked so failure-report.json can name the step that died.
  param([string]$Name)
  $script:CurrentStep = $Name
  Write-Host "==> $Name"
}

function Write-StageNotice {
  # Console banner for a completed T boundary. Purely informational: it keeps
  # "Apply complete" from being mistaken for the end of provisioning and has no
  # effect on the recorded timeline.
  param(
    [string[]]$Message,
    [System.ConsoleColor]$Color = [System.ConsoleColor]::Green
  )
  $line = "".PadRight(74, "=")
  Write-Host $line -ForegroundColor $Color
  foreach ($text in $Message) {
    Write-Host $text -ForegroundColor $Color
  }
  Write-Host $line -ForegroundColor $Color
}

function ConvertTo-ResultFileComponent {
  param(
    [string]$Value,
    [string]$FieldName
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$FieldName must not be empty."
  }
  $trimmed = $Value.Trim()
  if ($trimmed.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "$FieldName contains a character that cannot be used in a result filename: '$Value'."
  }
  return $trimmed
}

function Initialize-RunResultFile {
  param(
    [string]$Method,
    [int]$NodeCount,
    [string]$Experiment,
    [bool]$PlanOnly
  )

  $methodPart = ConvertTo-ResultFileComponent -Value $Method -FieldName "method"
  $experimentPart = ConvertTo-ResultFileComponent -Value $Experiment -FieldName "ExperimentLabel"
  $resultPrefix = "{0}_{1}_{2}_" -f $methodPart, $NodeCount, $experimentPart
  $escapedPrefix = [regex]::Escape($resultPrefix)
  $completedPattern = "^{0}iter(?<iteration>[1-9][0-9]*)\.csv$" -f $escapedPrefix
  $claimPattern = "^{0}iter(?<iteration>[1-9][0-9]*)\.csv\.inprogress$" -f $escapedPrefix

  $script:RunIteration = $null
  $script:RunResultCsvPath = $null
  $script:RunResultClaimPath = $null
  $script:RunOutputClaimed = $false
  if ($PlanOnly) {
    return
  }

  while ($true) {
    $resultFiles = @(
      Get-ChildItem -LiteralPath $script:OutDirFull -Force |
        Where-Object { -not $_.PSIsContainer }
    )
    $activeClaims = @(
      $resultFiles | Where-Object {
        [regex]::IsMatch(
          $_.Name,
          $claimPattern,
          [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
      }
    )
    if ($activeClaims.Count -gt 0) {
      $activeClaimList = ($activeClaims.FullName -join ", ")
      throw "A result iteration is already in progress for '$resultPrefix': $activeClaimList. Another provisioning run may be active; if it is not, inspect and remove the stale .inprogress file before retrying."
    }

    # Next iteration = highest completed iteration + 1. Gaps are never reused
    # (with 1 and 3 on disk the next run is 4).
    $highestIteration = [long]0
    foreach ($file in $resultFiles) {
      $match = [regex]::Match(
        $file.Name,
        $completedPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      if (-not $match.Success) {
        continue
      }
      $parsedIteration = [long]0
      if ([long]::TryParse($match.Groups["iteration"].Value, [ref]$parsedIteration) -and
          $parsedIteration -gt $highestIteration) {
        $highestIteration = $parsedIteration
      }
    }
    if ($highestIteration -ge [int]::MaxValue) {
      throw "Cannot allocate another result iteration for '$resultPrefix': the maximum supported iteration number has been reached."
    }

    $selectedIteration = [int]($highestIteration + 1)
    $baseName = "{0}iter{1}" -f $resultPrefix, $selectedIteration
    $candidate = Join-Path $script:OutDirFull "$baseName.csv"
    $claimPath = "$candidate.inprogress"

    try {
      # FileMode.CreateNew guarantees that when two processes compute the same
      # next iteration only one claims it. The loser stops instead of moving to
      # the next number, so two runs never mutate the same Terraform state.
      $claimStream = [System.IO.File]::Open(
        $claimPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
      )
    }
    catch [System.IO.IOException] {
      throw "Result iteration $selectedIteration is already claimed: $claimPath. Another provisioning run may be active; if it is not, inspect and remove the stale .inprogress file before retrying."
    }

    $retrySelection = $false
    $claimCommitted = $false
    try {
      # Handles the race where a previous run finished its CSV and released its
      # claim right after the directory scan: drop this claim and recompute.
      if (Test-Path -LiteralPath $candidate) {
        $retrySelection = $true
      }
      else {
        $claimText = "pid=$PID`nstarted_at=$((Get-Date).ToUniversalTime().ToString('o'))`nresult=$candidate`niteration=$selectedIteration`n"
        $claimBytes = [System.Text.Encoding]::UTF8.GetBytes($claimText)
        $claimStream.Write($claimBytes, 0, $claimBytes.Length)
        $claimCommitted = $true
      }
    }
    finally {
      $claimStream.Dispose()
      if (-not $claimCommitted -and (Test-Path -LiteralPath $claimPath)) {
        Remove-Item -LiteralPath $claimPath -Force
      }
    }
    if ($retrySelection) {
      continue
    }

    $script:RunIteration = $selectedIteration
    $script:RunResultCsvPath = $candidate
    $script:RunResultClaimPath = $claimPath
    $script:RunOutputClaimed = $true
    Write-Host "Selected result iteration automatically: $selectedIteration ($candidate)"
    return
  }
}

function Release-RunResultClaim {
  try {
    if (-not [string]::IsNullOrWhiteSpace($script:RunResultClaimPath) -and
        (Test-Path -LiteralPath $script:RunResultClaimPath)) {
      Remove-Item -LiteralPath $script:RunResultClaimPath -Force
    }
  }
  catch {
    Write-Warning "Could not remove result claim '$($script:RunResultClaimPath)': $($_.Exception.Message)"
  }
  $script:RunResultClaimPath = $null
  $script:RunOutputClaimed = $false
}

function Move-FileSnapshotAtomically {
  param(
    [string]$SourcePath,
    [string]$DestinationPath,
    [ValidateRange(1, 60)]
    [int]$MaxAttempts = 40
  )

  # Move-Item -Force on Windows PowerShell 5.1 intermittently fails with
  # "Cannot create a file when that file already exists" when replacing an
  # existing destination. Replace the snapshot atomically through NTFS
  # File.Replace and absorb short locks (antivirus, indexer, an open Excel) with
  # a bounded retry.
  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $backupPath = "$DestinationPath.replace-backup-$PID-$attempt"
    try {
      if ([System.IO.File]::Exists($DestinationPath)) {
        # The .NET Framework of Windows PowerShell 5.1 rejects a null backup
        # path, so ReplaceFile needs a unique backup in the same directory.
        [System.IO.File]::Replace($SourcePath, $DestinationPath, $backupPath, $true)
      }
      else {
        [System.IO.File]::Move($SourcePath, $DestinationPath)
      }
      return
    }
    catch {
      $lastError = $_
      if ($attempt -eq 8) {
        Write-Warning "Result CSV '$DestinationPath' is locked by another process. If it is open in Excel or a text editor, close it now - retrying for up to 30 more seconds."
      }
      if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Milliseconds ([math]::Min(1000, 50 * $attempt))
      }
    }
    finally {
      if ([System.IO.File]::Exists($backupPath)) {
        try {
          [System.IO.File]::Delete($backupPath)
        }
        catch {
          # Replacing the destination is what matters; a leftover backup never
          # justifies re-running the command.
        }
      }
    }
  }
  throw $lastError
}

function Write-RunResultCsv {
  if (-not $script:RunOutputClaimed -or [string]::IsNullOrWhiteSpace($script:RunResultCsvPath)) {
    return
  }

  $rows = @()
  foreach ($entry in @($script:Timeline)) {
    $dataJson = ConvertTo-Json -InputObject $entry.data -Depth 8 -Compress
    $rows += [pscustomobject][ordered]@{
      record_type           = if ($entry.name -eq "FAILURE") { "FAILURE" } else { "POINT" }
      name                  = $entry.name
      description           = $entry.description
      status                = $script:RunStatus
      method                = $script:ResultMethodLabel
      node_count            = $script:ExpectedNodeCount
      experiment            = $script:ExperimentLabel
      iteration             = $script:RunIteration
      timestamp_utc         = $entry.timestamp
      timestamp_unix_ms     = $entry.timestamp_unix_ms
      elapsed_ms            = $entry.elapsed_ms
      started_at            = $null
      ended_at              = $null
      duration_milliseconds = $null
      duration_seconds      = $null
      data_json             = $dataJson
    }
  }
  foreach ($duration in @($script:DurationRows)) {
    $rows += [pscustomobject][ordered]@{
      record_type           = "DURATION"
      name                  = $duration.name
      description           = $duration.description
      status                = $duration.status
      method                = $script:ResultMethodLabel
      node_count            = $script:ExpectedNodeCount
      experiment            = $script:ExperimentLabel
      iteration             = $script:RunIteration
      timestamp_utc         = $null
      timestamp_unix_ms     = $null
      elapsed_ms            = $null
      started_at            = $duration.started_at
      ended_at              = $duration.ended_at
      duration_milliseconds = $duration.duration_milliseconds
      duration_seconds      = $duration.duration_seconds
      data_json             = $null
    }
  }
  if ($rows.Count -eq 0) {
    return
  }

  # Every event rewrites the whole snapshot to a temporary file and swaps it in,
  # so a mid-run failure still leaves the last good CSV behind.
  $temporaryPath = "$($script:RunResultCsvPath).tmp-$PID"
  try {
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $temporaryPath
    Move-FileSnapshotAtomically -SourcePath $temporaryPath -DestinationPath $script:RunResultCsvPath
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }

  # Round-trip immediately so a serializer that drops or reorders rows is caught.
  $persisted = @(Import-Csv -LiteralPath $script:RunResultCsvPath)
  $persistedEvents = @($persisted | Where-Object { $_.record_type -ne "DURATION" })
  if ($persistedEvents.Count -ne @($script:Timeline).Count) {
    throw "Result CSV round-trip mismatch: expected $(@($script:Timeline).Count) event rows, found $($persistedEvents.Count)."
  }
  for ($index = 0; $index -lt $persistedEvents.Count; $index++) {
    if ($persistedEvents[$index].name -ne $script:Timeline[$index].name) {
      throw "Result CSV event order mismatch at row $index."
    }
  }
  $persistedDurations = @($persisted | Where-Object { $_.record_type -eq "DURATION" })
  if ($persistedDurations.Count -ne @($script:DurationRows).Count) {
    throw "Result CSV round-trip mismatch: expected $(@($script:DurationRows).Count) duration rows, found $($persistedDurations.Count)."
  }
  for ($index = 0; $index -lt $persistedDurations.Count; $index++) {
    if ($persistedDurations[$index].name -ne $script:DurationRows[$index].name) {
      throw "Result CSV duration order mismatch at row $index."
    }
  }
}

function Assert-TimelineEventCanBeAdded {
  param(
    [string]$Name,
    [double]$ElapsedMilliseconds
  )

  $expectedNames = @("T0", "T1", "T2", "T3", "T4", "T5")
  if ($Name -match '^T\d+$' -and $expectedNames -notcontains $Name) {
    throw "Unsupported timeline boundary ${Name}; experiment 1 uses T0-T5."
  }
  if ($expectedNames -notcontains $Name) {
    return
  }
  if ([double]::IsNaN($ElapsedMilliseconds) -or [double]::IsInfinity($ElapsedMilliseconds)) {
    throw "$Name elapsed_ms must be a finite number."
  }

  $points = @($script:Timeline | Where-Object { $expectedNames -contains $_.name })
  if ($points.Count -ge $expectedNames.Count) {
    throw "Cannot add ${Name}: T0-T5 are already complete."
  }
  $expectedNext = $expectedNames[$points.Count]
  if ($Name -ne $expectedNext) {
    throw "Timeline order violation: expected $expectedNext, got $Name."
  }
  if ($points.Count -gt 0) {
    $previous = $points[-1]
    if ($ElapsedMilliseconds -lt ([double]$previous.elapsed_ms)) {
      throw "Timeline monotonicity violation: $Name elapsed_ms is earlier than $($previous.name)."
    }
  }
}

function Add-Timeline {
  param(
    [string]$Name,
    [string]$Description,
    [hashtable]$Data = @{},
    [Nullable[datetime]]$TimestampUtc = $null,
    [Nullable[double]]$ElapsedMilliseconds = $null
  )

  # A Nullable[T] that receives a value is boxed as T in PowerShell, so .Value
  # cannot be used (StrictMode on Windows PowerShell 5.1 fails immediately).
  $eventUtc = if ($null -eq $TimestampUtc) { (Get-Date).ToUniversalTime() } else { ([datetime]$TimestampUtc).ToUniversalTime() }
  $eventElapsedMs = if ($null -eq $ElapsedMilliseconds) { $script:MonotonicClock.Elapsed.TotalMilliseconds } else { [double]$ElapsedMilliseconds }
  Assert-TimelineEventCanBeAdded -Name $Name -ElapsedMilliseconds $eventElapsedMs
  $script:Timeline += [pscustomobject]@{
    name              = $Name
    description       = $Description
    timestamp         = $eventUtc.ToString("o")
    timestamp_unix_ms = ([DateTimeOffset]$eventUtc).ToUnixTimeMilliseconds()
    elapsed_ms        = [math]::Round($eventElapsedMs, 3)
    data              = $Data
  }
  Write-RunResultCsv
  Write-Host "[$Name] $Description"
}

function Add-CommandTiming {
  param(
    [string]$Name,
    [string]$File,
    [string[]]$Arguments,
    [string]$StartedAt,
    [string]$EndedAt,
    [double]$StartedElapsedMilliseconds,
    [double]$EndedElapsedMilliseconds,
    [double]$DurationMilliseconds,
    [int]$ExitCode,
    [string]$LogPath
  )

  $timing = [pscustomobject]@{
    name                  = $Name
    command               = "$File $($Arguments -join ' ')"
    started_at            = $StartedAt
    ended_at              = $EndedAt
    started_elapsed_ms    = [math]::Round($StartedElapsedMilliseconds, 3)
    ended_elapsed_ms      = [math]::Round($EndedElapsedMilliseconds, 3)
    duration_milliseconds = [math]::Round($DurationMilliseconds, 3)
    duration_seconds      = [math]::Round($DurationMilliseconds / 1000.0, 6)
    exit_code             = $ExitCode
    log_path              = $LogPath
  }
  $script:CommandTimings += $timing
  $script:LastNativeTiming = $timing

  ConvertTo-Json -InputObject @($script:CommandTimings) -Depth 8 |
    Set-Content -Encoding UTF8 -Path $script:CommandTimingsJsonPath
  $script:CommandTimings | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:CommandTimingsCsvPath
}

function New-ProvisioningDurationRow {
  param(
    [string]$Name,
    [string]$Description,
    [datetime]$StartedAt,
    [datetime]$EndedAt,
    [double]$DurationMilliseconds,
    [string]$Status
  )

  return [pscustomobject]@{
    name                  = $Name
    description           = $Description
    status                = $Status
    started_at            = $StartedAt.ToUniversalTime().ToString("o")
    ended_at              = $EndedAt.ToUniversalTime().ToString("o")
    duration_milliseconds = [math]::Round($DurationMilliseconds, 3)
    duration_seconds      = [math]::Round($DurationMilliseconds / 1000.0, 6)
  }
}

function Get-TimelineEntry {
  param([string]$Name)

  $entries = @($script:Timeline | Where-Object { $_.name -eq $Name })
  if ($entries.Count -eq 0) {
    return $null
  }
  return $entries[-1]
}

function Invoke-Native {
  param(
    [string]$File,
    [string[]]$Arguments,
    [string]$WorkingDirectory,
    [string]$LogPath,
    [string]$TimingName,
    # Text pushed into the child process stdin (used to feed a remote bash
    # script to ssh without hitting Windows argument quoting).
    [string]$StdinText = $null
  )

  Push-Location $WorkingDirectory
  $started = (Get-Date).ToUniversalTime()
  $startedElapsedMs = $script:MonotonicClock.Elapsed.TotalMilliseconds
  $commandClock = [System.Diagnostics.Stopwatch]::StartNew()
  $exitCode = -1
  $nativeProcessReturnedExitCode = $false
  try {
    # On Windows PowerShell 5.1, redirecting a native command's stderr while
    # $ErrorActionPreference is Stop promotes one stderr line to a
    # NativeCommandError and kills the script even when the command exits 0.
    # Lower it for the duration of the call and judge success by $LASTEXITCODE
    # only. ToString() turns the ErrorRecord back into the original stderr text.
    $ErrorActionPreference = "Continue"
    # Never confuse a launch failure with a stale exit code of a previous call.
    $global:LASTEXITCODE = $null
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
      if ([string]::IsNullOrEmpty($StdinText)) {
        & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Write-Host
      }
      else {
        $StdinText | & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Write-Host
      }
    }
    else {
      if ([string]::IsNullOrEmpty($StdinText)) {
        & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() } |
          Out-File -FilePath $LogPath -Encoding utf8
      }
      else {
        $StdinText | & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() } |
          Out-File -FilePath $LogPath -Encoding utf8
      }
    }
    if ($null -ne $global:LASTEXITCODE) {
      $exitCode = [int]$global:LASTEXITCODE
      $nativeProcessReturnedExitCode = $true
    }
  }
  finally {
    $ErrorActionPreference = "Stop"
    $commandClock.Stop()
    $endedElapsedMs = $script:MonotonicClock.Elapsed.TotalMilliseconds
    $ended = (Get-Date).ToUniversalTime()
    $durationMs = $commandClock.Elapsed.TotalMilliseconds
    if ($TimingName -eq "terraform apply" -and $nativeProcessReturnedExitCode) {
      # Only a real native process exit marks the run as a cleanup candidate, so
      # a local path or launch error never destroys an existing cluster.
      $script:ApplyAttempted = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($TimingName)) {
      Add-CommandTiming `
        -Name $TimingName `
        -File $File `
        -Arguments $Arguments `
        -StartedAt $started.ToString("o") `
        -EndedAt $ended.ToString("o") `
        -StartedElapsedMilliseconds $startedElapsedMs `
        -EndedElapsedMilliseconds $endedElapsedMs `
        -DurationMilliseconds $durationMs `
        -ExitCode $exitCode `
        -LogPath $LogPath
    }
    Pop-Location
  }

  if ($exitCode -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($LogPath) -and (Test-Path -LiteralPath $LogPath)) {
      Get-Content -LiteralPath $LogPath -Tail 80 | Write-Host
    }
    throw "Command failed (exit $exitCode): $File $($Arguments -join ' ')"
  }
}

function Get-TfVarString {
  param(
    [string]$Path,
    [string]$Name
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $pattern = "^\s*$([regex]::Escape($Name))\s*=\s*`"([^`"]+)`""
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $pattern) {
      return $Matches[1]
    }
  }
  return $null
}

function Get-TfVarScalar {
  param(
    [string]$Path,
    [string]$Name
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $pattern = "^\s*$([regex]::Escape($Name))\s*=\s*(.+?)\s*(#.*)?$"
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $pattern) {
      $value = $Matches[1].Trim()
      if ($value.StartsWith('"') -and $value.EndsWith('"')) {
        return $value.Substring(1, $value.Length - 2)
      }
      return $value
    }
  }
  return $null
}

function Resolve-WorkspacePath {
  param(
    [string]$Path,
    [string]$BasePath
  )
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return (Resolve-Path -LiteralPath $Path).Path
  }
  return (Resolve-Path -LiteralPath (Join-Path $BasePath $Path)).Path
}

function Join-WorkspacePath {
  param(
    [string]$Path,
    [string]$BasePath
  )
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    $Path
  }
  else {
    Join-Path $BasePath $Path
  }
  return [System.IO.Path]::GetFullPath($candidate)
}

function Get-TerraformOutputRaw {
  param(
    [string]$TfDirFull,
    [string]$Name
  )
  $output = @(& terraform -chdir="$TfDirFull" output -raw $Name)
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read terraform output '$Name'."
  }
  return ([string]($output | Out-String)).Trim()
}

function Get-TerraformOutputRawOptional {
  param(
    [string]$TfDirFull,
    [string]$Name
  )

  $output = @()
  $exitCode = -1
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& terraform -chdir="$TfDirFull" output -raw $Name 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = "Stop"
  }
  if ($exitCode -ne 0) {
    return $null
  }
  return ([string]($output | Out-String)).Trim()
}

function Select-ExperimentTerraformWorkspace {
  param(
    [string]$TfDirFull,
    [string]$Workspace,
    [bool]$CreateIfMissing
  )

  $raw = @(& terraform -chdir="$TfDirFull" workspace list)
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to list Terraform workspaces in $TfDirFull."
  }
  $names = @($raw | ForEach-Object { ([string]$_ -replace '^\s*\*?\s*', '').Trim() } | Where-Object { $_ })
  if ($names -contains $Workspace) {
    & terraform -chdir="$TfDirFull" workspace select $Workspace | Out-Null
  }
  elseif ($CreateIfMissing) {
    & terraform -chdir="$TfDirFull" workspace new $Workspace | Out-Null
  }
  else {
    throw "Terraform workspace '$Workspace' does not exist in $TfDirFull."
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to select Terraform workspace '$Workspace'."
  }
  $selected = [string]((& terraform -chdir="$TfDirFull" workspace show) | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $selected -ne $Workspace) {
    throw "Terraform workspace selection mismatch: expected '$Workspace', found '$selected'."
  }
}
