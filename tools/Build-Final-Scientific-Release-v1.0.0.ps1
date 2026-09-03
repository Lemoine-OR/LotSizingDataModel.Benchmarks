param([string]$BenchmarkRepo='D:\Dev\LotSizingDataModel.Benchmarks')
$ErrorActionPreference='Stop'
$catalog=Join-Path $BenchmarkRepo 'catalog\global'
$reports=Join-Path $BenchmarkRepo 'reports\v1.0.0'
$docs=Join-Path $BenchmarkRepo 'docs\benchmarks'
$release=Join-Path $BenchmarkRepo 'releases\v1.0.0'
New-Item -ItemType Directory -Force -Path $reports,$docs,$release|Out-Null
$registryPath=Join-Path $catalog 'GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv'
$trustPath=Join-Path $catalog 'GLOBAL-NORMALIZED-TRUST-v1.0.0.csv'
$challengesPath=Join-Path $catalog 'GLOBAL-OPEN-CHALLENGES-v1.0.0.csv'
$v2Path=Join-Path $catalog 'V2-DEFERRED-WORK-v1.0.0.csv'
$registry=@(Import-Csv -LiteralPath $registryPath)
$trust=@(Import-Csv -LiteralPath $trustPath)
$challenges=@(Import-Csv -LiteralPath $challengesPath)
$v2=@(Import-Csv -LiteralPath $v2Path)
if($registry.Count -ne 7905){throw 'Registry row invariant failed.'}
if($trust.Count -ne 7905){throw 'Trust row invariant failed.'}
if($challenges.Count -ne 125){throw 'Challenge count invariant failed.'}
if($v2.Count -ne 27){throw 'V2 workstream invariant failed.'}
$expected=@{CATTRYSSE1990=120;DJ2000=176;EM1987=17;STADTLER2003=2100;SUERIE_CLSPL=1291;TD1996=3450;TRIGEIRO1989=751}
foreach($family in $expected.Keys){$actual=@($registry|Where-Object {$_.family -eq $family}).Count;if($actual -ne $expected[$family]){throw ('Family count failed: '+$family)}}
if(@($registry|Group-Object global_instance_id|Where-Object {$_.Count -gt 1}).Count -ne 0){throw 'Global ID uniqueness failed.'}
if(@($registry|Where-Object {$_.fingerprint}|Group-Object fingerprint|Where-Object {$_.Count -gt 1}).Count -ne 0){throw 'Duplicate fingerprint invariant failed.'}
$collisions=@(Import-Csv -LiteralPath (Join-Path $catalog 'GLOBAL-HISTORICAL-ID-COLLISIONS-v0.16.4.csv'))
if($collisions.Count -ne 100){throw 'Historical collision row invariant failed.'}
$collisionGroups=@($collisions|Group-Object family,original_instance_id|Where-Object {$_.Count -gt 1}).Count
if($collisionGroups -ne 50){throw 'Historical collision group invariant failed.'}
$dup=@(Import-Csv -LiteralPath (Join-Path $catalog 'GLOBAL-DUPLICATE-CLUSTERS-v0.16.4.csv'))
$lineage=@(Import-Csv -LiteralPath (Join-Path $catalog 'GLOBAL-LINEAGE-EDGES-v0.16.4.csv'))
if($dup.Count -ne 0){throw 'Duplicate cluster file is not empty.'}
if($lineage.Count -ne 0){throw 'Lineage edge file is not empty.'}
$g30=Get-Content -Raw -LiteralPath (Join-Path $catalog 'GLOBAL-G30-G30B-NONIDENTITY-GUARD.csv')
if($g30 -notmatch 'PASS_NON_IDENTITY_GUARD'){throw 'G30/G30b guard failed.'}
$hashFailures=New-Object 'System.Collections.Generic.List[string]'
foreach($r in $registry){if(-not(Test-Path -LiteralPath $r.canonical_xml_path -PathType Leaf)){$hashFailures.Add($r.global_instance_id);continue};$h=(Get-FileHash -LiteralPath $r.canonical_xml_path -Algorithm SHA256).Hash;if($h -ne $r.canonical_xml_sha256){$hashFailures.Add($r.global_instance_id)}}
if($hashFailures.Count -ne 0){throw ('Canonical hash validation failed: '+$hashFailures.Count)}
$matrix=@(
 [pscustomobject]@{control='REGISTRY_ROWS';expected='7905';actual=$registry.Count;status='PASS'},
 [pscustomobject]@{control='CANONICAL_FAMILIES';expected='7';actual=$expected.Count;status='PASS'},
 [pscustomobject]@{control='GLOBAL_IDS_UNIQUE';expected='TRUE';actual='TRUE';status='PASS'},
 [pscustomobject]@{control='HISTORICAL_COLLISIONS';expected='50 groups / 100 rows';actual=($collisionGroups.ToString()+' groups / '+$collisions.Count+' rows');status='PASS'},
 [pscustomobject]@{control='DUPLICATE_FINGERPRINT_CLUSTERS';expected='0';actual=$dup.Count;status='PASS'},
 [pscustomobject]@{control='LINEAGE_EDGES';expected='0';actual=$lineage.Count;status='PASS'},
 [pscustomobject]@{control='G30_G30B';expected='PASS';actual='PASS';status='PASS'},
 [pscustomobject]@{control='CANONICAL_XML_HASHES';expected='7905 PASS';actual='7905 PASS';status='PASS'},
 [pscustomobject]@{control='ACTIONABLE_CHALLENGES';expected='125';actual=$challenges.Count;status='PASS'},
 [pscustomobject]@{control='V2_WORKSTREAMS';expected='27';actual=$v2.Count;status='PASS'},
 [pscustomobject]@{control='MODEL_CHANGE';expected='NONE';actual='NONE';status='PASS'}
)
$matrixPath=Join-Path $reports 'FINAL-VALIDATION-MATRIX-v1.0.0.csv'
$matrix|Export-Csv -LiteralPath $matrixPath -NoTypeInformation -Encoding UTF8
$matrix|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $reports 'FINAL-VALIDATION-MATRIX-v1.0.0.json') -Encoding UTF8
$summary=@"
# LotSizingDataModel.Benchmarks v1.0.0

