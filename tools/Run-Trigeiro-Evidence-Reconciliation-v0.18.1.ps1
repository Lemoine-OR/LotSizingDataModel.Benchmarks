param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$g=Join-Path $BenchmarkRepo "catalog\global"
$r=Join-Path $BenchmarkRepo "reports\v0.18.1"
$d=Join-Path $BenchmarkRepo "docs\benchmarks"
foreach($p in @($g,$r,$d)){if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null}}
$old=@(Import-Csv -LiteralPath (Join-Path $g "TRIGEIRO-LOWER-BOUND-RECONCILIATION-v0.18.0.csv"))
if($old.Count -ne 5){throw "Expected five records."}
$rows=@($old|ForEach-Object{[pscustomobject][ordered]@{
global_instance_id=$_.global_instance_id;instance_id=$_.instance_id;objective_reference=$_.objective_reference;lower_bound=$_.lower_bound
objective_source="Ioannis Fragkos (2013), Large-Scale Optimisation in Operations Management, Table 2.4"
lower_bound_source="Ioannis Fragkos (2013), Table 3.3, DJ column"
source_url="https://discovery.ucl.ac.uk/id/eprint/1413951/2/thesis_after_revisions.pdf"
literature_claim="LITERATURE_CLAIMED_OPTIMAL";normalized_trust_status="REFERENCE_WITH_LOWER_BOUND"
provenance_status="RECONCILED";checker_verified_solution="False";verified_proven_optimal="False"
remaining_challenge_type="OPTIMALITY_PROOF";severity="HIGH"
decision="NO_TRUST_PROMOTION_WITHOUT_COMPLETE_SOLUTION_AND_CHECKER_CERTIFICATE"
}})
$rows|Export-Csv -LiteralPath (Join-Path $g "TRIGEIRO-EVIDENCE-RECONCILIATION-v0.18.1.csv") -NoTypeInformation -Encoding UTF8
$campaign=@(Import-Csv -LiteralPath (Join-Path $g "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.0.csv"))
$updated=@($campaign|ForEach-Object{if($_.family -eq "TRIGEIRO1989"){$_.workstream="OPTIMALITY_CERTIFICATION";$_.status="PROVENANCE_RECONCILED_SOLUTION_MISSING";$_.severity="HIGH";$_.next_action="Acquire a complete solution and independently verify feasibility, objective and optimality."};$_})
$updated|Export-Csv -LiteralPath (Join-Path $g "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.1.csv") -NoTypeInformation -Encoding UTF8
$rows|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $g "TRIGEIRO-EVIDENCE-RECONCILIATION-v0.18.1.json") -Encoding UTF8
@([pscustomobject]@{metric="provenance_reconciled";value=5},[pscustomobject]@{metric="remaining_optimality_proofs";value=5},[pscustomobject]@{metric="cattrysse_solution_acquisitions";value=120},[pscustomobject]@{metric="trust_promotions";value=0})|Export-Csv -LiteralPath (Join-Path $r "EVIDENCE-RECONCILIATION-SUMMARY-v0.18.1.csv") -NoTypeInformation -Encoding UTF8
$md="# Trigeiro evidence reconciliation v0.18.1`r`n`r`nThe five lower bounds are reconciled to Fragkos (2013), Table 3.3, DJ column. The corresponding objective values are labelled optimal in Table 2.4. These literature claims are preserved without promotion: no complete solution or Checker certificate is available.`r`n`r`nRemaining work: five OPTIMALITY_PROOF challenges and 120 CATTRYSSE solution acquisitions."
[IO.File]::WriteAllText((Join-Path $d "TRIGEIRO-EVIDENCE-RECONCILIATION-v0.18.1.md"),$md,(New-Object Text.UTF8Encoding($false)))
Write-Host "TRIGEIRO_EVIDENCE_V0.18.1";Write-Host "RECONCILED|5";Write-Host "TRUST_PROMOTIONS|0";Write-Host "REMAINING_CHALLENGES|125"
