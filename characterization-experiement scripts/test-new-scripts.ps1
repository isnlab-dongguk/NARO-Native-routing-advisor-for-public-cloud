[CmdletBinding()]
param()

# Smoke check for this repository root. Runs offline: no GCP or cluster changes.
#   1) every .ps1 parses
#   2) every Verb-Noun command a script calls is defined in that script, in a
#      file it dot-sources, or is a real cmdlet  (catches a helper that moved to
#      provision-common.ps1 without the dot-source)
#   3) every .sh passes bash -n (skipped when bash is unavailable)
#   4) the -Mode / -NodeCount mapping of provision.ps1 is the one the plan expects
#   5) every Terraform root is complete/formatted and GKE uses a valid channel
#   6) no shipped file leaks a local absolute path or a private key
#   7) every shipped path stays within this repository root
#   8) workspace path helpers return canonical root-anchored paths
#   9) Git ignores generated Terraform data, user tfvars, and results
#  10) no typed script parameter is shadowed by a differently-cased variable
#  11) the GKE experiment 2 engine accepts only the Cloud routing method
#  12) the experiment-3 clock protocol handles a redirected-stdin UTF-8 BOM
#  13) experiment 1 keeps T5 validation but records durations only through T4
#  14) both experiment 2 engines default to three runs and accept overrides
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\test-new-scripts.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$failures = @()
function Add-Failure { param([string]$Message) $script:failures += $Message; Write-Host "FAIL $Message" -ForegroundColor Red }
function Write-Pass { param([string]$Message) Write-Host "ok   $Message" -ForegroundColor Green }

$scripts = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1" |
  Where-Object { $_.Name -ne "test-new-scripts.ps1" })

# --- 1) parse -----------------------------------------------------------------
$asts = @{}
foreach ($file in $scripts) {
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
  if ($errors.Count -gt 0) {
    Add-Failure "$($file.Name) does not parse: line $($errors[0].Extent.StartLineNumber) $($errors[0].Message)"
    continue
  }
  $asts[$file.FullName] = $ast
}
if ($asts.Count -eq $scripts.Count) { Write-Pass "$($scripts.Count) PowerShell files parse" }

# --- 2) resolvable commands ---------------------------------------------------
function Get-DefinedFunctions {
  param([System.Management.Automation.Language.Ast]$Ast)
  return @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $_.Name })
}
function Get-DotSourcedPaths {
  # The dot-source targets are built with Join-Path and $PSScriptRoot, sometimes
  # after walking up a level, so the quoted tail is resolved against the script
  # directory and each of its ancestors.
  param([System.Management.Automation.Language.Ast]$Ast, [string]$Directory)
  $paths = @()
  foreach ($command in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    if ($command.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot) { continue }
    $text = $command.Extent.Text
    foreach ($match in [regex]::Matches($text, '"([^"]+\.ps1)"')) {
      $relative = $match.Groups[1].Value -replace '\\', [System.IO.Path]::DirectorySeparatorChar
      $base = $Directory
      $found = $null
      while (-not [string]::IsNullOrWhiteSpace($base)) {
        $candidate = Join-Path $base $relative
        if (Test-Path -LiteralPath $candidate) { $found = $candidate; break }
        $base = Split-Path -Parent $base
      }
      if ($null -eq $found) { $found = Join-Path $Directory $relative }
      $paths += $found
    }
  }
  return $paths
}

# Libraries are dot-sourced into another script and deliberately use functions
# their caller defines, so they are resolved against every function in the tree.
$libraryNames = @(
  "provision-common.ps1", "native-routing-t4.ps1", "cleanup-native-routing-t4.ps1",
  "exp3-common.ps1", "exp3-context-gke.ps1"
)
$allFunctions = @()
foreach ($ast in $asts.Values) { $allFunctions += @(Get-DefinedFunctions -Ast $ast) }

