param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks",[string]$ModelRepo="D:\Dev\LotSizingDataModel")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$normalized=Join-Path $BenchmarkRepo "benchmarks\MULTILSB\normalized-source\v0.25.0";if(-not(Test-Path -LiteralPath $normalized -PathType Container)){throw "v0.25.0 normalized corpus missing."}
$jsonFiles=@(Get-ChildItem -LiteralPath $normalized -Recurse -File -Filter "*.json");if($jsonFiles.Count -ne 120){throw "Normalized corpus must contain 120 files."}
$reportRoot=Join-Path $BenchmarkRepo "reports\v0.30.0";if(-not(Test-Path -LiteralPath $reportRoot)){New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null}
$plan=New-Object System.Collections.Generic.List[object]
foreach($file in $jsonFiles){$data=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json;$miplib="NO";if($data.source_id -in @("set3-10","set3-15","set3-20")){$miplib="SOURCE_DECLARED"};$plan.Add([pscustomobject]@{source_id=$data.source_id;periods=$data.period_count;items=$data.item_count;families=$data.family_count;bom_arcs=@($data.bill_of_materials).Count;family_setups=@($data.family_machine_setup_times).Count;miplib_overlap=$miplib;normalized_sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower();admission_state="WAITING_MODEL_EXTENSION"})|Out-Null}
$plan|Sort-Object source_id|Export-Csv -LiteralPath (Join-Path $reportRoot "MULTILSB-ATOMIC-ADMISSION-PLAN-v0.30.0.csv") -NoTypeInformation -Encoding UTF8
$surface=@(
  "LotSizingDataModel.Core\SupplyChain.cs",
  "LotSizingDataModel.Core\Building\SupplyChainModelBuilder.cs",
  "LotSizingDataModel.Core\Validation\SupplyChainValidator.cs",
  "LotSizingDataModel.Instance\Classification\LotSizingProblemFeatures.cs",
  "LotSizingDataModel.Instance\Classification\LotSizingProblemFeatureExtractor.cs",
  "LotSizingDataModel.Solver\Formulation\StandardLotSizingFormulationFactory.cs",
  "LotSizingDataModel.Solver\Formulation\SetupVariableFamilyBuilder.cs",
  "LotSizingDataModel.Solver\Formulation\ProductionSetupLinkConstraintFamilyBuilder.cs",
  "LotSizingDataModel.Solver\Formulation\WorkCenterCapacityConstraintFamilyBuilder.cs"
)
$surfaceRows=New-Object System.Collections.Generic.List[object]
foreach($relative in $surface){$path=Join-Path $ModelRepo $relative;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ("Model surface file missing: "+$relative)};$surfaceRows.Add([pscustomobject]@{relative_path=$relative;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower();required_change="YES";rollback_policy="RESTORE_EXACT_BACKUP"})|Out-Null}
$surfaceRows|Export-Csv -LiteralPath (Join-Path $reportRoot "MODEL-EXTENSION-SURFACE-v0.30.0.csv") -NoTypeInformation -Encoding UTF8
$registryCandidates=@((Join-Path $BenchmarkRepo "catalog\global\GLOBAL-BENCHMARK-REGISTRY-v0.23.0.csv"),(Join-Path $BenchmarkRepo "catalog\global\GLOBAL-BENCHMARK-REGISTRY-v0.21.0.csv"));$registryPath=$null;foreach($candidate in $registryCandidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){$registryPath=$candidate;break}};if($null -eq $registryPath){throw "Registry baseline missing."};$registry=@(Import-Csv -LiteralPath $registryPath);if($registry.Count -ne 7905){throw "Registry baseline invariant failed."}
$gate=[ordered]@{release="v0.30.0";baseline_rows=7905;candidate_rows=120;target_rows=8025;atomic=$true;automatic_rollback=$true;existing_xml_rewrite_allowed=$false;trust_promotion_allowed=$false;required_model_surface_files=$surface.Count;miplib_identity_claims=0;miplib_source_declared_candidates=3;current_decision="BLOCKED_UNTIL_FAMILY_SETUP_EXTENSION_COMPILES_AND_TESTS"}
$gate|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $reportRoot "ATOMIC-ADMISSION-GATE-v0.30.0.json") -Encoding UTF8
Write-Host "ATOMIC_MULTILSB_ADMISSION_GATE_V0.30.0"
Write-Host "BASELINE_ROWS|7905"
Write-Host "CANDIDATES|120"
Write-Host "TARGET_ROWS|8025"
Write-Host "MODEL_SURFACE|9"
Write-Host "MIPLIB_IDENTITY_CLAIMS|0"
Write-Host "ADMISSION|BLOCKED_MODEL_EXTENSION"
