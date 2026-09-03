param([string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

$globalRoot = Join-Path $BenchmarkRepo "catalog\global"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.18.0"
$docsRoot = Join-Path $BenchmarkRepo "docs\benchmarks"
$trustPath = Join-Path $globalRoot "GLOBAL-NORMALIZED-TRUST-v0.17.0.csv"
$cattryssePath = Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990\metadata\CATTRYSSE1990-TRUST-CATALOG-v0.15.0.csv"
Ensure-Directory $reportRoot
Ensure-Directory $docsRoot

$trust = @(Import-Csv -LiteralPath $trustPath)
$bounds = @($trust | Where-Object normalized_trust_status -eq "REFERENCE_WITH_LOWER_BOUND")
$cattrysse = @(Import-Csv -LiteralPath $cattryssePath)
if ($trust.Count -ne 7888) { throw "v0.17.0 trust cardinality failed." }
if ($bounds.Count -ne 5) { throw "Expected 5 lower-bound records." }
if ($cattrysse.Count -ne 120) { throw "Expected 120 CATTRYSSE records." }

$reconciliation = @($bounds | ForEach-Object {
    [pscustomobject][ordered]@{
        global_instance_id = $_.global_instance_id
        instance_id = $_.original_instance_id
        objective_reference = $_.objective_reference
        lower_bound = $_.lower_bound
        historical_citation = $_.literature_source
        citation_audit_status = "SOURCE_CITATION_CONFLICT"
        conflict = "CORE DP 2000/39 is attributed to Miller, Nemhauser and Savelsbergh; the catalogue attributes it to Belvaux and Wolsey."
        verified_belvaux_wolsey_work = "bc-prod: A specialized branch-and-cut system for lot-sizing problems"
        verified_doi = "10.1287/mnsc.46.5.724.12048"
        evidence_decision = "NO_PROMOTION"
        normalized_trust_status = $_.normalized_trust_status
        next_action = "Locate the exact primary table containing this instance, objective and lower bound; retain both bibliographic candidates in the audit trail."
    }
})

$acquisition = @($cattrysse | Sort-Object { [int]($_.instance_id -replace '\D','') } | ForEach-Object {
    [pscustomobject][ordered]@{
        global_instance_id = "CATTRYSSE1990::" + $_.class_id + "::" + $_.instance_id
        instance_id = $_.instance_id
        class_id = $_.class_id
        xml_file = $_.xml_file
        workbook = $_.workbook
        best_reported_objective = $_.best_reported_objective
        achieving_methods = $_.achieving_methods
        source_semantics = $_.source_semantics
        complete_solution_available = $_.complete_solution_available
        checker_verified_solution = $_.checker_verified_solution
        acquisition_status = "MISSING_COMPLETE_SOLUTION"
        evidence_decision = "NO_PROMOTION"
        next_action = "Acquire or reconstruct a complete production plan, preserve provenance, then run the canonical Checker."
    }
})

$campaign = New-Object System.Collections.Generic.List[object]
foreach ($row in $reconciliation) {
    $campaign.Add([pscustomobject][ordered]@{ global_instance_id=$row.global_instance_id; family="TRIGEIRO1989"; workstream="LOWER_BOUND_PROVENANCE"; status=$row.citation_audit_status; severity="HIGH"; evidence_decision=$row.evidence_decision; next_action=$row.next_action })
}
foreach ($row in $acquisition) {
    $campaign.Add([pscustomobject][ordered]@{ global_instance_id=$row.global_instance_id; family="CATTRYSSE1990"; workstream="COMPLETE_SOLUTION_ACQUISITION"; status=$row.acquisition_status; severity="MEDIUM"; evidence_decision=$row.evidence_decision; next_action=$row.next_action })
}

$reconciliation | Export-Csv -LiteralPath (Join-Path $globalRoot "TRIGEIRO-LOWER-BOUND-RECONCILIATION-v0.18.0.csv") -NoTypeInformation -Encoding UTF8
$acquisition | Export-Csv -LiteralPath (Join-Path $globalRoot "CATTRYSSE-SOLUTION-ACQUISITION-v0.18.0.csv") -NoTypeInformation -Encoding UTF8
$campaign.ToArray() | Export-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.0.csv") -NoTypeInformation -Encoding UTF8
$campaign.ToArray() | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $globalRoot "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.0.json") -Encoding UTF8

$summary = @(
    [pscustomobject]@{ workstream="LOWER_BOUND_PROVENANCE"; records=5; resolved=0; blocked=5; decision="NO_PROMOTION" },
    [pscustomobject]@{ workstream="COMPLETE_SOLUTION_ACQUISITION"; records=120; resolved=0; blocked=120; decision="NO_PROMOTION" }
)
$summary | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-EVIDENCE-CAMPAIGN-SUMMARY-v0.18.0.csv") -NoTypeInformation -Encoding UTF8

$quality = @(
    [pscustomobject]@{ check="v0.17_trust_rows"; observed=7888; expected=7888; result="PASS" },
    [pscustomobject]@{ check="lower_bound_audit_rows"; observed=$reconciliation.Count; expected=5; result="PASS" },
    [pscustomobject]@{ check="cattrysse_acquisition_rows"; observed=$acquisition.Count; expected=120; result="PASS" },
    [pscustomobject]@{ check="evidence_campaign_rows"; observed=$campaign.Count; expected=125; result="PASS" },
    [pscustomobject]@{ check="unsupported_promotions"; observed=@($campaign.ToArray() | Where-Object evidence_decision -ne "NO_PROMOTION").Count; expected=0; result="PASS" }
)
$quality | Export-Csv -LiteralPath (Join-Path $reportRoot "GLOBAL-EVIDENCE-DATA-QUALITY-v0.18.0.csv") -NoTypeInformation -Encoding UTF8

$page = @"
# Global evidence campaign v0.18.0

This release audits evidence without changing canonical XML or promoting trust claims.

## Findings

- Five TRIGEIRO1989 lower-bound records have a bibliographic conflict: CORE DP 2000/39 is not a Belvaux-Wolsey paper.
- The verified Belvaux-Wolsey article is *bc-prod*, DOI 10.1287/mnsc.46.5.724.12048, but no table-level match has yet been established for G53, G57, G62, G69 or G72.
- All 120 CATTRYSSE1990 objectives remain best-reported workbook values without complete solutions.
- No trust status is promoted in v0.18.0.

## Exit criteria

The five bounds require exact primary-table provenance. Each CATTRYSSE record requires a complete traceable solution followed by canonical Checker validation.
"@
[IO.File]::WriteAllText((Join-Path $docsRoot "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.0.md"), $page, (New-Object Text.UTF8Encoding($false)))
Write-Host "GLOBAL_EVIDENCE_CAMPAIGN_V0.18.0"
Write-Host "ROWS|125"
Write-Host "LOWER_BOUND_CONFLICTS|5"
Write-Host "CATTRYSSE_MISSING_SOLUTIONS|120"
Write-Host "PROMOTIONS|0"