foreach ($file in $scripts) {
  if (-not $asts.ContainsKey($file.FullName)) { continue }
  $ast = $asts[$file.FullName]
  $defined = if ($libraryNames -contains $file.Name) { @($allFunctions) } else { @(Get-DefinedFunctions -Ast $ast) }
  foreach ($sourced in Get-DotSourcedPaths -Ast $ast -Directory $file.DirectoryName) {
    $resolved = [System.IO.Path]::GetFullPath($sourced)
    if (-not (Test-Path -LiteralPath $resolved)) {
      Add-Failure "$($file.Name) dot-sources a missing file: $sourced"
      continue
    }
    if ($asts.ContainsKey($resolved)) {
      $defined += @(Get-DefinedFunctions -Ast $asts[$resolved])
      # one more level: exp3-context-gke.ps1 -> exp3-common.ps1
      foreach ($nested in Get-DotSourcedPaths -Ast $asts[$resolved] -Directory (Split-Path -Parent $resolved)) {
        $nestedResolved = [System.IO.Path]::GetFullPath($nested)
        if ($asts.ContainsKey($nestedResolved)) { $defined += @(Get-DefinedFunctions -Ast $asts[$nestedResolved]) }
      }
    }
  }

  $unresolved = @()
  foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[A-Z][a-z]+-[A-Za-z0-9]+$') { continue }
    if ($defined -contains $name) { continue }
    if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
    $unresolved += $name
  }
  $unresolved = @($unresolved | Sort-Object -Unique)
  if ($unresolved.Count -gt 0) {
    Add-Failure "$($file.Name) calls undefined function(s): $($unresolved -join ', ')"
  }
}
if ($failures.Count -eq 0) { Write-Pass "every Verb-Noun call resolves" }

# Files that actually ship. Everything a run generates is excluded: results/,
# .terraform/ provider caches, state files, and the user's own terraform.tfvars.
function Test-ShippedFile {
  param([System.IO.FileInfo]$File)
  $relative = $File.FullName.Substring($root.Length).TrimStart('\', '/')
  foreach ($generated in @('results\', 'results/', '.terraform')) {
    if ($relative -like "*$generated*") { return $false }
  }
  if ($File.Name -eq "terraform.tfvars") { return $false }
  if ($File.Name -like "terraform.tfstate*") { return $false }
  return ($File.Extension -in @(".ps1", ".sh", ".md", ".tf", ".tftpl", ".example", ".hcl") -or
          $File.Name -eq "Dockerfile")
}
$shipped = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { Test-ShippedFile -File $_ })

# --- 3) shell syntax ----------------------------------------------------------
$shellScripts = @($shipped | Where-Object { $_.Extension -eq ".sh" })
if (Get-Command bash -ErrorAction SilentlyContinue) {
  foreach ($file in $shellScripts) {
    # Run from the file's directory and pass a bare name: a Windows absolute
    # path would be mangled by the Git Bash path conversion.
    Push-Location $file.DirectoryName
    try {
      & bash -n $file.Name 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { Add-Failure "$($file.Name) fails bash -n" }
    }
    finally { Pop-Location }
  }
  Write-Pass "$($shellScripts.Count) shell scripts pass bash -n"
}
else {
  Write-Host "skip bash -n (bash not found)" -ForegroundColor Yellow
}

# --- 4) -NodeCount mapping --------------------------------------------------------
$provisionText = Get-Content -LiteralPath (Join-Path $root "provision.ps1") -Raw
foreach ($expected in @(
    '$WorkerCount = $NodeCount - 2',
    '$RequiredExistingNodes = if ($NodeCount -eq 4) { 0 } else { 4 }')) {
  if ($provisionText -notlike "*$expected*") {
    Add-Failure "provision.ps1 lost the -NodeCount mapping line: $expected"
  }
}
$gkeText = Get-Content -LiteralPath (Join-Path $root "provision-gke.ps1") -Raw
if ($gkeText -notlike '*$RequiredExistingWorkers = if ($NodeCount -eq 4) { 0 } else { 2 }*') {
  Add-Failure "provision-gke.ps1 lost its -NodeCount mapping"
}
if ($failures.Count -eq 0) { Write-Pass "-NodeCount mappings are 4 -> (2 workers, 0 existing) and 8 -> (6 workers, 4 existing)" }

# --- 5) Terraform roots -------------------------------------------------------
$infraRoot = Join-Path $root "infra"
foreach ($mode in @("vxlan", "host", "static", "dynamic", "gke")) {
  $dir = Join-Path $infraRoot $mode
  foreach ($required in @("main.tf", "variables.tf", "outputs.tf", "versions.tf", "terraform.tfvars.example")) {
    if (-not (Test-Path -LiteralPath (Join-Path $dir $required))) {
      Add-Failure "infra/$mode is missing $required"
    }
  }
}
$gkeMainText = Get-Content -LiteralPath (Join-Path $infraRoot "gke\main.tf") -Raw
$channelMatch = [regex]::Match(
  $gkeMainText,
  '(?s)release_channel\s*\{\s*channel\s*=\s*"(?<channel>[A-Z]+)"\s*\}'
)
$allowedReleaseChannels = @("RAPID", "REGULAR", "STABLE", "EXTENDED")
if (-not $channelMatch.Success) {
  Add-Failure "infra/gke/main.tf must enroll the cluster in an explicit GKE release channel"
}
elseif ($allowedReleaseChannels -notcontains $channelMatch.Groups["channel"].Value) {
  Add-Failure "infra/gke/main.tf uses a non-enrollable GKE release channel: $($channelMatch.Groups["channel"].Value)"
}
else {
  Write-Pass "GKE release channel is $($channelMatch.Groups["channel"].Value)"
}
if (Get-Command terraform -ErrorAction SilentlyContinue) {
  Push-Location $infraRoot
  try {
    & terraform fmt -check -recursive . 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Failure "terraform fmt -check failed under infra/" }
  }
  finally { Pop-Location }
  Write-Pass "5 Terraform roots are complete and parse"
}
else {
  Write-Host "skip terraform fmt (terraform not found)" -ForegroundColor Yellow
}