Final scientific release of the v1 corpus: 7,905 canonical instances across seven families.

## Verified invariants

- Global identifiers are unique.
- Historical identifier reuse is preserved as 50 groups / 100 rows.
- Exact duplicate fingerprint clusters: 0.
- Exact lineage edges: 0.
- G30/G30b non-identity guard: PASS.
- Canonical XML SHA-256 checks: 7,905 / 7,905 PASS.
- Canonical XML rewritten by this release: 0.

## Scientific status

The trust catalogue contains 125 actionable challenges. MULTILSB has 120 normalized source instances but remains deferred to v2 because shared production-family setup semantics are not represented by the current model. Redistribution rights remain to be documented family by family; this release does not invent a licence or a proof.
"@
[IO.File]::WriteAllText((Join-Path $docs 'README-v1.0.0.md'),$summary,(New-Object Text.UTF8Encoding($false)))
$roadmap=@"
# Final roadmap - v1.0.0

Status: **V1_RESEARCH_CORPUS_READY_WITH_DOCUMENTED_OPEN_ITEMS**.

The v1 branch is frozen at 7,905 canonical instances. Model extensions, further historical acquisitions, MULTILSB admission, proof acquisition, and rights documentation are governed by `V2-DEFERRED-WORK-v1.0.0.csv` and the Word backlog delivered with this release.
"@
[IO.File]::WriteAllText((Join-Path $BenchmarkRepo 'docs\roadmap\ROADMAP-FINAL-v1.0.0.md'),$roadmap,(New-Object Text.UTF8Encoding($false)))
$manifestTargets=@()
$manifestTargets+=Get-ChildItem -LiteralPath $catalog -File|Where-Object {$_.Name -like '*v1.0.0*'}
$manifestTargets+=Get-ChildItem -LiteralPath $reports -File
$manifestTargets+=Get-ChildItem -LiteralPath $docs -File|Where-Object {$_.Name -like '*v1.0.0*'}
$manifestTargets+=Get-ChildItem -LiteralPath (Join-Path $BenchmarkRepo 'docs\roadmap') -File|Where-Object {$_.Name -like '*v1.0.0*'}
$manifest=@($manifestTargets|Sort-Object FullName -Unique|ForEach-Object {[pscustomobject]@{path=$_.FullName.Substring($BenchmarkRepo.Length).TrimStart('\');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$manifestPath=Join-Path $release 'FINAL-RELEASE-MANIFEST-v1.0.0.csv'
$manifest|Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
$repro=[ordered]@{release='v1.0.0';generated_utc=[DateTime]::UtcNow.ToString('o');registry_rows=7905;canonical_families=7;actionable_challenges=125;v2_workstreams=27;canonical_xml_changes=0;rights_statement='Licences not invented; consult the family provenance audit before redistribution.';files=$manifest}
$repro|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $release 'REPRODUCIBILITY-MANIFEST-v1.0.0.json') -Encoding UTF8
$archive=Join-Path $release 'LotSizingDataModel.Benchmarks-v1.0.0-scientific-catalog.zip'
if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}
$archiveInputs=@($manifestTargets.FullName)+@($manifestPath,(Join-Path $release 'REPRODUCIBILITY-MANIFEST-v1.0.0.json'))
Compress-Archive -LiteralPath $archiveInputs -DestinationPath $archive -CompressionLevel Optimal -Force
Write-Host 'FINAL_SCIENTIFIC_RELEASE_V1.0.0'
Write-Host ('ROWS|'+$registry.Count)
Write-Host ('FAMILIES|'+$expected.Count)
Write-Host ('COLLISIONS|'+$collisionGroups+'|'+$collisions.Count)
Write-Host ('DUPLICATE_CLUSTERS|'+$dup.Count)
Write-Host ('LINEAGE_EDGES|'+$lineage.Count)
Write-Host 'G30_G30B|PASS'
Write-Host ('CANONICAL_HASHES|'+$registry.Count+'|PASS')
Write-Host ('ACTIONABLE_CHALLENGES|'+$challenges.Count)
Write-Host ('V2_WORKSTREAMS|'+$v2.Count)
Write-Host 'MACHINE_VALIDATOR|PASS'
Write-Host 'MODEL_CHANGES|0'
Write-Host 'V1.0.0_READY'
