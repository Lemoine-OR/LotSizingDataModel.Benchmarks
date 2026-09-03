param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Escape-Md {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace("|","\|")
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllLines(
        $Path,
        $Lines,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\DJ2000"
if (-not (Test-Path -LiteralPath $familyRoot -PathType Container)) {
    throw "DJ2000 benchmark directory not found."
}

$metaRoot = Join-Path $familyRoot "metadata"
$trustCsv = Join-Path $metaRoot "DJ-TRUST-GATE.csv"
$litCsv = Join-Path $metaRoot "DJ-LITERATURE-REFERENCE-CANDIDATES.csv"
$rejectedCsv = Join-Path $metaRoot "DJ-REJECTED-RESULTS.csv"

if (-not (Test-Path -LiteralPath $trustCsv -PathType Leaf)) {
    throw "DJ-TRUST-GATE.csv missing. Run v0.2.6 first."
}
if (-not (Test-Path -LiteralPath $litCsv -PathType Leaf)) {
    throw "DJ-LITERATURE-REFERENCE-CANDIDATES.csv missing. Run v0.2.8 first."
}

$trust = Import-Csv -LiteralPath $trustCsv
$literature = Import-Csv -LiteralPath $litCsv
$rejected = @()
if (Test-Path -LiteralPath $rejectedCsv -PathType Leaf) {
    $rejected = @(Import-Csv -LiteralPath $rejectedCsv)
}

Write-Step "Building final DJ reference catalogue"

$finalRows = New-Object System.Collections.Generic.List[object]

foreach ($r in $trust) {
    $lit = @($literature | Where-Object {
        $_.phase -eq $r.phase -and $_.candidate_canonical_id -eq $r.canonical_id
    } | Select-Object -First 1)

    $bad = @($rejected | Where-Object {
        $_.phase -eq $r.phase -and $_.canonical_id -eq $r.canonical_id
    } | Select-Object -First 1)

    $litObj = ""
    $litSource = ""
    $litStatus = ""
    if ($lit.Count -gt 0) {
        $litObj = $lit[0].objective
        $litSource = $lit[0].source
        $litStatus = $lit[0].source_status
    }

    $currentBestObjective = ""
    $currentBestStatus = $r.trust_status
    $sourceClass = "NONE"

    if ($r.trust_status -eq "VERIFIED_PROVEN_OPTIMAL") {
        $currentBestObjective = $r.objective
        $sourceClass = "VERIFIED_LOCAL_SOLUTION"
    }
    elseif ($r.trust_status -eq "VERIFIED_BEST_KNOWN") {
        $currentBestObjective = $r.objective
        $sourceClass = "VERIFIED_LOCAL_SOLUTION"
    }
    elseif ($r.trust_status -eq "REJECTED_BY_CHECKER") {
        if (-not [string]::IsNullOrWhiteSpace($litObj)) {
            $currentBestObjective = $litObj
            $currentBestStatus = "HISTORICAL_LITERATURE_VALUE_UNVERIFIED"
            $sourceClass = "LITERATURE_VALUE_ONLY"
        }
        else {
            $currentBestObjective = ""
            $currentBestStatus = "UNKNOWN"
            $sourceClass = "NONE"
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($r.objective) -and
            $r.trust_status -like "VERIFIED_*") {
        $currentBestObjective = $r.objective
        $sourceClass = "VERIFIED_LOCAL_REFERENCE"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($litObj)) {
        $currentBestObjective = $litObj
        $currentBestStatus = "HISTORICAL_LITERATURE_VALUE_UNVERIFIED"
        $sourceClass = "LITERATURE_VALUE_ONLY"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($r.objective)) {
        $currentBestObjective = $r.objective
        $currentBestStatus = "UNVERIFIED_LOCAL_VALUE"
        $sourceClass = "LOCAL_VALUE_ONLY"
    }
    else {
        $currentBestStatus = "UNKNOWN"
    }

    $finalRows.Add([pscustomobject]@{
        phase = $r.phase
        canonical_id = $r.canonical_id
        current_reference_objective = $currentBestObjective
        current_reference_status = $currentBestStatus
        source_class = $sourceClass
        local_objective = $r.objective
        local_trust_status = $r.trust_status
        literature_objective_2011 = $litObj
        literature_source = $litSource
        literature_status = $litStatus
        rejected_local_claim = $(if ($bad.Count -gt 0) { "True" } else { "False" })
        complete_solution_available = $r.solution_available
        checker_report_directory = $r.report_directory
    })
}

$finalCsv = Join-Path $metaRoot "DJ-FINAL-REFERENCE-CATALOG.csv"
$finalRows | Sort-Object phase,canonical_id |
    Export-Csv -LiteralPath $finalCsv -NoTypeInformation -Encoding UTF8

Write-Step "Generating per-instance result history"

$historyRoot = Join-Path $familyRoot "result-history"
Ensure-Directory $historyRoot

foreach ($row in $finalRows) {
    $instanceHistoryRoot = Join-Path $historyRoot ($row.phase + "\" + $row.canonical_id)
    Ensure-Directory $instanceHistoryRoot

    $history = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($row.literature_objective_2011)) {
        $history.Add([pscustomobject]@{
            chronology = "2011"
            source_type = "LITERATURE"
            source = $row.literature_source
            objective = $row.literature_objective_2011
            status = $row.literature_status
            verified_by_checker = "False"
            note = "Historical literature value. Exact mapping and newer 2014 BKS still require reconciliation."
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($row.local_objective)) {
        $localStatus = $row.local_trust_status
        $verified = "False"
        if ($localStatus -like "VERIFIED_*") { $verified = "True" }

        $history.Add([pscustomobject]@{
            chronology = "local"
            source_type = "LOCAL_XML"
            source = "LotSizingDataModel converted source copies"
            objective = $row.local_objective
            status = $localStatus
            verified_by_checker = $verified
            note = $(if ($localStatus -eq "REJECTED_BY_CHECKER") {
                "Preserved for traceability; must never be promoted without a new valid solution."
            } else {
                "Local KnownResult claim."
            })
        })
    }

    $historyCsv = Join-Path $instanceHistoryRoot "history.csv"
    $history | Export-Csv -LiteralPath $historyCsv -NoTypeInformation -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# " + $row.canonical_id)
    $lines.Add("")
    $lines.Add("| Field | Value |")
    $lines.Add("|---|---|")
    $lines.Add("| Phase | " + $row.phase + " |")
    $lines.Add("| Current reference objective | " + $(if ([string]::IsNullOrWhiteSpace($row.current_reference_objective)) { "unknown" } else { $row.current_reference_objective }) + " |")
    $lines.Add("| Current reference status | **" + $row.current_reference_status + "** |")
    $lines.Add("| Complete solution available | " + $row.complete_solution_available + " |")
    $lines.Add("")
    $lines.Add("Historical records are stored in `history.csv`.")

    Write-Utf8NoBom -Path (Join-Path $instanceHistoryRoot "README.md") -Lines $lines
}

Write-Step "Generating final GitHub pages"

$verifiedOpt = @($finalRows | Where-Object { $_.current_reference_status -eq "VERIFIED_PROVEN_OPTIMAL" }).Count
$verifiedBkv = @($finalRows | Where-Object { $_.current_reference_status -eq "VERIFIED_BEST_KNOWN" }).Count
$litOnly = @($finalRows | Where-Object { $_.source_class -eq "LITERATURE_VALUE_ONLY" }).Count
$unknown = @($finalRows | Where-Object { $_.current_reference_status -eq "UNKNOWN" }).Count
$rejectedCount = @($finalRows | Where-Object { $_.rejected_local_claim -eq "True" }).Count
$withSolution = @($finalRows | Where-Object { $_.complete_solution_available -eq "True" }).Count

$familyLines = New-Object System.Collections.Generic.List[string]
$familyLines.Add("# Dellaert-Jeunet benchmark")
$familyLines.Add("")
$familyLines.Add("> **176 canonical instances, three historical phases, trust-gated reference results.**")
$familyLines.Add("")
$familyLines.Add("## Current coverage")
$familyLines.Add("")
$familyLines.Add("| Metric | Count |")
$familyLines.Add("|---|---:|")
$familyLines.Add("| Canonical instances | **176 / 176** |")
$familyLines.Add("| Verified proven optimal | **$verifiedOpt** |")
$familyLines.Add("| Verified best-known | **$verifiedBkv** |")
$familyLines.Add("| Literature value only | **$litOnly** |")
$familyLines.Add("| Complete solution available | **$withSolution** |")
$familyLines.Add("| Rejected local claims | **$rejectedCount** |")
$familyLines.Add("| Unknown reference objective | **$unknown** |")
$familyLines.Add("")
$familyLines.Add("## Historical phases")
$familyLines.Add("")
$familyLines.Add("| Phase | Instances | Verified optimal | Literature only | Unknown |")
$familyLines.Add("|---|---:|---:|---:|---:|")

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $pr = @($finalRows | Where-Object { $_.phase -eq $phase })
    $po = @($pr | Where-Object { $_.current_reference_status -eq "VERIFIED_PROVEN_OPTIMAL" }).Count
    $pl = @($pr | Where-Object { $_.source_class -eq "LITERATURE_VALUE_ONLY" }).Count
    $pu = @($pr | Where-Object { $_.current_reference_status -eq "UNKNOWN" }).Count
    $familyLines.Add("| [$phase](./$phase/) | $($pr.Count) | $po | $pl | $pu |")
}

$familyLines.Add("")
$familyLines.Add("## Trust policy")
$familyLines.Add("")
$familyLines.Add("- A value from literature can be displayed without being called verified.")
$familyLines.Add("- A complete solution must pass `LotSizingDataModel.Checker` before promotion.")
$familyLines.Add("- Rejected values remain visible in `known-bad-results/` for scientific traceability.")
$familyLines.Add("- New candidate solutions are submitted through `candidate-solutions/` and the CI trust gate.")
$familyLines.Add("")
$familyLines.Add("See [`DJ-FINAL-REFERENCE-CATALOG.csv`](./metadata/DJ-FINAL-REFERENCE-CATALOG.csv).")

Write-Utf8NoBom -Path (Join-Path $familyRoot "README.md") -Lines $familyLines

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $phaseRoot = Join-Path $familyRoot $phase
    $phaseRows = @($finalRows | Where-Object { $_.phase -eq $phase } | Sort-Object canonical_id)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Dellaert-Jeunet - " + $phase)
    $lines.Add("")
    $lines.Add("| Instance | Current reference | Status | Complete solution | History |")
    $lines.Add("|---|---:|---|---|---|")

    foreach ($r in $phaseRows) {
        $obj = $r.current_reference_objective
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = "unknown" }

        $historyLink = "../result-history/" + $phase + "/" + $r.canonical_id + "/"
        $lines.Add("| ``" + $r.canonical_id + "`` | " + $obj + " | **" + $r.current_reference_status + "** | " + $r.complete_solution_available + " | [history](" + $historyLink + ") |")
    }

    Write-Utf8NoBom -Path (Join-Path $phaseRoot "README.md") -Lines $lines
}

Write-Step "Preparing candidate-solution directories"

$candidateRoot = Join-Path $familyRoot "candidate-solutions"
Ensure-Directory $candidateRoot
Ensure-Directory (Join-Path $candidateRoot "incoming")
Ensure-Directory (Join-Path $candidateRoot "accepted")
Ensure-Directory (Join-Path $candidateRoot "rejected")

$candidateLines = @(
    "# Candidate solutions",
    "",
    "A candidate must provide a metadata JSON file and, whenever possible, a complete LotSizingDataModel solution.",
    "",
    "## Promotion conditions",
    "",
    "1. canonical instance identity resolved;",
    "2. complete solution loads successfully;",
    "3. `LotSizingDataModel.Checker --level full` returns valid;",
    "4. objective is recomputed independently;",
    "5. recomputed objective equals the declared objective within tolerance;",
    "6. candidate is strictly better than the current reference, or proves optimality;",
    "7. prior reference remains in result history.",
    "",
    "A value-only publication may update the literature history but cannot become `VERIFIED_BEST_KNOWN` without a complete valid solution."
)
Write-Utf8NoBom -Path (Join-Path $candidateRoot "README.md") -Lines $candidateLines

Write-Step "Finalization summary"
Write-Host "Canonical instances: 176 / 176"
Write-Host ("Verified proven optimal: " + $verifiedOpt)
Write-Host ("Literature value only: " + $litOnly)
Write-Host ("Rejected local claims: " + $rejectedCount)
Write-Host ("Unknown current reference: " + $unknown)
Write-Host ("Complete solutions available: " + $withSolution)
Write-Host ("Final catalogue: " + $finalCsv)