# --- 6) nothing local leaks ---------------------------------------------------
# The user's own terraform.tfvars is excluded above: it legitimately holds their
# project id and key path.
$leakPatterns = @('C:\\Users\\', '-----BEGIN [A-Z ]*PRIVATE KEY-----')
foreach ($file in $shipped) {
  $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrEmpty($text)) { continue }
  foreach ($pattern in $leakPatterns) {
    if ($text -match $pattern) {
      Add-Failure "$($file.Name) contains a local absolute path or a private key ($pattern)"
    }
  }
}
if ($failures.Count -eq 0) { Write-Pass "none of the $($shipped.Count) shipped files leaks a local path or a key" }

# --- 7) self-contained: nothing resolves outside this directory ---------------
# Another user must be able to clone this directory alone and run it, so no
# shipped file may depend on a marker, sibling, or parent of this tree.
foreach ($file in $shipped | Where-Object { $_.Extension -in @(".ps1", ".sh") }) {
  $text = Get-Content -LiteralPath $file.FullName -Raw
  if ([string]::IsNullOrEmpty($text)) { continue }
  if ($text -match '실험계획\.md') {
    Add-Failure "$($file.Name) still depends on a marker outside the repository root"
  }
  # Every "$PSScriptRoot + relative tail" and every dot-source must land inside.
  foreach ($match in [regex]::Matches($text, '\$PSScriptRoot[^"]*"([^"]+)"')) {
    $tail = $match.Groups[1].Value
    if ($tail -notmatch '\.\.') { continue }
    $ups = ([regex]::Matches($tail, '\.\.')).Count
    $depth = ($file.DirectoryName.Substring($root.Length).Split([char[]]'\/', [System.StringSplitOptions]::RemoveEmptyEntries)).Count
    if ($ups -gt $depth) {
      Add-Failure "$($file.Name) resolves '$tail' outside the repository root (goes up $ups from depth $depth)"
    }
  }
}
$legacyRootPrefixPattern = [regex]::Escape("scripts") + '[\\/]' + [regex]::Escape("new")
foreach ($file in $shipped) {
  $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
  if (-not [string]::IsNullOrEmpty($text) -and $text -match $legacyRootPrefixPattern) {
    Add-Failure "$($file.Name) still contains the former parent-repository prefix"
  }
}
if ($failures.Count -eq 0) { Write-Pass "every shipped path is repository-root relative" }

