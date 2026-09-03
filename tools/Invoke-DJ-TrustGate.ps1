param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel",
    [double]$ObjectiveAbsoluteTolerance = 1e-6,
    [double]$ObjectiveRelativeTolerance = 1e-9
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Fail {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

function Get-SummaryValue {
    param(
        [string[]]$Lines,
        [string]$Label
    )

    foreach ($line in $Lines) {
        if ($line -match ("^\s*" + [regex]::Escape($Label) + "\s*:\s*(.+?)\s*$")) {
            return $Matches[1].Trim()
        }
    }
    return ""
}

function Get-ClaimedStatus {
    param([string]$CurrentStatus)

    switch ($CurrentStatus) {
        "PROVEN_OPTIMAL" { return "CLAIMED_PROVEN_OPTIMAL" }
        "CURRENT_SOLVER_BEST" { return "CLAIMED_SOLVER_BEST" }
        "FEASIBLE_SOLUTION" { return "CLAIMED_FEASIBLE_SOLUTION" }
        "OBJECTIVE_VALUE_ONLY" { return "UNVERIFIED_OBJECTIVE_VALUE" }
        "UNKNOWN" { return "UNKNOWN" }
        default { return "UNVERIFIED_" + $CurrentStatus }
    }
}

if (-not (Test-Path -LiteralPath $BenchmarkRepo -PathType Container)) {
    Fail "Benchmark repository not found: $BenchmarkRepo"
}

if (-not (Test-Path -LiteralPath $ModelRepo -PathType Container)) {
    Fail "LotSizingDataModel repository not found: $ModelRepo"
}

$checkerProject = Join-Path $ModelRepo "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"
if (-not (Test-Path -LiteralPath $checkerProject -PathType Leaf)) {
    Fail "Checker CLI project not found: $checkerProject"
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnet) {
    Fail "dotnet was not found in PATH."
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\DJ2000"
$consolidated = Join-Path $familyRoot "metadata\DJ-REFERENCE-RESULTS-CONSOLIDATED.csv"
if (-not (Test-Path -LiteralPath $consolidated -PathType Leaf)) {
    Fail "Missing v0.2.4 consolidated result catalogue: $consolidated"
}

Write-Step "Building LotSizingDataModel.Checker.Cli"
& dotnet build $checkerProject -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    Fail "Checker build failed with exit code $LASTEXITCODE"
}

$reportsRoot = Join-Path $familyRoot "checker-reports"
New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null

$rows = Import-Csv -LiteralPath $consolidated
$gateRows = New-Object System.Collections.Generic.List[object]
$phaseResults = @{}

Write-Step "Running full non-destructive checker campaigns"

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $inputDir = Join-Path $familyRoot ($phase + "\instances-with-reference")
    $outputDir = Join-Path $reportsRoot $phase

    if (-not (Test-Path -LiteralPath $inputDir -PathType Container)) {
        Fail "Missing phase input directory: $inputDir"
    }

    if (Test-Path -LiteralPath $outputDir) {
        Remove-Item -LiteralPath $outputDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    Write-Host ""
    Write-Host ("Checking " + $phase + "...")

    $arguments = @(
        "run",
        "--project", $checkerProject,
        "-c", "Release",
        "--no-build",
        "--",
        $inputDir,
        "--level", "full",
        "--output", $outputDir,
        "--no-update-known-result",
        "--no-promote-known-result",
        "--no-progress",
        "--objective-absolute-tolerance", $ObjectiveAbsoluteTolerance.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--objective-relative-tolerance", $ObjectiveRelativeTolerance.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    )

    $consoleLines = @(& dotnet @arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE

    $logPath = Join-Path $outputDir "checker-console.log"
    [System.IO.File]::WriteAllLines(
        $logPath,
        $consoleLines,
        (New-Object System.Text.UTF8Encoding($false))
    )

    foreach ($line in $consoleLines) {
        Write-Host $line
    }

    if ($exitCode -ge 2) {
        Fail ("Checker execution failed for " + $phase + " with exit code " + $exitCode)
    }

    $candidatesText = Get-SummaryValue -Lines $consoleLines -Label "Candidates"
    $validText = Get-SummaryValue -Lines $consoleLines -Label "Valid"
    $invalidText = Get-SummaryValue -Lines $consoleLines -Label "Invalid"
    $overall = Get-SummaryValue -Lines $consoleLines -Label "Overall"

    $candidates = 0
    $valid = 0
    $invalid = 0
    [void][int]::TryParse($candidatesText, [ref]$candidates)
    [void][int]::TryParse($validText, [ref]$valid)
    [void][int]::TryParse($invalidText, [ref]$invalid)

    $phaseCanPromote = ($exitCode -eq 0 -and $invalid -eq 0 -and $candidates -gt 0)

    $phaseResults[$phase] = [pscustomobject]@{
        Phase = $phase
        ExitCode = $exitCode
        Candidates = $candidates
        Valid = $valid
        Invalid = $invalid
        Overall = $overall
        CanPromote = $phaseCanPromote
        ReportDirectory = $outputDir
    }

    $phaseRows = @($rows | Where-Object { $_.phase -eq $phase })
    foreach ($r in $phaseRows) {
        $hasObjective = -not [string]::IsNullOrWhiteSpace($r.current_local_objective)
        $claimed = Get-ClaimedStatus -CurrentStatus $r.current_local_status
        $trust = $claimed
        $gateReason = "Not independently verified."

        if (-not $hasObjective) {
            $trust = "UNKNOWN"
            $gateReason = "No local objective value."
        }
        elseif ($phaseCanPromote) {
            if ($r.current_local_status -eq "PROVEN_OPTIMAL") {
                $trust = "VERIFIED_PROVEN_OPTIMAL"
                $gateReason = "All selected candidates in the phase passed the full checker campaign."
            }
            elseif ($r.current_local_status -eq "CURRENT_SOLVER_BEST") {
                $trust = "VERIFIED_FEASIBLE_REFERENCE"
                $gateReason = "All selected candidates in the phase passed the full checker campaign."
            }
            elseif ($r.current_local_status -eq "FEASIBLE_SOLUTION") {
                $trust = "VERIFIED_FEASIBLE_REFERENCE"
                $gateReason = "All selected candidates in the phase passed the full checker campaign."
            }
            else {
                $trust = "VERIFIED_OBJECTIVE_REFERENCE"
                $gateReason = "Checker campaign passed; optimality is not claimed."
            }
        }
        elseif ($candidates -eq 0) {
            $gateReason = "No checker candidate was available for this phase."
        }
        elseif ($invalid -gt 0) {
            $gateReason = "At least one candidate in this phase is invalid; no automatic promotion is allowed."
        }

        $gateRows.Add([pscustomobject]@{
            phase = $phase
            canonical_id = $r.canonical_id
            objective = $r.current_local_objective
            previous_claim = $r.current_local_status
            trust_status = $trust
            solution_available = $r.complete_solution_available
            checker_phase_candidates = $candidates
            checker_phase_valid = $valid
            checker_phase_invalid = $invalid
            checker_phase_overall = $overall
            automatic_promotion_allowed = $phaseCanPromote
            trust_reason = $gateReason
            report_directory = $outputDir
        })
    }
}

$gateCsv = Join-Path $familyRoot "metadata\DJ-TRUST-GATE.csv"
$gateRows | Export-Csv -LiteralPath $gateCsv -NoTypeInformation -Encoding UTF8

$phaseCsv = Join-Path $familyRoot "metadata\DJ-CHECKER-PHASE-SUMMARY.csv"
$phaseResults.Values |
    Sort-Object Phase |
    Export-Csv -LiteralPath $phaseCsv -NoTypeInformation -Encoding UTF8

Write-Step "Generating trust-gated GitHub pages"

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $phaseRoot = Join-Path $familyRoot $phase
    $phaseRows = @($gateRows | Where-Object { $_.phase -eq $phase } | Sort-Object canonical_id)
    $pr = $phaseResults[$phase]

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Dellaert-Jeunet - $phase")
    $lines.Add("")
    $lines.Add("> Result status on this page is controlled by `LotSizingDataModel.Checker`.")
    $lines.Add("")
    $lines.Add("## Checker campaign")
    $lines.Add("")
    $lines.Add("| Candidates | Valid | Invalid | Overall | Automatic promotion |")
    $lines.Add("|---:|---:|---:|---|---|")
    $promoteText = "NO"
    if ($pr.CanPromote) { $promoteText = "YES" }
    $lines.Add("| $($pr.Candidates) | $($pr.Valid) | $($pr.Invalid) | **$($pr.Overall)** | **$promoteText** |")
    $lines.Add("")
    $lines.Add("## Instances")
    $lines.Add("")
    $lines.Add("| Instance | Objective | Trust status | Solution |")
    $lines.Add("|---|---:|---|---|")

    foreach ($r in $phaseRows) {
        $obj = $r.objective
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = "unknown" }
        $solution = "No"
        if ($r.solution_available -eq "True") { $solution = "Yes" }

        $lines.Add("| ``$($r.canonical_id)`` | $obj | **$($r.trust_status)** | $solution |")
    }

    [System.IO.File]::WriteAllLines(
        (Join-Path $phaseRoot "README.md"),
        $lines,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

$verifiedOptimal = @($gateRows | Where-Object { $_.trust_status -eq "VERIFIED_PROVEN_OPTIMAL" }).Count
$claimedOptimal = @($gateRows | Where-Object { $_.trust_status -eq "CLAIMED_PROVEN_OPTIMAL" }).Count
$verifiedOther = @($gateRows | Where-Object { $_.trust_status -like "VERIFIED_*" -and $_.trust_status -ne "VERIFIED_PROVEN_OPTIMAL" }).Count
$unknown = @($gateRows | Where-Object { $_.trust_status -eq "UNKNOWN" }).Count

$familyLines = New-Object System.Collections.Generic.List[string]
$familyLines.Add("# Dellaert-Jeunet benchmark")
$familyLines.Add("")
$familyLines.Add("> **Trust-gated benchmark:** a result is called verified only after independent checking by `LotSizingDataModel.Checker`.")
$familyLines.Add("")
$familyLines.Add("## Verification status")
$familyLines.Add("")
$familyLines.Add("| Status | Count |")
$familyLines.Add("|---|---:|")
$familyLines.Add("| Verified proven optimal | **$verifiedOptimal** |")
$familyLines.Add("| Claimed optimal, not promoted | **$claimedOptimal** |")
$familyLines.Add("| Other verified references | **$verifiedOther** |")
$familyLines.Add("| Unknown objective | **$unknown** |")
$familyLines.Add("")
$familyLines.Add("## Phase checker summary")
$familyLines.Add("")
$familyLines.Add("| Phase | Candidates | Valid | Invalid | Overall | Auto-promote |")
$familyLines.Add("|---|---:|---:|---:|---|---|")
foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $pr = $phaseResults[$phase]
    $promoteText = "NO"
    if ($pr.CanPromote) { $promoteText = "YES" }
    $familyLines.Add("| [$phase](./$phase/) | $($pr.Candidates) | $($pr.Valid) | $($pr.Invalid) | **$($pr.Overall)** | **$promoteText** |")
}
$familyLines.Add("")
$familyLines.Add("Any phase containing an invalid candidate is blocked from automatic promotion until the offending result is identified and corrected.")
$familyLines.Add("")
$familyLines.Add("Detailed checker output is stored under [`checker-reports/`](./checker-reports/).")

[System.IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $familyLines,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "Trust gate result"
Write-Host "VERIFIED_PROVEN_OPTIMAL: $verifiedOptimal"
Write-Host "CLAIMED_PROVEN_OPTIMAL: $claimedOptimal"
Write-Host "OTHER VERIFIED: $verifiedOther"
Write-Host "UNKNOWN: $unknown"
Write-Host ""
foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $pr = $phaseResults[$phase]
    Write-Host ($phase + ": candidates=" + $pr.Candidates + " valid=" + $pr.Valid + " invalid=" + $pr.Invalid + " overall=" + $pr.Overall + " promote=" + $pr.CanPromote)
}
