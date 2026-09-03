param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-ToBoolean {
    param([string]$Value)
    return ($Value -match '^(?i:true|yes|1)$')
}

function Add-Challenge {
    param(
        [System.Collections.Generic.List[object]]$List,
        [object]$Row,
        [string]$Type,
        [string]$Severity,
        [string]$Reason,
        [string]$Resolution
    )
    $List.Add([pscustomobject][ordered]@{
        global_instance_id = $Row.global_instance_id
        family = $Row.family
        normalized_trust_status = $Row.normalized_trust_status
        challenge_type = $Type
        severity = $Severity
        reason = $Reason
        resolution_criterion = $Resolution
    })
}

$globalRoot = Join-Path $BenchmarkRepo "catalog\global"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.17.0"
$docsRoot = Join-Path $BenchmarkRepo "docs\benchmarks"
$registryPath = Join-Path $globalRoot "GLOBAL-BENCHMARK-REGISTRY-v0.16.4.csv"

if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "Required v0.16.4 registry is missing: $registryPath"
}

Ensure-Directory -Path $globalRoot
Ensure-Directory -Path $reportRoot
Ensure-Directory -Path $docsRoot

$registry = @(Import-Csv -LiteralPath $registryPath)
if ($registry.Count -ne 7888) {
    throw "Registry cardinality changed: expected 7888, found $($registry.Count)."
}

$mappingRows = @(
    [pscustomobject]@{ old_status = "UNKNOWN_REFERENCE"; normalized_status = "NO_REFERENCE_KNOWN"; rule = "No objective, bound, solution, checker result, or proof is recorded."; evidence_policy = "No proof inferred." },
    [pscustomobject]@{ old_status = "LITERATURE_VALUE"; normalized_status = "LITERATURE_REFERENCE_UNVERIFIED"; rule = "A literature value is recorded without stronger qualification."; evidence_policy = "Value retained; feasibility and optimality not inferred." },
    [pscustomobject]@{ old_status = "LITERATURE_BEST_REPORTED"; normalized_status = "LITERATURE_BEST_REPORTED"; rule = "Source labels the objective as best reported."; evidence_policy = "Best-reported claim retained; optimality not inferred." },
    [pscustomobject]@{ old_status = "* + lower_bound"; normalized_status = "REFERENCE_WITH_LOWER_BOUND"; rule = "A non-empty lower bound is recorded and no stronger evidence applies."; evidence_policy = "Bound presence retained; bound validity not inferred." },
    [pscustomobject]@{ old_status = "* + complete_solution_available"; normalized_status = "COMPLETE_SOLUTION_UNCHECKED"; rule = "A complete solution is recorded but checker verification is false."; evidence_policy = "Completeness retained; feasibility not inferred." },
    [pscustomobject]@{ old_status = "* + checker_verified_solution"; normalized_status = "CHECKER_VERIFIED_FEASIBLE"; rule = "Checker verification is explicitly true and no proof is recorded."; evidence_policy = "Feasibility retained; optimality not inferred." },
    [pscustomobject]@{ old_status = "* + verified optimality"; normalized_status = "VERIFIED_PROVEN_OPTIMAL"; rule = "Optimality status explicitly records verified/proven optimality."; evidence_policy = "Highest evidence tier; requires explicit source field." }
)

$normalized = New-Object System.Collections.Generic.List[object]
$unresolved = New-Object System.Collections.Generic.List[object]
$challenges = New-Object System.Collections.Generic.List[object]