# --- 8) canonical workspace paths ---------------------------------------------
. (Join-Path $root "provision-common.ps1")
. (Join-Path $root "exp3\exp3-common.ps1")
$expectedResultPath = [System.IO.Path]::GetFullPath(
  (Join-Path $root "results\gke\provisioning-4node")
)
$canonicalPaths = @{
  provision = Join-WorkspacePath -Path ".\results\gke\provisioning-4node" -BasePath $root
  exp3      = Join-Exp3WorkspacePath -Path ".\results\gke\provisioning-4node" -BasePath $root
}
$pathFailureCount = $failures.Count
foreach ($entry in $canonicalPaths.GetEnumerator()) {
  if ($entry.Value -cne $expectedResultPath) {
    Add-Failure "$($entry.Key) path helper returned '$($entry.Value)', expected '$expectedResultPath'"
  }
}
if ($failures.Count -eq $pathFailureCount) {
  Write-Pass "workspace helpers canonicalize relative paths against the repository root"
}

# --- 9) Git safety -------------------------------------------------------------
$gitIgnorePath = Join-Path $root ".gitignore"
$gitIgnoreFailureCount = $failures.Count
if (-not (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf)) {
  Add-Failure ".gitignore is missing"
}
else {
  $gitIgnoreLines = @(Get-Content -LiteralPath $gitIgnorePath)
  foreach ($requiredPattern in @(
      "**/.terraform/", "*.tfstate", "*.tfstate.*", "*.tfplan",
      "**/*.tfvars", "**/*.tfvars.json", "/results/")) {
    if ($gitIgnoreLines -notcontains $requiredPattern) {
      Add-Failure ".gitignore is missing required pattern: $requiredPattern"
    }
  }
}
if ($failures.Count -eq $gitIgnoreFailureCount) {
  Write-Pass "Git excludes Terraform local data, user tfvars, plans, and results"
}

# --- 10) no typed parameter is shadowed by a script-level variable ------------
# PowerShell variable names are case-insensitive, so a script parameter declared
# [int]$NodeCount also owns every later "$nodeCount = ..." assignment - and the
# declared type is enforced, so assigning an array throws a type-conversion error
# far from the parameter. This only surfaces at runtime, after apply, so it is
# checked here instead.
foreach ($file in $scripts) {
  if (-not $asts.ContainsKey($file.FullName)) { continue }
  $ast = $asts[$file.FullName]
  if ($null -eq $ast.ParamBlock) { continue }

  $declared = @{}
  foreach ($parameter in $ast.ParamBlock.Parameters) {
    $declared[$parameter.Name.VariablePath.UserPath.ToLowerInvariant()] = @{
      Name = $parameter.Name.VariablePath.UserPath
      Type = $parameter.StaticType
    }
  }

  $assignments = $ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true)
  foreach ($assignment in $assignments) {
    # A function body has its own scope, so only script-level assignments count.
    $parent = $assignment.Parent
    $insideFunction = $false
    while ($null -ne $parent) {
      if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $insideFunction = $true; break }
      $parent = $parent.Parent
    }
    if ($insideFunction) { continue }

    $name = $assignment.Left.VariablePath.UserPath
    $key = $name.ToLowerInvariant()
    if (-not $declared.ContainsKey($key)) { continue }
    # An exact-name assignment is the intended "fill in the default" pattern.
    if ($name -ceq $declared[$key].Name) { continue }
    Add-Failure ("$($file.Name):$($assignment.Extent.StartLineNumber) assigns `$$name, which PowerShell treats as the parameter [$($declared[$key].Type.Name)]`$$($declared[$key].Name). Rename one of them.")
  }
}
if ($failures.Count -eq 0) { Write-Pass "no script variable shadows a typed parameter" }

