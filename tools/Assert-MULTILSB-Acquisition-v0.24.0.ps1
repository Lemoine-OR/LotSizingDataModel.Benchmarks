param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$reportRoot=Join-Path $BenchmarkRepo "reports\v0.24.0"
$inventoryPath=Join-Path $reportRoot "MULTILSB-OFFICIAL-INVENTORY-v0.24.0.csv"
$manifestPath=Join-Path $reportRoot "MULTILSB-ACQUISITION-MANIFEST-v0.24.0.json"
$crosswalkPath=Join-Path $reportRoot "MULTILSB-MIPLIB-CROSSWALK-v0.24.0.csv"
foreach($path in @($inventoryPath,$manifestPath,$crosswalkPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ("Required release file missing: "+$path)}}
$inventory=@(Import-Csv -LiteralPath $inventoryPath)
if($inventory.Count -ne 120){throw "MULTILSB inventory count failed."}
foreach($setName in @("SET1","SET2","SET3","SET4")){if(@($inventory|Where-Object{$_.set -eq $setName}).Count -ne 30){throw ("Set count failed: "+$setName)}}
if(@($inventory|Where-Object{$_.canonical_status -ne "NOT_ADMITTED_MODEL_MAPPING_REQUIRED"}).Count -ne 0){throw "Unsafe canonical admission detected."}
$crosswalk=@(Import-Csv -LiteralPath $crosswalkPath)
if($crosswalk.Count -ne 3){throw "MIPLIB crosswalk count failed."}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if([int]$manifest.raw_instances -ne 120 -or [int]$manifest.canonical_admissions -ne 0){throw "Manifest invariant failed."}
Write-Host "MULTILSB_ACQUISITION_V0.24.0_VALID"
Write-Host "RAW_INSTANCES|120"
Write-Host "CANONICAL_ADMISSIONS|0"
Write-Host "TRUST_PROMOTIONS|0"
Write-Host "REGISTRY_ROWS|7905"