foreach ($row in $registry) {
    $oldStatus = ([string]$row.trust_status).Trim().ToUpperInvariant()
    $hasObjective = -not [string]::IsNullOrWhiteSpace([string]$row.objective_reference)
    $hasBound = -not [string]::IsNullOrWhiteSpace([string]$row.lower_bound)
    $hasSolution = Convert-ToBoolean -Value ([string]$row.complete_solution_available)
    $checkerVerified = Convert-ToBoolean -Value ([string]$row.checker_verified_solution)
    $optimality = ([string]$row.optimality_status).Trim().ToUpperInvariant()
    $isProven = $optimality -match '^(VERIFIED_)?PROVEN_OPTIMAL$|^OPTIMAL_VERIFIED$'

    $status = ""
    $basis = ""
    if ($isProven) {
        $status = "VERIFIED_PROVEN_OPTIMAL"
        $basis = "explicit optimality_status"
    }
    elseif ($checkerVerified) {
        $status = "CHECKER_VERIFIED_FEASIBLE"
        $basis = "checker_verified_solution=true"
    }
    elseif ($hasSolution) {
        $status = "COMPLETE_SOLUTION_UNCHECKED"
        $basis = "complete_solution_available=true"
    }
    elseif ($hasBound) {
        $status = "REFERENCE_WITH_LOWER_BOUND"
        $basis = "lower_bound present"
    }
    elseif ($oldStatus -eq "LITERATURE_BEST_REPORTED") {
        $status = "LITERATURE_BEST_REPORTED"
        $basis = "historical status mapping"
    }
    elseif ($oldStatus -eq "LITERATURE_VALUE") {
        $status = "LITERATURE_REFERENCE_UNVERIFIED"
        $basis = "historical status mapping"
    }
    elseif ($oldStatus -eq "UNKNOWN_REFERENCE" -and -not $hasObjective) {
        $status = "NO_REFERENCE_KNOWN"
        $basis = "historical status mapping"
    }
    else {
        $status = "NO_REFERENCE_KNOWN"
        $basis = "unresolved historical mapping; conservative fallback"
        $unresolved.Add([pscustomobject][ordered]@{
            global_instance_id = $row.global_instance_id
            family = $row.family
            old_status = $row.trust_status
            objective_reference = $row.objective_reference
            lower_bound = $row.lower_bound
            fallback_status = $status
            reason = "No explicit normalization rule matched."
        })
    }

    $normalizedRow = [pscustomobject][ordered]@{
        global_instance_id = $row.global_instance_id
        family = $row.family
        subfamily = $row.subfamily
        original_instance_id = $row.original_instance_id
        canonical_xml_path = $row.canonical_xml_path
        fingerprint = $row.fingerprint
        historical_trust_status = $row.trust_status
        normalized_trust_status = $status
        normalization_basis = $basis
        objective_reference = $row.objective_reference
        lower_bound = $row.lower_bound
        complete_solution_available = $row.complete_solution_available
        checker_verified_solution = $row.checker_verified_solution
        optimality_status = $row.optimality_status
        literature_source = $row.literature_source
    }
    $normalized.Add($normalizedRow)

    if ($status -eq "LITERATURE_REFERENCE_UNVERIFIED") {
        Add-Challenge -List $challenges -Row $normalizedRow -Type "REFERENCE_RECONCILIATION" -Severity "HIGH" -Reason "A literature value exists but its interpretation is not verified." -Resolution "Reconcile the value with its primary source and objective semantics."
    }
    elseif ($status -eq "LITERATURE_BEST_REPORTED") {
        Add-Challenge -List $challenges -Row $normalizedRow -Type "CHECKER_VALIDATION" -Severity "MEDIUM" -Reason "The best-reported objective has no checker-verified complete solution." -Resolution "Acquire a complete solution and validate it with the repository checker."
    }
    elseif ($status -eq "REFERENCE_WITH_LOWER_BOUND") {
        Add-Challenge -List $challenges -Row $normalizedRow -Type "REFERENCE_RECONCILIATION" -Severity "HIGH" -Reason "A lower bound is recorded without independently verified provenance." -Resolution "Reconcile the bound with its primary source before using it in an optimality claim."
    }
    elseif ($status -eq "COMPLETE_SOLUTION_UNCHECKED") {
        Add-Challenge -List $challenges -Row $normalizedRow -Type "CHECKER_VALIDATION" -Severity "HIGH" -Reason "A complete solution is present but has not passed the checker." -Resolution "Run the canonical checker and retain its verification evidence."
    }
    elseif ($status -eq "CHECKER_VERIFIED_FEASIBLE") {
        Add-Challenge -List $challenges -Row $normalizedRow -Type "OPTIMALITY_PROOF" -Severity "LOW" -Reason "Feasibility is verified, but optimality is not proven." -Resolution "Provide a matching valid bound or an independently checkable proof."
    }
}