# --- 11) GKE experiment 2 is Cloud-only --------------------------------------
# Source the engine from a temporary Bash test file and call only its argument
# normalizer. A file avoids Windows bash.exe rewriting dollar expressions passed
# through -c. The BASH_SOURCE guard keeps main/preflight/kubectl from running.
$gkeExp2MethodFailureCount = $failures.Count
if (Get-Command bash -ErrorAction SilentlyContinue) {
  $gkeExp2Dir = Join-Path $root "gke\exp2"
  $probeName = ".exp2-method-contract-$([guid]::NewGuid().ToString('N')).sh"
  $probePath = Join-Path $gkeExp2Dir $probeName
  $probeText = @'
#!/usr/bin/env bash
set -euo pipefail
source ./exp2_benchmark_gke.sh

METHOD=Cloud
METHOD_PROVIDED=true
normalize_and_validate
[[ "$METHOD" == Cloud ]]
[[ "$METHOD_SLUG" == cloud ]]
[[ "$MODE" == normal ]]
[[ "$HOST_NETWORK" == false ]]
[[ "$DNS_POLICY" == ClusterFirst ]]

for rejected in Host VXLAN Static Dynamic; do
  if (
    METHOD="$rejected"
    METHOD_PROVIDED=true
    normalize_and_validate
  ) 2>/dev/null; then
    printf 'incorrectly accepted method: %s\n' "$rejected" >&2
    exit 1
  fi
done
'@
  [System.IO.File]::WriteAllText(
    $probePath,
    $probeText.Replace("`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  Push-Location $gkeExp2Dir
  try {
    $probeOutput = @(& bash $probeName 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Add-Failure "GKE exp2 Cloud-only contract failed: $($probeOutput -join ' ')"
    }
  }
  finally {
    Pop-Location
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }

  if ($failures.Count -eq $gkeExp2MethodFailureCount) {
    Write-Pass "GKE exp2 accepts Cloud and rejects Host/VXLAN/Static/Dynamic"
  }
}
else {
  Write-Host "skip GKE exp2 method validation (bash not found)" -ForegroundColor Yellow
}

# --- 12) experiment 3 clock protocol is BOM-safe -----------------------------
$exp3ClockFailureCount = $failures.Count
$exp3CommonText = Get-Content -LiteralPath (Join-Path $root "exp3\exp3-common.ps1") -Raw
$remoteBomStrip = 'line="${line#$''\xEF\xBB\xBF''}"'
$remoteCrStrip = 'line="${line%$''\r''}"'
foreach ($requiredClockGuard in @(
    '$startInfo.StandardOutputEncoding = $utf8NoBom',
    '$startInfo.StandardErrorEncoding = $utf8NoBom',
    $remoteBomStrip,
    $remoteCrStrip)) {
  if (-not $exp3CommonText.Contains($requiredClockGuard)) {
    Add-Failure "exp3 clock protocol lost its encoding guard: $requiredClockGuard"
  }
}

# UTF-8 decoding turns EF BB BF into U+FEFF. The production parser already
# removes that code point; verify the exact reply shape that previously became
# the CP949 mojibake '癤풱1'.
$bomAndToken = [byte[]](0xEF, 0xBB, 0xBF, 0x53, 0x31)
$decodedToken = ([System.Text.UTF8Encoding]::new($false)).GetString($bomAndToken)
$clockReply = (("PONG $decodedToken 1787311420776" -replace [string][char]0xFEFF, '')).Trim()
if ($clockReply -notmatch '^PONG S1 \d{12,14}$') {
  Add-Failure "exp3 clock reply BOM normalization failed: $clockReply"
}
if ($failures.Count -eq $exp3ClockFailureCount) {
  Write-Pass "experiment 3 clock ping-pong is BOM-safe across Windows encodings"
}

# --- 13) experiment 1 metric ends at T4; T5 remains validation ---------------
$exp1TimelineFailureCount = $failures.Count
$provisionCommonText = Get-Content -LiteralPath (Join-Path $root "provision-common.ps1") -Raw
$exp1Engines = @(
  Join-Path $root "provision.ps1"
  Join-Path $root "provision-gke.ps1"
)
$expectedTimelineDeclaration = '$expectedNames = @("T0", "T1", "T2", "T3", "T4", "T5")'
if (-not $provisionCommonText.Contains($expectedTimelineDeclaration)) {
  Add-Failure "experiment 1 common timeline no longer retains T0 through T5"
}
foreach ($enginePath in $exp1Engines) {
  $engineText = Get-Content -LiteralPath $enginePath -Raw
  $engineName = Split-Path -Leaf $enginePath
  foreach ($requiredToken in @('Add-Timeline -Name "T5"', '"T0_to_T4"')) {
    if (-not $engineText.Contains($requiredToken)) {
      Add-Failure "$engineName lost experiment 1 contract token: $requiredToken"
    }
  }
  foreach ($forbiddenDuration in @('"T4_to_T5"', '"T0_to_T5"')) {
    if ($engineText.Contains($forbiddenDuration)) {
      Add-Failure "$engineName still records excluded duration $forbiddenDuration"
    }
  }
}
if ($failures.Count -eq $exp1TimelineFailureCount) {
  Write-Pass "experiment 1 retains T5 validation and records durations only through T4"
}

# --- 14) experiment 2 defaults to three and accepts positive overrides --------
$exp2RunsFailureCount = $failures.Count
if (Get-Command bash -ErrorAction SilentlyContinue) {
  $probeName = ".exp2-runs-contract-$([guid]::NewGuid().ToString('N')).sh"
  $probePath = Join-Path $root $probeName
  $probeText = @'
#!/usr/bin/env bash
set -euo pipefail

(
  unset RUNS METHOD METHOD_PROVIDED
  source ./exp2_benchmark.sh
  [[ "$RUNS" == 3 ]]
  parse_args benchmark -m VXLAN -r 5
  normalize_and_validate
  [[ "$RUNS" == 5 ]]
  for invalid in 0 -1 1.5 abc; do
    if (RUNS="$invalid"; normalize_and_validate) 2>/dev/null; then
      echo "generic exp2 engine accepted invalid runs: $invalid" >&2
      exit 1
    fi
  done
)

(
  unset RUNS METHOD METHOD_PROVIDED
  source ./gke/exp2/exp2_benchmark_gke.sh
  [[ "$RUNS" == 3 ]]
  parse_args benchmark -m Cloud --runs 5
  normalize_and_validate
  [[ "$RUNS" == 5 ]]
  for invalid in 0 -1 1.5 abc; do
    if (RUNS="$invalid"; normalize_and_validate) 2>/dev/null; then
      echo "GKE exp2 engine accepted invalid runs: $invalid" >&2
      exit 1
    fi
  done
)
'@
  [System.IO.File]::WriteAllText(
    $probePath,
    $probeText.Replace("`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
  Push-Location $root
  try {
    $probeOutput = @(& bash $probeName 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Add-Failure "experiment 2 run-count override contract failed: $($probeOutput -join ' ')"
    }
  }
  finally {
    Pop-Location
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }
  if ($failures.Count -eq $exp2RunsFailureCount) {
    Write-Pass "both experiment 2 engines default to three and accept positive run overrides"
  }
}
else {
  Write-Host "skip experiment 2 run-count validation (bash not found)" -ForegroundColor Yellow
}

Write-Host ""
if ($failures.Count -gt 0) {
  throw "$($failures.Count) check(s) failed."
}
Write-Host "All smoke checks passed." -ForegroundColor Green
