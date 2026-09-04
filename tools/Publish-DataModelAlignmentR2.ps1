param(
 [Parameter(Mandatory=$true)][string]$CandidateDirectory,
 [Parameter(Mandatory=$true)][string]$OutputRoot,
 [string]$BenchmarkRepo='D:\Dev\LotSizingDataModel.Benchmarks'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'PowerShell 5.1 required'}
$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$t,[ref]$e);if($e.Count){throw 'Parser guard failed'}
$rows=Get-Content (Join-Path $CandidateDirectory 'classification-candidate.json') -Raw | ConvertFrom-Json
$evidence=Get-Content (Join-Path $CandidateDirectory 'preservation-evidence.json') -Raw | ConvertFrom-Json
$baseline=Get-Content (Join-Path $BenchmarkRepo 'catalog\global\GLOBAL-BENCHMARK-REGISTRY-v1.0.0.json') -Raw | ConvertFrom-Json
if($rows.Count -ne 7905 -or $evidence.Count -ne 7905 -or $baseline.Count -ne 7905){throw 'ROWS guard failed'}
if(@($evidence | Where-Object {-not $_.pass}).Count){throw 'XML/fingerprint/known result preservation failed'}
$byId=@{};foreach($r in $baseline){$byId[$r.global_instance_id]=$r}
foreach($row in $rows){
 if(-not $byId.ContainsKey($row.global_instance_id)){throw 'Unknown global ID'}
 foreach($p in $byId[$row.global_instance_id].PSObject.Properties){if(($row.($p.Name) | ConvertTo-Json -Compress -Depth 20) -cne ($p.Value | ConvertTo-Json -Compress -Depth 20)){throw ('Original registry field changed: '+$row.global_instance_id+'/'+$p.Name)}}
 foreach($field in @('UniversalNotation','Lsi10Notation','LegacyFamily')){if([string]::IsNullOrWhiteSpace($row.$field)){throw ('Missing '+$field)}}
 if($row.DataModelVersion -ne '1.3.0'){throw 'DataModelVersion mismatch'}
}
if(@($rows | Group-Object global_instance_id | Where-Object {$_.Count -gt 1}).Count -or @($rows | Group-Object fingerprint | Where-Object {$_.Count -gt 1}).Count){throw 'Duplicate identity/fingerprint'}
$guardPath=Join-Path $BenchmarkRepo 'catalog\global\GLOBAL-G30-G30B-NONIDENTITY-GUARD.csv'
$guard=@(Import-Csv $guardPath)
if($guard.Count -ne 1 -or $guard[0].status -ne 'PASS_NON_IDENTITY_GUARD' -or $guard[0].prohibited_name_merge -ne 'G30b'){throw 'G30/G30b guard definition changed'}
$g30=@($rows | Where-Object {$_.global_instance_id -eq $guard[0].authoritative_instance})
if($g30.Count -ne 1 -or $g30[0].fingerprint -ne $guard[0].authoritative_fingerprint){throw 'G30 authoritative identity changed'}
if(@($rows | Where-Object {$_.original_instance_id -eq 'G30b' -and $_.fingerprint -eq $g30[0].fingerprint}).Count){throw 'G30/G30b identity collapse'}
$catalog=Join-Path $OutputRoot 'catalog\global'
$pages=Join-Path $OutputRoot 'docs\benchmarks\alignment-r2'
$reports=Join-Path $OutputRoot 'reports\alignment-r2'
New-Item -ItemType Directory -Force $catalog,$pages,$reports | Out-Null
Copy-Item (Join-Path $CandidateDirectory 'classification-candidate.json') (Join-Path $catalog 'GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.json')
$csvRows=foreach($r in $rows){$flat=[ordered]@{};foreach($p in $r.PSObject.Properties){$flat[$p.Name]=if($null -eq $p.Value){''}elseif($p.Value -is [pscustomobject] -or $p.Value -is [Array]){ConvertTo-Json -InputObject $p.Value -Depth 30 -Compress}else{$p.Value}};[pscustomobject]$flat}
$csvRows | Export-Csv (Join-Path $catalog 'GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.csv') -NoTypeInformation -Encoding UTF8
Copy-Item (Join-Path $CandidateDirectory 'preservation-evidence.json') (Join-Path $reports 'preservation-evidence.json')
Copy-Item $guardPath (Join-Path $reports 'G30-G30b-preserved-guard.csv')
$challenges=@(Import-Csv (Join-Path $BenchmarkRepo 'catalog\global\GLOBAL-OPEN-CHALLENGES-v1.0.0.csv'))
$challengeMap=@{};foreach($c in $challenges){if(-not $challengeMap.ContainsKey($c.global_instance_id)){$challengeMap[$c.global_instance_id]=New-Object 'System.Collections.Generic.List[string]'};$challengeMap[$c.global_instance_id].Add($c.challenge_type+': '+$c.reason+' Resolution: '+$c.resolution_criterion)}
$repoPrefix=[IO.Path]::GetFullPath($BenchmarkRepo).TrimEnd('\')+'\'
$data=foreach($r in $rows){
 $path=[IO.Path]::GetFullPath($r.canonical_xml_path)
 if(-not $path.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'XML outside repository'}
 $setups=@($r.SetupFeatures.PSObject.Properties | Where-Object {$_.Value -eq $true} | ForEach-Object {$_.Name})
 [ordered]@{id=$r.global_instance_id;family=$r.family;legacy=$r.LegacyFamily;lsi=$r.Lsi10Notation;universal=$r.UniversalNotation;structure=$r.ProductStructureDetected;declared=$r.ProductStructureDeclared;capacity=$r.CapacityProfile.Regime;setups=$(if($setups.Count){$setups -join ', '}else{'None detected'});scheduling=($r.SchedulingFeatures | ConvertTo-Json -Depth 10 -Compress);status=$r.trust_status;challenge=$(if($challengeMap.ContainsKey($r.global_instance_id)){$challengeMap[$r.global_instance_id] -join ' / '}else{''});items=$r.DetectedItemCount;periods=$r.DetectedPlanningHorizon;objective=$r.objective_reference;url=('../../../'+$path.Substring($repoPrefix.Length).Replace('\','/'));confidence=$r.ClassificationConfidence;warnings=$r.ClassificationWarnings}
}
[IO.File]::WriteAllText((Join-Path $pages 'data.js'),('window.ALIGNMENT_DATA='+ (ConvertTo-Json -InputObject @($data) -Depth 30 -Compress)+';'),(New-Object Text.UTF8Encoding($false)))
$views=[ordered]@{family='Bibliographic family';legacy='Legacy family';lsi='LSI 1.0';structure='Product structure';capacity='Capacity';setups='Setups';scheduling='Scheduling';status='Status';challenge='Open challenges'}
foreach($key in $views.Keys){
 $title=$views[$key]
 $html=@"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>$title — LotSizing benchmarks</title><link rel="stylesheet" href="style.css"></head>
<body data-view="$key"><header><p>LotSizingDataModel 1.3.0 · Alignment R2</p><h1>$title</h1><p>7,905 preserved instances · scientific classification generated by DataModel</p><nav id="nav"></nav></header>
<main><label>Search <input id="search" type="search" placeholder="ID, classification, family…"></label><label>Group <select id="group"><option value="">All groups</option></select></label><p id="summary"></p><div class="table"><table><thead><tr><th>Instance</th><th>Family / legacy</th><th>Structure / capacity</th><th>Size</th><th>Status / reference</th><th>Classification</th></tr></thead><tbody id="rows"></tbody></table></div><button id="previous">Previous</button><span id="pagination"></span><button id="next">Next</button><p>Confidence is unavailable from the current projection API. Unknown reference results remain unknown. Classifications describe the represented data.</p><a href="../../../catalog/global/GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.json">Full registry JSON</a> · <a href="../../../catalog/global/GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.csv">CSV</a></main><script src="data.js"></script><script src="app.js"></script></body></html>
"@
 [IO.File]::WriteAllText((Join-Path $pages ($key+'.html')),$html,(New-Object Text.UTF8Encoding($false)))
}
Copy-Item (Join-Path $pages 'family.html') (Join-Path $pages 'index.html')
$summary=[ordered]@{rows=$rows.Count;xmlSemanticPreservation='PASS';globalIds='PASS';fingerprints='PASS';knownResults='PASS';universalNotation=$rows.Count;lsi10=$rows.Count;g30G30bNonIdentity='PASS';globalRegistry='PASS';classificationConfidence='UNAVAILABLE';pages='GENERATED_PENDING_VERIFICATION';baseline='v1.0.0';dataModelVersion='1.3.0'}
$summary | ConvertTo-Json | Set-Content (Join-Path $reports 'classification-summary.json') -Encoding UTF8
Write-Output 'REGISTRY_AND_PAGES_GENERATED|7905'