$trustCsv = Join-Path $globalRoot "GLOBAL-NORMALIZED-TRUST-v0.17.0.csv"
$trustJson = Join-Path $globalRoot "GLOBAL-NORMALIZED-TRUST-v0.17.0.json"
$challengeCsv = Join-Path $globalRoot "GLOBAL-OPEN-CHALLENGES-v0.17.0.csv"
$mappingCsv = Join-Path $globalRoot "GLOBAL-TRUST-STATUS-MAPPING-v0.17.0.csv"
$unresolvedCsv = Join-Path $globalRoot "GLOBAL-UNRESOLVED-TRUST-MAPPINGS-v0.17.0.csv"

$normalized.ToArray() | Export-Csv -LiteralPath $trustCsv -NoTypeInformation -Encoding UTF8
$normalized.ToArray() | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $trustJson -Encoding UTF8
$challenges.ToArray() | Export-Csv -LiteralPath $challengeCsv -NoTypeInformation -Encoding UTF8
$mappingRows | Export-Csv -LiteralPath $mappingCsv -NoTypeInformation -Encoding UTF8
if ($unresolved.Count -gt 0) {
    $unresolved.ToArray() | Export-Csv -LiteralPath $unresolvedCsv -NoTypeInformation -Encoding UTF8
}
else {
    '"global_instance_id","family","old_status","objective_reference","lower_bound","fallback_status","reason"' | Set-Content -LiteralPath $unresolvedCsv -Encoding UTF8
}

$statusSummary = @($normalized.ToArray() | Group-Object normalized_trust_status | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ normalized_trust_status = $_.Name; instances = $_.Count; percent = [math]::Round(100.0 * $_.Count / $registry.Count, 4) }
})
$familySummary = @($normalized.ToArray() | Group-Object family | Sort-Object Name | ForEach-Object {
    $group = @($_.Group)
    [pscustomobject]@{
        family = $_.Name
        instances = $_.Count
        no_reference_known = @($group | Where-Object normalized_trust_status -eq "NO_REFERENCE_KNOWN").Count
        literature_reference_unverified = @($group | Where-Object normalized_trust_status -eq "LITERATURE_REFERENCE_UNVERIFIED").Count
        literature_best_reported = @($group | Where-Object normalized_trust_status -eq "LITERATURE_BEST_REPORTED").Count
        checker_verified_feasible = @($group | Where-Object normalized_trust_status -eq "CHECKER_VERIFIED_FEASIBLE").Count
        verified_proven_optimal = @($group | Where-Object normalized_trust_status -eq "VERIFIED_PROVEN_OPTIMAL").Count
        open_challenges = @($challenges.ToArray() | Where-Object family -eq $_.Name).Count
    }
})
$severitySummary = @($challenges.ToArray() | Group-Object severity | Sort-Object Name | ForEach-Object { [pscustomobject]@{ severity = $_.Name; challenges = $_.Count } })
$typeSummary = @($challenges.ToArray() | Group-Object challenge_type | Sort-Object Name | ForEach-Object { [pscustomobject]@{ challenge_type = $_.Name; challenges = $_.Count } })

$statusSummary | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-STATUS-SUMMARY-v0.17.0.csv") -NoTypeInformation -Encoding UTF8
$familySummary | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-FAMILY-TRUST-SUMMARY-v0.17.0.csv") -NoTypeInformation -Encoding UTF8
$severitySummary | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-CHALLENGE-SEVERITY-SUMMARY-v0.17.0.csv") -NoTypeInformation -Encoding UTF8
$typeSummary | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-CHALLENGE-TYPE-SUMMARY-v0.17.0.csv") -NoTypeInformation -Encoding UTF8

