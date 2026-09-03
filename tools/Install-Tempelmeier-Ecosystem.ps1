param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [switch]$SkipDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" }
function Ensure-Dir { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Safe-Token {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
    $v=[regex]::Replace($Value.Trim(),"[^A-Za-z0-9._-]","-")
    $v=[regex]::Replace($v,"-+","-")
    return $v.Trim("-")
}
function Child-Local {
    param([System.Xml.XmlElement]$Parent,[string]$Name)
    foreach($c in $Parent.ChildNodes) {
        if($c -is [System.Xml.XmlElement] -and $c.LocalName -ieq $Name) { return $c }
    }
    return $null
}
function Save-Xml {
    param([xml]$Doc,[string]$Path)
    $settings=New-Object System.Xml.XmlWriterSettings
    $settings.Indent=$true
    $settings.Encoding=New-Object System.Text.UTF8Encoding($false)
    $writer=[System.Xml.XmlWriter]::Create($Path,$settings)
    try { $Doc.Save($writer) } finally { $writer.Dispose() }
}
function Download-Asset {
    param([string]$Url,[string]$Destination)
    Ensure-Dir (Split-Path -Parent $Destination)
    if(Test-Path -LiteralPath $Destination -PathType Leaf) {
        Write-Host ("Already present: " + $Destination)
        return $true
    }
    try {
        Write-Host ("Downloading: " + $Url)
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
        Write-Host ("Downloaded: " + $Destination)
        return $true
    } catch {
        Write-Warning ("Download failed: " + $Url + " | " + $_.Exception.Message)
        return $false
    }
}
function Detect-Family {
    param([string]$FileName,[string]$XmlName,[string]$SourceInfo)
    $text=($FileName+" "+$XmlName+" "+$SourceInfo)
    if($text -match "(?i)Buschk|MLCLSP-L|MLCLSPL|Sahling") { return "TB2009" }
    if($text -match "(?i)Suerie|CLSPL|linked lot") { return "SUERIE_CLSPL" }
    if($text -match "(?i)Stadtler|A\+|B\+|Set.?A|Set.?B") { return "STADTLER2003" }
    if($text -match "(?i)Derstroff|Tempelmeier") { return "TD1996" }
    return ""
}
function Detect-Subclass {
    param([string]$Family,[string]$Text)
    if($Family -eq "STADTLER2003") {
        if($Text -match "(?i)A\+|Aplus") { return "Set-Aplus" }
        if($Text -match "(?i)B\+|Bplus") { return "Set-Bplus" }
        if($Text -match "(?i)C\+|Cplus") { return "Set-Cplus" }
        if($Text -match "(?i)D\+|Dplus") { return "Set-Dplus" }
        if($Text -match "(?i)E\+|Eplus") { return "Set-Eplus" }
        if($Text -match "(?i)Set.?C|\bC\b") { return "Set-C" }
        if($Text -match "(?i)Set.?D|\bD\b") { return "Set-D" }
        if($Text -match "(?i)Set.?E|\bE\b") { return "Set-E" }
        return "Unclassified"
    }
    if($Family -eq "SUERIE_CLSPL") {
        if($Text -match "(?i)datab") { return "TestSet3-datab" }
        if($Text -match "(?i)datam") { return "TestSet2-datam" }
        if($Text -match "(?i)\bdata\b") { return "TestSet1-data" }
        return "Unclassified"
    }
    if($Family -eq "TB2009") {
        if($Text -match "(?i)class.?1") { return "Class1" }
        if($Text -match "(?i)class.?2") { return "Class2" }
        if($Text -match "(?i)class.?3") { return "Class3" }
        if($Text -match "(?i)class.?4") { return "Class4" }
        if($Text -match "(?i)class.?5") { return "Class5" }
        if($Text -match "(?i)class.?6") { return "Class6" }
        return "Unclassified"
    }
    return ""
}

if(-not (Test-Path -LiteralPath $BenchmarkRepo -PathType Container)) { throw "Benchmark repo not found: $BenchmarkRepo" }

$manifest=Join-Path $BenchmarkRepo "catalog\acquisition-manifest.csv"
if(-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Acquisition manifest missing: $manifest" }

Write-Step "Acquiring public benchmark archives"
$acqRows=Import-Csv -LiteralPath $manifest
$acqResults=New-Object System.Collections.Generic.List[object]

foreach($a in $acqRows) {
    $raw=Join-Path $BenchmarkRepo ("benchmarks\"+$a.family_id+"\raw\upstream")
    Ensure-Dir $raw
    $ext=".bin"
    if($a.url -match "\.zip$") { $ext=".zip" }
    elseif($a.url -match "\.tar\.bz2$") { $ext=".tar.bz2" }
    elseif($a.url -match "\.pdf$") { $ext=".pdf" }
    $dest=Join-Path $raw ($a.asset_id+$ext)
    $ok=$false
    if($SkipDownload) { $ok=Test-Path -LiteralPath $dest -PathType Leaf }
    else { $ok=Download-Asset -Url $a.url -Destination $dest }
    $sha=""
    if($ok -and (Test-Path -LiteralPath $dest -PathType Leaf)) { $sha=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash }
    $acqResults.Add([pscustomobject]@{ family_id=$a.family_id; asset_id=$a.asset_id; url=$a.url; local_path=$dest; downloaded=$ok; sha256=$sha })
}
$acqResults | Export-Csv -LiteralPath (Join-Path $BenchmarkRepo "catalog\acquisition-status.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Extracting public archives"
$stadtZip=Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\upstream\mlclsp-complete.zip"
if(Test-Path -LiteralPath $stadtZip -PathType Leaf) {
    $dst=Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\extracted"
    Ensure-Dir $dst
    try { Expand-Archive -LiteralPath $stadtZip -DestinationPath $dst -Force; Write-Host "Extracted Stadtler archive." }
    catch { Write-Warning ("Stadtler extraction failed: "+$_.Exception.Message) }
}
$clsTar=Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\upstream\clspl-complete.tar.bz2"
if(Test-Path -LiteralPath $clsTar -PathType Leaf) {
    $dst=Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\extracted"
    Ensure-Dir $dst
    $tar=Get-Command tar.exe -ErrorAction SilentlyContinue
    if($null -ne $tar) {
        & tar.exe -xf $clsTar -C $dst
        if($LASTEXITCODE -eq 0) { Write-Host "Extracted Suerie CLSPL archive." }
        else { Write-Warning "tar.exe could not extract CLSPL archive." }
    }
}

Write-Step "Scanning workstation for converted LSDM XML"
$roots=@("D:\Dev",(Join-Path $env:USERPROFILE "Documents"),(Join-Path $env:USERPROFILE "Downloads"))
$rows=New-Object System.Collections.Generic.List[object]
$seen=@{}

foreach($scanRoot in $roots) {
    if(-not (Test-Path -LiteralPath $scanRoot -PathType Container)) { continue }
    Get-ChildItem -LiteralPath $scanRoot -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if($_.FullName.StartsWith($BenchmarkRepo,[System.StringComparison]::OrdinalIgnoreCase)) { return }
        try { [xml]$doc=Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 } catch { return }
        if($null -eq $doc.DocumentElement -or -not ($doc.DocumentElement.LocalName -ieq "lotSizingInstance")) { return }

        $xroot=$doc.DocumentElement
        $xmlName=$xroot.GetAttribute("name")
        $instanceId=$xroot.GetAttribute("instanceId")
        $sourceNode=Child-Local -Parent $xroot -Name "sourceInformation"
        $sourceInfo=""
        if($null -ne $sourceNode) { $sourceInfo=$sourceNode.InnerText }

        $family=Detect-Family -FileName $_.Name -XmlName $xmlName -SourceInfo $sourceInfo
        if([string]::IsNullOrWhiteSpace($family)) { return }

        $key=$family+"|"+$instanceId
        if([string]::IsNullOrWhiteSpace($instanceId)) { $key=$family+"|"+$xmlName }
        if($seen.ContainsKey($key)) { return }
        $seen[$key]=$true

        $supply=Child-Local -Parent $xroot -Name "supplyChain"
        $periods="0"
        if($null -ne $supply) {
            $p=$supply.GetAttribute("planningHorizon")
            if(-not [string]::IsNullOrWhiteSpace($p)) { $periods=$p }
        }
        $classification=Child-Local -Parent $xroot -Name "problemClassification"
        $ptype=$family
        if($null -ne $classification) {
            $pt=$classification.GetAttribute("primaryProblemTypeCode")
            if(-not [string]::IsNullOrWhiteSpace($pt)) { $ptype=$pt }
        }

        $id=$xmlName
        if([string]::IsNullOrWhiteSpace($id)) { $id=$instanceId }
        if([string]::IsNullOrWhiteSpace($id)) { $id=$_.BaseName }

        $text=$_.Name+" "+$xmlName+" "+$sourceInfo
        $sub=Detect-Subclass -Family $family -Text $text
        $targetRoot=Join-Path $BenchmarkRepo ("benchmarks\"+$family)
        if(-not [string]::IsNullOrWhiteSpace($sub)) { $targetRoot=Join-Path $targetRoot $sub }
        $instDir=Join-Path $targetRoot "instances"
        $refDir=Join-Path $targetRoot "instances-with-reference"
        Ensure-Dir $instDir; Ensure-Dir $refDir

        $fn="LSDM_"+$family+"_"+(Safe-Token $ptype)+"_"+$periods+"_unknown_"+(Safe-Token $id)+".xml"
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $refDir $fn) -Force

        [xml]$pure=Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $pr=$pure.DocumentElement
        if($pr.HasAttribute("bestKnownResultId")) { $pr.RemoveAttribute("bestKnownResultId") }
        $kr=Child-Local -Parent $pr -Name "knownResults"
        if($null -ne $kr) { [void]$pr.RemoveChild($kr) }
        Save-Xml -Doc $pure -Path (Join-Path $instDir $fn)

        $rows.Add([pscustomobject]@{ family_id=$family; subclass=$sub; instance_id=$instanceId; original_name=$xmlName; lsdm_filename=$fn; periods=$periods; problem_type=$ptype; original_local_path=$_.FullName })
    }
}

$rows | Export-Csv -LiteralPath (Join-Path $BenchmarkRepo "catalog\tempelmeier-ecosystem-local-lsdm.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Generating ecosystem status report"
$counts=@{}
foreach($fid in @("TD1996","STADTLER2003","SUERIE_CLSPL","TB2009")) { $counts[$fid]=@($rows | Where-Object { $_.family_id -eq $fid }).Count }

$report=@(
"# Tempelmeier ecosystem ingestion status",
"",
("- TD1996 local LSDM instances: "+$counts["TD1996"]),
("- STADTLER2003 local LSDM instances: "+$counts["STADTLER2003"]),
("- SUERIE_CLSPL local LSDM instances: "+$counts["SUERIE_CLSPL"]),
("- TB2009 local LSDM instances: "+$counts["TB2009"]),
"",
"Public archives are retained under raw/upstream.",
"Raw files are not labelled converted until a verified source-specific importer parses them.",
"Published objectives/lower bounds remain literature evidence until identity and trust rules permit promotion."
)
[System.IO.File]::WriteAllLines((Join-Path $BenchmarkRepo "reports\tempelmeier-ecosystem-status.md"),$report,(New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host ("TD1996 LSDM: "+$counts["TD1996"])
Write-Host ("STADTLER2003 LSDM: "+$counts["STADTLER2003"])
Write-Host ("SUERIE_CLSPL LSDM: "+$counts["SUERIE_CLSPL"])
Write-Host ("TB2009 LSDM: "+$counts["TB2009"])
Write-Host ("Acquisition status: "+(Join-Path $BenchmarkRepo "catalog\acquisition-status.csv"))
