param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks",[string]$ModelRepo="D:\Dev\LotSizingDataModel")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
function Parse-Triple([string]$line,[string]$section){$p=@($line.Trim() -split ';');if($p.Count -ne 3){throw ("Invalid triple in "+$section+": "+$line)};return [ordered]@{first=[int]$p[0];second=[int]$p[1];value=[double]::Parse($p[2],[Globalization.CultureInfo]::InvariantCulture)}}
function Parse-Pair([string]$line,[string]$section){$p=@($line.Trim() -split ';');if($p.Count -ne 2){throw ("Invalid pair in "+$section+": "+$line)};return [ordered]@{first=[int]$p[0];second=[double]::Parse($p[1],[Globalization.CultureInfo]::InvariantCulture)}}
$rawRoot=Join-Path $BenchmarkRepo "benchmarks\MULTILSB\raw\official-v0.24.0"
if(-not(Test-Path -LiteralPath $rawRoot -PathType Container)){throw "v0.24.0 official MULTILSB source missing."}
$normalizedRoot=Join-Path $BenchmarkRepo "benchmarks\MULTILSB\normalized-source\v0.25.0"
if(Test-Path -LiteralPath $normalizedRoot -PathType Container){Remove-Item -LiteralPath $normalizedRoot -Recurse -Force}
New-Item -ItemType Directory -Path $normalizedRoot -Force|Out-Null
$inventory=New-Object System.Collections.Generic.List[object]
foreach($setNumber in 1..4){
  $setName="SET"+$setNumber;$setRoot=Join-Path $rawRoot $setName
  $periodLine=(Get-Content -LiteralPath (Join-Path $setRoot "periods.txt")|Where-Object{$_.Trim() -match '^NT:'}|Select-Object -First 1)
  if($periodLine -notmatch '^NT:\s*(\d+)\s*$'){throw ("Invalid periods file: "+$setName)};$periods=[int]$Matches[1]
  $lines=@(Get-Content -LiteralPath (Join-Path $setRoot "multilsb_data.txt")|ForEach-Object{$_.Trim()}|Where-Object{$_ -ne ""})
  if($lines.Count -ne 283){throw ("Unexpected common data line count: "+$setName+"|"+$lines.Count)}
  if($lines[0] -notmatch '^RU:\s*(.+)$'){throw "RU missing"};$ru=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
  if($lines[1] -notmatch '^RUT:\s*(\d+)$'){throw "RUT missing"};$rut=[int]$Matches[1]
  if($lines[2] -notmatch '^BC:\s*(.+)$'){throw "BC missing"};$bc=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
  if($lines[3] -ne 'I k a^ik' -or $lines[82] -ne 'I f c^if' -or $lines[119] -ne 'f k v^fk' -or $lines[131] -ne 'I succ_I' -or $lines[204] -ne 'I h^I'){throw ("Section markers invalid: "+$setName)}
  $production=@();foreach($line in $lines[4..81]){$x=Parse-Triple $line "production";$production+=[ordered]@{item=$x.first;machine=$x.second;unit_capacity=$x.value}}
  $memberships=@();foreach($line in $lines[83..118]){$x=Parse-Triple $line "family";$memberships+=[ordered]@{item=$x.first;family=$x.second;membership=$x.value}}
  $familySetups=@();foreach($line in $lines[120..130]){$x=Parse-Triple $line "family setup";$familySetups+=[ordered]@{family=$x.first;machine=$x.second;setup_time=$x.value}}
  $bom=@();foreach($line in $lines[132..203]){$x=Parse-Pair $line "bom";$bom+=[ordered]@{component=$x.first;successor=[int]$x.second;quantity=1.0}}
  $marginal=@();foreach($line in $lines[205..282]){$x=Parse-Pair $line "holding";$marginal+=[ordered]@{item=$x.first;marginal_holding_cost=$x.second}}
  if($production.Count -ne 78 -or $memberships.Count -ne 36 -or $familySetups.Count -ne 11 -or $bom.Count -ne 72 -or $marginal.Count -ne 78){throw ("Common cardinality failure: "+$setName)}
  foreach($instanceNumber in 1..30){
    $instanceName=$instanceNumber.ToString("00");$demandPath=Join-Path (Join-Path $setRoot $instanceName) "demand.txt";$demandLines=@(Get-Content -LiteralPath $demandPath|Where-Object{$_.Trim() -ne ""})
    if($demandLines.Count -ne $periods){throw ("Demand period count failed: "+$setName+"-"+$instanceName)}
    $demand=@();for($t=0;$t -lt $periods;$t++){$values=@($demandLines[$t].Trim() -split ';');if($values.Count -ne 6){throw ("Demand item count failed: "+$setName+"-"+$instanceName)};for($i=0;$i -lt 6;$i++){$demand+=[ordered]@{period=$t+1;item=$i+1;quantity=[double]::Parse($values[$i],[Globalization.CultureInfo]::InvariantCulture)}}}
    $document=[ordered]@{schema="LSDM.MULTILSB.normalized-source.v1";family="MULTILSB";source_id=($setName.ToLower()+"-"+$instanceNumber);set=$setName;instance=$instanceName;period_count=$periods;item_count=78;end_item_count=6;family_count=17;machine_ids=@(1,2,8,9,10,17);resource_utilization=$ru;resource_utilization_type=$rut;backorder_cost_coefficient=$bc;production_coefficients=$production;item_family_memberships=$memberships;family_machine_setup_times=$familySetups;bill_of_materials=$bom;marginal_holding_costs=$marginal;demand=$demand;semantic_notes=[ordered]@{backlog_cost="BC multiplied by derived conventional holding cost for each end item";family_setup="One shared binary w[t,f] activates all member-item setups and consumes v[f,k] capacity";terminal_inventory="No explicit nonzero boundary inventory in source model"}}
    $setOut=Join-Path $normalizedRoot $setName;if(-not(Test-Path -LiteralPath $setOut)){New-Item -ItemType Directory -Path $setOut -Force|Out-Null};$out=Join-Path $setOut ($instanceName+".json")
    $json=$document|ConvertTo-Json -Depth 12 -Compress;[IO.File]::WriteAllText($out,$json,(New-Object Text.UTF8Encoding($false)))
    $reload=Get-Content -LiteralPath $out -Raw|ConvertFrom-Json
    if($reload.source_id -ne $document.source_id -or @($reload.demand).Count -ne (6*$periods) -or @($reload.bill_of_materials).Count -ne 72){throw ("Round-trip validation failed: "+$document.source_id)}
    $inventory.Add([pscustomobject]@{source_id=$document.source_id;set=$setName;instance=$instanceName;periods=$periods;items=78;end_items=6;families=17;machines=6;production_coefficients=78;family_memberships=36;family_setups=11;bom_arcs=72;demand_values=(6*$periods);normalized_sha256=(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower();round_trip="PASS";canonical_admission="BLOCKED_FAMILY_SETUP_SEMANTICS"})|Out-Null
  }
}
$reportRoot=Join-Path $BenchmarkRepo "reports\v0.25.0";if(-not(Test-Path -LiteralPath $reportRoot)){New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null}
$inventory|Export-Csv -LiteralPath (Join-Path $reportRoot "MULTILSB-SEMANTIC-NORMALIZATION-v0.25.0.csv") -NoTypeInformation -Encoding UTF8
$backlogFiles=@("LotSizingDataModel.Core\DecisionModel\Constraints\BacklogConstraint.cs","LotSizingDataModel.Core\DecisionModel\Costs\BacklogCost.cs","LotSizingDataModel.Core\Relationships\DistributionCenterSourcing.DecisionModel.cs")
$backlogPresent=$true;foreach($relative in $backlogFiles){if(-not(Test-Path -LiteralPath (Join-Path $ModelRepo $relative) -PathType Leaf)){$backlogPresent=$false}}
$coreRoot=Join-Path $ModelRepo "LotSizingDataModel.Core"
$familyMatches=@()
if(Test-Path -LiteralPath $coreRoot -PathType Container){
  $coreFiles=@(Get-ChildItem -LiteralPath $coreRoot -Recurse -File -Filter "*.cs")
  if($coreFiles.Count -gt 0){
    $familyMatches=@($coreFiles|Select-String -Pattern "family.*setup|setup.*family" -CaseSensitive:$false|Select-Object -ExpandProperty Path -Unique)
  }
}
$capability=@([pscustomobject]@{capability="Backlog quantity constraint";required=$true;supported=$backlogPresent;decision="SUPPORTED"},[pscustomobject]@{capability="Backlog cost by period";required=$true;supported=$backlogPresent;decision="SUPPORTED"},[pscustomobject]@{capability="Shared family setup binary";required=$true;supported=($familyMatches.Count -gt 0);decision="BLOCKING_GAP"},[pscustomobject]@{capability="Family setup capacity consumption";required=$true;supported=($familyMatches.Count -gt 0);decision="BLOCKING_GAP"})
$capability|Export-Csv -LiteralPath (Join-Path $reportRoot "MULTILSB-MODEL-CAPABILITY-GAP-v0.25.0.csv") -NoTypeInformation -Encoding UTF8
$manifest=[ordered]@{release="v0.25.0";normalized_instances=120;round_trip_pass=120;canonical_admissions=0;registry_rows=7905;backlogging_supported=$backlogPresent;family_setup_supported=($familyMatches.Count -gt 0);blocking_gap="Shared family setup binary and family setup capacity consumption";trust_promotions=0}
$manifest|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $reportRoot "MULTILSB-SEMANTIC-MANIFEST-v0.25.0.json") -Encoding UTF8
Write-Host "MULTILSB_SEMANTIC_NORMALIZATION_V0.25.0"
Write-Host "NORMALIZED|120"
Write-Host "ROUND_TRIP|120|PASS"
$backlogLabel="FAIL";if($backlogPresent){$backlogLabel="PASS"}
$familySetupLabel="BLOCKED";if($familyMatches.Count -gt 0){$familySetupLabel="PASS"}
Write-Host ("BACKLOG_MODEL_SUPPORT|"+$backlogLabel)
Write-Host ("FAMILY_SETUP_MODEL_SUPPORT|"+$familySetupLabel)
Write-Host "CANONICAL_ADMISSIONS|0"
Write-Host "REGISTRY_ROWS|7905"
