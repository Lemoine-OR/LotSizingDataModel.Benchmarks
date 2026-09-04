param(
 [string]$BenchmarkRepo='D:\Dev\LotSizingDataModel.Benchmarks',
 [string]$ModelRepo='D:\Dev\LotSizingDataModel',
 [Parameter(Mandatory=$true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'PowerShell 5.1 required'}
$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$t,[ref]$e);if($e.Count){throw 'Parser guard failed'}
$model=[IO.Path]::GetFullPath($ModelRepo).TrimEnd('\')
$repo=[IO.Path]::GetFullPath($BenchmarkRepo).TrimEnd('\')
$out=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if($out -eq $repo -or $out.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase) -or $out -eq $model -or $out.StartsWith($model+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be outside source repositories'}
if(Test-Path $out){throw 'Output directory must be new'}
if((Get-Content (Join-Path $model 'version.json') -Raw | ConvertFrom-Json).version -ne '1.3.0'){throw 'Requires DataModel 1.3.0'}
$preflight=@{
 'LotSizingDataModel.Instance\Classification\LotSizingProblemFeatureExtractor.cs'='public static class LotSizingProblemFeatureExtractor';
 'LotSizingDataModel.Instance\Descriptors\LotSizingProblemDescriptor.cs'='FromLegacyFeatures';
 'LotSizingDataModel.Instance\Notation\UniversalNotationGenerator.cs'='public sealed class UniversalNotationGenerator';
 'LotSizingDataModel.Instance\Notation\Lsi\Lsi10ScientificProjector.cs'='public sealed class Lsi10ScientificProjector';
 'LotSizingDataModel.Core\SupplyChain.LegacySerialization.cs'='ShouldSerializeSalesOptions';
 'LotSizingDataModel.Core\Relationships\Inventory.LegacySerialization.cs'='ShouldSerializeInitialInventoryDecisionMode'
}
foreach($relative in $preflight.Keys){$p=Join-Path $model $relative;if(-not(Test-Path $p) -or -not [IO.File]::ReadAllText($p).Contains($preflight[$relative])){throw ('Exact-symbol preflight failed: '+$relative)}}
$project=Join-Path $PSScriptRoot 'DataModelAlignment\DataModelAlignment.csproj'
$sourceFiles=@(Get-ChildItem (Join-Path $PSScriptRoot 'DataModelAlignment'),(Join-Path $model 'LotSizingDataModel.Core'),(Join-Path $model 'LotSizingDataModel.Solution'),(Join-Path $model 'LotSizingDataModel.Instance') -Recurse -File | Where-Object {$_.Extension -in @('.cs','.csproj') -and $_.FullName -notmatch '\\(bin|obj)\\'})
$sourceFiles+=Get-Item (Join-Path $model 'version.json'),(Join-Path $model 'Directory.Build.props'),(Join-Path $model 'Directory.Build.targets')
New-Item -ItemType Directory -Path $out | Out-Null
$snapshot=@($sourceFiles | ForEach-Object {[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash -LiteralPath $_.FullName).Hash;utc=$_.LastWriteTimeUtc.ToString('o')}})
$snapshot | Export-Csv (Join-Path $out 'source-snapshot.csv') -NoTypeInformation -Encoding UTF8
$start=[DateTime]::UtcNow
& dotnet build $project -c Release --no-incremental ('-p:ModelRepo='+$model) *> (Join-Path $out 'build.log')
if($LASTEXITCODE -ne 0){throw 'Fresh build failed; see build.log'}
$dll=Join-Path $PSScriptRoot 'DataModelAlignment\bin\Release\net10.0\DataModelAlignment.dll'
if((Get-Item $dll).LastWriteTimeUtc -lt $start){throw 'Fresh-build timestamp guard failed'}
foreach($s in $snapshot){if((Get-FileHash -LiteralPath $s.path).Hash -ne $s.hash -or (Get-Item $s.path).LastWriteTimeUtc.ToString('o') -ne $s.utc){throw ('Source changed during build: '+$s.path)}}
$candidate=Join-Path $out 'candidate'
& dotnet $dll (Join-Path $repo 'catalog\global\GLOBAL-BENCHMARK-REGISTRY-v1.0.0.json') $candidate 7905 *> (Join-Path $out 'reclassification.log')
if($LASTEXITCODE -ne 0){throw 'Preservation guard failed; see candidate/preservation-evidence.json'}
foreach($s in $snapshot){if((Get-FileHash -LiteralPath $s.path).Hash -ne $s.hash){throw ('Source changed during classification: '+$s.path)}}
& (Join-Path $PSScriptRoot 'Publish-DataModelAlignmentR2.ps1') -CandidateDirectory $candidate -OutputRoot (Join-Path $out 'generated') -BenchmarkRepo $repo
foreach($asset in @('app.js','style.css')){Copy-Item -LiteralPath (Join-Path $repo ('docs\benchmarks\alignment-r2\'+$asset)) -Destination (Join-Path $out ('generated\docs\benchmarks\alignment-r2\'+$asset))}
Write-Output 'CLASSIFICATION_PRESERVATION_VALID|7905'
Write-Output 'Final package validation remains mandatory.'