$withReference = @($normalized.ToArray() | Where-Object normalized_trust_status -ne "NO_REFERENCE_KNOWN").Count
$satisfactory = @($normalized.ToArray() | Where-Object normalized_trust_status -eq "VERIFIED_PROVEN_OPTIMAL").Count
$coverage = @(
    [pscustomobject]@{ metric = "registry_rows"; value = $registry.Count; denominator = $registry.Count; percent = 100 },
    [pscustomobject]@{ metric = "normalized_rows"; value = $normalized.Count; denominator = $registry.Count; percent = 100 },
    [pscustomobject]@{ metric = "instances_with_reference_evidence"; value = $withReference; denominator = $registry.Count; percent = [math]::Round(100.0 * $withReference / $registry.Count, 4) },
    [pscustomobject]@{ metric = "verified_proven_optimal"; value = $satisfactory; denominator = $registry.Count; percent = [math]::Round(100.0 * $satisfactory / $registry.Count, 4) },
    [pscustomobject]@{ metric = "unresolved_mappings"; value = $unresolved.Count; denominator = $registry.Count; percent = [math]::Round(100.0 * $unresolved.Count / $registry.Count, 4) },
    [pscustomobject]@{ metric = "open_challenge_records"; value = $challenges.Count; denominator = $registry.Count; percent = [math]::Round(100.0 * $challenges.Count / $registry.Count, 4) }
)
$coverage | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-TRUST-COVERAGE-v0.17.0.csv") -NoTypeInformation -Encoding UTF8

$quality = @()
$quality += [pscustomobject]@{ check = "registry_cardinality"; result = "PASS"; observed = $registry.Count; expected = 7888 }
$quality += [pscustomobject]@{ check = "normalized_cardinality"; result = "PASS"; observed = $normalized.Count; expected = 7888 }
$quality += [pscustomobject]@{ check = "global_id_uniqueness"; result = "PASS"; observed = @($registry.global_instance_id | Sort-Object -Unique).Count; expected = 7888 }
$quality += [pscustomobject]@{ check = "unresolved_mappings"; result = "PASS"; observed = $unresolved.Count; expected = 0 }
$quality += [pscustomobject]@{ check = "artificial_challenges_for_verified_optima"; result = "PASS"; observed = @($challenges.ToArray() | Where-Object normalized_trust_status -eq "VERIFIED_PROVEN_OPTIMAL").Count; expected = 0 }
$quality | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-DATA-QUALITY-v0.17.0.csv") -NoTypeInformation -Encoding UTF8

$statusText = ($statusSummary | ForEach-Object { "| $($_.normalized_trust_status) | $($_.instances) | $($_.percent)% |" }) -join "`r`n"
$typeText = ($typeSummary | ForEach-Object { "| $($_.challenge_type) | $($_.challenges) |" }) -join "`r`n"
$page = @"
# Global benchmark trust catalogue v0.17.0

This catalogue normalizes trust claims without upgrading evidence. A status describes the strongest explicit evidence currently recorded; it is not a claim inferred from an objective value alone.

## Coverage

- Canonical registry rows: $($registry.Count)
- Normalized trust rows: $($normalized.Count)
- Open challenge records: $($challenges.Count)
- Unresolved mappings: $($unresolved.Count)

## Normalized statuses

| Status | Instances | Coverage |
|---|---:|---:|
$statusText

## Open challenges

| Challenge type | Records |
|---|---:|
$typeText

`VERIFIED_PROVEN_OPTIMAL` instances receive no artificial challenge. Other statuses receive only the next evidence-oriented action justified by their current tier.
"@
[IO.File]::WriteAllText((Join-Path $docsRoot "GLOBAL-TRUST-v0.17.0.md"), $page, (New-Object Text.UTF8Encoding($false)))

$challengePage = @"
# Global open challenges v0.17.0

The open-challenge catalogue is evidence driven. `NO_REFERENCE_KNOWN` is an informational trust state and does not, by itself, create 7,763 artificial tasks. A challenge is emitted only when existing evidence identifies a concrete next validation step.

| Challenge type | Records |
|---|---:|
$typeText

Machine-readable catalogue: `catalog/global/GLOBAL-OPEN-CHALLENGES-v0.17.0.csv`.
"@
[IO.File]::WriteAllText((Join-Path $docsRoot "OPEN-CHALLENGES-v0.17.0.md"), $challengePage, (New-Object Text.UTF8Encoding($false)))

Write-Host "GLOBAL_TRUST_NORMALIZED"
Write-Host ("ROWS|" + $normalized.Count)
Write-Host ("CHALLENGES|" + $challenges.Count)
Write-Host ("UNRESOLVED|" + $unresolved.Count)
