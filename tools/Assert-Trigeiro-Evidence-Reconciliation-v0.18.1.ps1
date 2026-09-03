param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest;$ErrorActionPreference="Stop"
$g=Join-Path $BenchmarkRepo "catalog\global";$x=@(Import-Csv -LiteralPath (Join-Path $g "TRIGEIRO-EVIDENCE-RECONCILIATION-v0.18.1.csv"));$c=@(Import-Csv -LiteralPath (Join-Path $g "GLOBAL-EVIDENCE-CAMPAIGN-v0.18.1.csv"));$t=@(Import-Csv -LiteralPath (Join-Path $g "GLOBAL-NORMALIZED-TRUST-v0.17.0.csv"))
if($x.Count-ne 5-or$c.Count-ne 125-or$t.Count-ne 7888){throw "Cardinality guard failed."};if(@($x|Where-Object verified_proven_optimal -ne "False").Count-ne 0){throw "Unsupported optimality promotion."};if(@($x|Where-Object provenance_status -ne "RECONCILED").Count-ne 0){throw "Provenance guard failed."}
Write-Host "TRIGEIRO_EVIDENCE_V0.18.1_VALID";Write-Host "ROWS|5";Write-Host "GLOBAL_TRUST_ROWS|7888";Write-Host "PROMOTIONS|0"
