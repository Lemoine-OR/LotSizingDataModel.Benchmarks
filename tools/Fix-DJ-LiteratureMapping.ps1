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

function Get-BaseDjId {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return ""
    }

    if ($Id -match "(?i)^(ph[123]in[0-9]+)") {
        return $Matches[1].ToLowerInvariant()
    }

    return $Id.ToLowerInvariant()
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\DJ2000"
$metaRoot = Join-Path $familyRoot "metadata"
$trustCsv = Join-Path $metaRoot "DJ-TRUST-GATE.csv"
$litCsv = Join-Path $metaRoot "DJ-LITERATURE-REFERENCE-CANDIDATES.csv"
$rejectedCsv = Join-Path $metaRoot "DJ-REJECTED-RESULTS.csv"

if (-not (Test-Path -LiteralPath $trustCsv -PathType Leaf)) {
    throw "Missing trust catalogue: $trustCsv"
}
if (-not (Test-Path -LiteralPath $litCsv -PathType Leaf)) {
    throw "Missing literature catalogue: $litCsv"
}

$trust = Import-Csv -LiteralPath $trustCsv
$literature = Import-Csv -LiteralPath $litCsv
$rejected = @()
if (Test-Path -LiteralPath $rejectedCsv -PathType Leaf) {
    $rejected = @(Import-Csv -LiteralPath $rejectedCsv)
}

Write-Step "Normalizing DJ literature mapping keys"

$litByBase = @{}
foreach ($lit in $literature) {
    $base = Get-BaseDjId -Id $lit.candidate_canonical_id
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $litByBase[$base] = $lit
    }
}

$finalRows = New-Object System.Collections.Generic.List[object]
$mappingRows = New-Object System.Collections.Generic.List[object]

foreach ($r in $trust) {
    $base = Get-BaseDjId -Id $r.canonical_id
    $lit = $null
    if ($litByBase.ContainsKey($base)) {
        $lit = $litByBase[$base]
    }

    $bad = @($rejected | Where-Object {
        $_.phase -eq $r.phase -and
        (Get-BaseDjId -Id $_.canonical_id) -eq $base
    } | Select-Object -First 1)

    $litObj = ""
    $litSource = ""
    $litStatus = ""
    $mappingStatus = "NO_LITERATURE_MATCH"

    if ($null -ne $lit) {
        $litObj = $lit.objective
        $litSource = $lit.source
        $litStatus = $lit.source_status
        $mappingStatus = "MATCHED_BY_BASE_DJ_ID"
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
            $currentBestStatus = "UNKNOWN"
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
        base_dj_id = $base
        current_reference_objective = $currentBestObjective
        current_reference_status = $currentBestStatus
        source_class = $sourceClass
        local_objective = $r.objective
        local_trust_status = $r.trust_status
        literature_objective_2011 = $litObj
        literature_source = $litSource
        literature_status = $litStatus
        literature_mapping_status = $mappingStatus
        rejected_local_claim = $(if ($bad.Count -gt 0) { "True" } else { "False" })
        complete_solution_available = $r.solution_available
        checker_report_directory = $r.report_directory
    })

    $mappingRows.Add([pscustomobject]@{
        phase = $r.phase
        canonical_id = $r.canonical_id
        base_dj_id = $base
        literature_candidate_id = $(if ($null -ne $lit) { $lit.candidate_canonical_id } else { "" })
        literature_objective = $litObj
        mapping_status = $mappingStatus
    })
}

$finalCsv = Join-Path $metaRoot "DJ-FINAL-REFERENCE-CATALOG.csv"
$finalRows | Sort-Object phase,canonical_id |
    Export-Csv -LiteralPath $finalCsv -NoTypeInformation -Encoding UTF8

$mappingCsv = Join-Path $metaRoot "DJ-LITERATURE-ID-MAPPING.csv"
$mappingRows | Sort-Object phase,canonical_id |
    Export-Csv -LiteralPath $mappingCsv -NoTypeInformation -Encoding UTF8

Write-Step "Regenerating family and phase README files"

$verifiedOpt = @($finalRows | Where-Object { $_.current_reference_status -eq "VERIFIED_PROVEN_OPTIMAL" }).Count
$litOnly = @($finalRows | Where-Object { $_.source_class -eq "LITERATURE_VALUE_ONLY" }).Count
$unknown = @($finalRows | Where-Object { $_.current_reference_status -eq "UNKNOWN" }).Count
$rejectedCount = @($finalRows | Where-Object { $_.rejected_local_claim -eq "True" }).Count
$withSolution = @($finalRows | Where-Object { $_.complete_solution_available -eq "True" }).Count
$matchedLit = @($mappingRows | Where-Object { $_.mapping_status -eq "MATCHED_BY_BASE_DJ_ID" }).Count

$familyLines = @(
    "# Dellaert-Jeunet benchmark",
    "",
    "> **176 canonical instances, three historical phases, trust-gated reference results.**",
    "",
    "## Current coverage",
    "",
    "| Metric | Count |",
    "|---|---:|",
    "| Canonical instances | **176 / 176** |",
    "| Verified proven optimal | **$verifiedOpt** |",
    "| Literature value only | **$litOnly** |",
    "| Literature rows mapped | **$matchedLit / 80** |",
    "| Complete solution available | **$withSolution** |",
    "| Rejected local claims | **$rejectedCount** |",
    "| Unknown reference objective | **$unknown** |",
    "",
    "Phase 2 and Phase 3 literature values remain **unverified** until newer 2014 per-instance BKS and exact objective equivalence are fully reconciled.",
    "",
    "See `metadata/DJ-LITERATURE-ID-MAPPING.csv` for the explicit canonical-to-literature mapping."
)

[System.IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $familyLines,
    (New-Object System.Text.UTF8Encoding($false))
)

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $phaseRows = @($finalRows | Where-Object { $_.phase -eq $phase } | Sort-Object canonical_id)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Dellaert-Jeunet - " + $phase)
    $lines.Add("")
    $lines.Add("| Instance | Literature key | Current reference | Status | Complete solution |")
    $lines.Add("|---|---|---:|---|---|")

    foreach ($r in $phaseRows) {
        $obj = $r.current_reference_objective
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = "unknown" }
        $lines.Add("| ``" + $r.canonical_id + "`` | ``" + $r.base_dj_id + "`` | " + $obj + " | **" + $r.current_reference_status + "** | " + $r.complete_solution_available + " |")
    }

    [System.IO.File]::WriteAllLines(
        (Join-Path (Join-Path $familyRoot $phase) "README.md"),
        $lines,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

Write-Step "Mapping fix summary"
Write-Host ("Literature mappings: " + $matchedLit + " / 80")
Write-Host ("Verified proven optimal: " + $verifiedOpt)
Write-Host ("Literature value only: " + $litOnly)
Write-Host ("Rejected local claims: " + $rejectedCount)
Write-Host ("Unknown current reference: " + $unknown)
Write-Host ("Complete solutions: " + $withSolution)
Write-Host ("Mapping catalogue: " + $mappingCsv)
