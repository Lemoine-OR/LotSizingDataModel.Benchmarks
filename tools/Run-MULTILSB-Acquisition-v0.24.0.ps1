param([string]$BenchmarkRepo="D:\Dev\LotSizingDataModel.Benchmarks")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$familyRoot=Join-Path $BenchmarkRepo "benchmarks\MULTILSB"
$rawRoot=Join-Path $familyRoot "raw"
$archive=Join-Path $rawRoot "multilsbnew.zip"
$officialRoot=Join-Path $rawRoot "official-v0.24.0"
if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){throw "Official MULTILSB archive missing."}
if(Test-Path -LiteralPath $officialRoot -PathType Container){Remove-Item -LiteralPath $officialRoot -Recurse -Force}
Expand-Archive -LiteralPath $archive -DestinationPath $officialRoot -Force
$rows=New-Object System.Collections.Generic.List[object]
foreach($setNumber in 1..4){
  $setName="SET"+$setNumber
  $setRoot=Join-Path $officialRoot $setName
  $common=Join-Path $setRoot "multilsb_data.txt"
  $periods=Join-Path $setRoot "periods.txt"
  if(-not(Test-Path -LiteralPath $common -PathType Leaf)){throw ("Common data missing: "+$setName)}
  if(-not(Test-Path -LiteralPath $periods -PathType Leaf)){throw ("Periods missing: "+$setName)}
  foreach($instanceNumber in 1..30){
    $instanceName=$instanceNumber.ToString("00")
    $demand=Join-Path (Join-Path $setRoot $instanceName) "demand.txt"
    if(-not(Test-Path -LiteralPath $demand -PathType Leaf)){throw ("Demand missing: "+$setName+"-"+$instanceName)}
    $rows.Add([pscustomobject]@{
      family="MULTILSB";set=$setName;instance=$instanceName;source_id=($setName.ToLower()+"-"+$instanceNumber)
      common_data_sha256=(Get-FileHash -LiteralPath $common -Algorithm SHA256).Hash.ToLower()
      periods_sha256=(Get-FileHash -LiteralPath $periods -Algorithm SHA256).Hash.ToLower()
      demand_sha256=(Get-FileHash -LiteralPath $demand -Algorithm SHA256).Hash.ToLower()
      acquisition_status="OFFICIAL_RAW_ACQUIRED";canonical_status="NOT_ADMITTED_MODEL_MAPPING_REQUIRED"
    })|Out-Null
  }
}
$reportRoot=Join-Path $BenchmarkRepo "reports\v0.24.0"
if(-not(Test-Path -LiteralPath $reportRoot)){New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null}
$inventory=Join-Path $reportRoot "MULTILSB-OFFICIAL-INVENTORY-v0.24.0.csv"
$rows|Export-Csv -LiteralPath $inventory -NoTypeInformation -Encoding UTF8
$crosswalk=@(
  [pscustomobject]@{multilsb_id="set3-10";miplib_name="set3-10";relationship="SOURCE_DECLARED_OVERLAP";verification="IDENTITY_NOT_FINGERPRINT_VERIFIED"},
  [pscustomobject]@{multilsb_id="set3-15";miplib_name="set3-15";relationship="SOURCE_DECLARED_OVERLAP";verification="IDENTITY_NOT_FINGERPRINT_VERIFIED"},
  [pscustomobject]@{multilsb_id="set3-20";miplib_name="set3-20";relationship="SOURCE_DECLARED_OVERLAP";verification="IDENTITY_NOT_FINGERPRINT_VERIFIED"}
)
$crosswalk|Export-Csv -LiteralPath (Join-Path $reportRoot "MULTILSB-MIPLIB-CROSSWALK-v0.24.0.csv") -NoTypeInformation -Encoding UTF8
$registryCandidates=@(
  (Join-Path $BenchmarkRepo "catalog\global\GLOBAL-BENCHMARK-REGISTRY-v0.23.0.csv"),
  (Join-Path $BenchmarkRepo "catalog\global\GLOBAL-BENCHMARK-REGISTRY-v0.21.0.csv")
)
$registryPath=$null
foreach($candidate in $registryCandidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){$registryPath=$candidate;break}}
if($null -eq $registryPath){throw "Validated registry baseline missing."}
$registry=@(Import-Csv -LiteralPath $registryPath)
if($registry.Count -ne 7905){throw "Registry row invariant failed."}
$idColumn=@("global_instance_id","global_id","instance_id")|Where-Object{$registry[0].PSObject.Properties.Name -contains $_}|Select-Object -First 1
if($null -eq $idColumn){throw "Global ID column missing."}
$unique=@($registry|ForEach-Object{$_.$idColumn}|Sort-Object -Unique)
if($unique.Count -ne 7905){throw "Global IDs are not unique."}
$manifest=[ordered]@{
  release="v0.24.0";family="MULTILSB";source="University of Strathclyde Pure"
  doi="10.15129/252b7827-b62b-4af4-8869-64b12b1c69a1";license="CC BY 4.0"
  archive_sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
  sets=4;instances_per_set=30;raw_instances=120;canonical_admissions=0
  canonical_blocker="Backlogging semantics require an explicit lossless model mapping before XML admission."
  miplib_source_declared_overlap=@("set3-10","set3-15","set3-20")
  trust_policy="LP bounds and heuristic values are preserved as source evidence; neither is promoted to proven optimum."
}
$manifest|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $reportRoot "MULTILSB-ACQUISITION-MANIFEST-v0.24.0.json") -Encoding UTF8
Write-Host "MULTILSB_ACQUISITION_V0.24.0"
Write-Host "RAW_INSTANCES|120"
Write-Host "SETS|4|30"
Write-Host "MIPLIB_SOURCE_OVERLAPS|3"
Write-Host "CANONICAL_ADMISSIONS|0"
Write-Host "REGISTRY_ROWS|7905"
