param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$reportRoot=Join-Path $BenchmarkRepo "reports\v0.25.0";$inventoryPath=Join-Path $reportRoot "MULTILSB-SEMANTIC-NORMALIZATION-v0.25.0.csv";$manifestPath=Join-Path $reportRoot "MULTILSB-SEMANTIC-MANIFEST-v0.25.0.json";$gapPath=Join-Path $reportRoot "MULTILSB-MODEL-CAPABILITY-GAP-v0.25.0.csv"
foreach($path in @($inventoryPath,$manifestPath,$gapPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ("Release artifact missing: "+$path)}}
$rows=@(Import-Csv -LiteralPath $inventoryPath);if($rows.Count -ne 120){throw "Normalized count failed."};if(@($rows|Where-Object{$_.round_trip -ne "PASS"}).Count -ne 0){throw "Round-trip failure."};if(@($rows|Where-Object{$_.canonical_admission -ne "BLOCKED_FAMILY_SETUP_SEMANTICS"}).Count -ne 0){throw "Unsafe admission state."}
foreach($setName in @("SET1","SET2","SET3","SET4")){if(@($rows|Where-Object{$_.set -eq $setName}).Count -ne 30){throw ("Set count failed: "+$setName)}}
$jsonFiles=@(Get-ChildItem -LiteralPath (Join-Path $BenchmarkRepo "benchmarks\MULTILSB\normalized-source\v0.25.0") -Recurse -File -Filter "*.json");if($jsonFiles.Count -ne 120){throw "Normalized JSON count failed."}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;if([int]$manifest.normalized_instances -ne 120 -or [int]$manifest.canonical_admissions -ne 0 -or [int]$manifest.registry_rows -ne 7905){throw "Manifest invariant failed."}
Write-Host "MULTILSB_SEMANTIC_NORMALIZATION_V0.25.0_VALID"
Write-Host "NORMALIZED|120"
Write-Host "ROUND_TRIP|PASS"
Write-Host "BLOCKER|FAMILY_SETUP_SEMANTICS"
Write-Host "TRUST_PROMOTIONS|0"
Write-Host "REGISTRY_ROWS|7905"
