param([string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$g = Join-Path $BenchmarkRepo "catalog\global"
$trust = @(Import-Csv -LiteralPath (Join-Path $g "GLOBAL-NORMALIZED-TRUST-v0.17.0.csv"))
$campaign = @(Import-Csv -LiteralPath (Join-Path $g "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.0.csv"))
$bounds = @(Import-Csv -LiteralPath (Join-Path $g "TRIGEIRO-LOWER-BOUND-RECONCILIATION-v0.18.0.csv"))
$cat = @(Import-Csv -LiteralPath (Join-Path $g "CATTRYSSE-SOLUTION-ACQUISITION-v0.18.0.csv"))
if ($trust.Count -ne 7888 -or @($trust.global_instance_id | Sort-Object -Unique).Count -ne 7888) { throw "Global trust invariant failed." }
if ($campaign.Count -ne 125 -or $bounds.Count -ne 5 -or $cat.Count -ne 120) { throw "Campaign cardinality failed." }
if (@($bounds | Where-Object citation_audit_status -ne "SOURCE_CITATION_CONFLICT").Count -ne 0) { throw "Citation conflict guard failed." }
if (@($campaign | Where-Object evidence_decision -ne "NO_PROMOTION").Count -ne 0) { throw "Unsupported promotion detected." }
$expectedIds = @("G53","G57","G62","G69","G72")
$observedIdText = (@($bounds.instance_id | Sort-Object) -join ',')
$expectedIdText = (@($expectedIds | Sort-Object) -join ',')
if ($observedIdText -ne $expectedIdText) { throw "Lower-bound identity guard failed." }
Write-Host "GLOBAL_EVIDENCE_V0.18.0_VALID"
Write-Host "TRUST_ROWS|7888"
Write-Host "CAMPAIGN_ROWS|125"
Write-Host "PROMOTIONS|0"
