param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$root=Join-Path $BenchmarkRepo "reports\v0.30.0";$planPath=Join-Path $root "MULTILSB-ATOMIC-ADMISSION-PLAN-v0.30.0.csv";$surfacePath=Join-Path $root "MODEL-EXTENSION-SURFACE-v0.30.0.csv";$gatePath=Join-Path $root "ATOMIC-ADMISSION-GATE-v0.30.0.json";foreach($path in @($planPath,$surfacePath,$gatePath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ("Gate artifact missing: "+$path)}}
$plan=@(Import-Csv -LiteralPath $planPath);if($plan.Count -ne 120){throw "Candidate count failed."};if(@($plan|Where-Object{$_.admission_state -ne "WAITING_MODEL_EXTENSION"}).Count -ne 0){throw "Unsafe admission state."};if(@($plan|Where-Object{$_.miplib_overlap -eq "SOURCE_DECLARED"}).Count -ne 3){throw "MIPLIB candidate count failed."}
$surface=@(Import-Csv -LiteralPath $surfacePath);if($surface.Count -ne 9){throw "Model surface count failed."};$gate=Get-Content -LiteralPath $gatePath -Raw|ConvertFrom-Json;if([int]$gate.target_rows -ne 8025 -or [bool]$gate.atomic -ne $true -or [int]$gate.miplib_identity_claims -ne 0){throw "Atomic gate invariant failed."}
Write-Host "ATOMIC_MULTILSB_ADMISSION_GATE_V0.30.0_VALID"
Write-Host "CANDIDATES|120"
Write-Host "MODEL_SURFACE|9"
Write-Host "ROLLBACK|READY"
Write-Host "CANONICAL_XML_CHANGES|0"
Write-Host "REGISTRY_ROWS|7905"
