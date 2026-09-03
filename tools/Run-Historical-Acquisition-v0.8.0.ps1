param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = 60
    )

    try {
        $parent = Split-Path -Parent $Destination
        Ensure-Directory -Path $parent

        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -UserAgent "LotSizingDataModel.Benchmarks/0.8.0"

        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            return $false
        }

        if ((Get-Item -LiteralPath $Destination).Length -le 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            return $false
        }

        return $true
    }
    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-GetText {
    param(
        [string]$Url,
        [int]$TimeoutSec = 60
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Url `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSec `
            -UserAgent "Mozilla/5.0 LotSizingDataModel.Benchmarks/0.8.0"

        return [string]$response.Content
    }
    catch {
        return ""
    }
}

function Resolve-Url {
    param(
        [string]$BaseUrl,
        [string]$Href
    )

    try {
        $base = New-Object Uri($BaseUrl)
        $resolved = New-Object Uri($base,$Href)
        return $resolved.AbsoluteUri
    }
    catch {
        return ""
    }
}

function Get-Hrefs {
    param([string]$Html)

    $hrefs = New-Object System.Collections.Generic.List[string]

    foreach ($match in [regex]::Matches(
        $Html,
        '(?is)href\s*=\s*["''](?<u>[^"'']+)["'']'
    )) {
        $hrefs.Add($match.Groups["u"].Value)
    }

    return $hrefs.ToArray()
}

function Expand-ZipSafe {
    param(
        [string]$Archive,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination -PathType Container) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    Ensure-Directory -Path $Destination

    try {
        Expand-Archive `
            -LiteralPath $Archive `
            -DestinationPath $Destination `
            -Force

        return $true
    }
    catch {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Get-DirectorySignature {
    param([string]$Directory)

    return (
        @(
            Get-ChildItem `
                -LiteralPath $Directory `
                -File `
                -ErrorAction SilentlyContinue |
            ForEach-Object {
                $_.Name.ToUpperInvariant()
            } |
            Sort-Object
        ) -join ";"
    )
}

function Test-HasFiles {
    param(
        [string]$Directory,
        [string[]]$Required
    )

    foreach ($name in $Required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Classify-MLCLSPContract {
    param([string]$Directory)

    $datab = @(
        "AUSLAST.PRN","DIREKT-B.PRN","FLAGS.PRN","INDEX.PRN","L0.PRN",
        "LT.PRN","MITT_BED.PRN","P-BEDARF.PRN","PRODKOEF.PRN","RUESTZ.PRN",
        "SPARSE.PRN","TBO.PRN","UEBER-KS.PRN","YFIX.PRN","ZFIX.PRN","ZFKOEF.PRN"
    )

    $explicit = @(
        "AUSLAST.PRN","DIREKT-B.PRN","INDEX.PRN","L0.PRN","LT.PRN",
        "MITT_BED.PRN","P-BEDARF.PRN","PRODKOEF.PRN","RUESTZ.PRN",
        "TBO.PRN","UEBER-KS.PRN","ZFKOEF.PRN"
    )

    if (Test-HasFiles -Directory $Directory -Required $datab) {
        return "DATAB_BPLUS"
    }

    if (Test-HasFiles -Directory $Directory -Required $explicit) {
        return "EXPLICIT_MLCLSP"
    }

    return "UNKNOWN"
}

function Get-IndexDirectories {
    param([string]$Root)

    $seen = @{}
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($file in Get-ChildItem `
        -LiteralPath $Root `
        -Filter "INDEX.PRN" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue) {

        $dir = $file.Directory.FullName
        $key = $dir.ToLowerInvariant()

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result.Add($dir)
        }
    }

    return $result.ToArray()
}

function Get-FileProvenance {
    param(
        [string]$Family,
        [string]$Url,
        [string]$Path,
        [string]$SourcePage,
        [string]$Status
    )

    $sha = ""
    $length = 0

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $sha = (
            Get-FileHash `
                -LiteralPath $Path `
                -Algorithm SHA256
        ).Hash

        $length = (Get-Item -LiteralPath $Path).Length
    }

    return [pscustomobject]@{
        family = $Family
        url = $Url
        source_page = $SourcePage
        local_path = $Path
        sha256 = $sha
        length = $length
        acquired_utc = [DateTime]::UtcNow.ToString("o")
        status = $Status
    }
}

$tdRoot = Join-Path $BenchmarkRepo "benchmarks\TD1996"
$triRoot = Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.8.0"
$catalogRoot = Join-Path $BenchmarkRepo "catalog"

foreach ($p in @(
    $tdRoot,
    (Join-Path $tdRoot "raw\upstream"),
    (Join-Path $tdRoot "raw\materialized"),
    (Join-Path $tdRoot "instances"),
    (Join-Path $tdRoot "metadata"),
    $triRoot,
    (Join-Path $triRoot "raw\upstream"),
    (Join-Path $triRoot "raw\materialized"),
    (Join-Path $triRoot "metadata"),
    $reportRoot,
    $catalogRoot
)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: frozen benchmark invariants"

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$stadtlerTotal = 0

foreach ($spec in @(
    [pscustomobject]@{Folder="Aplus";Count=240},
    [pscustomobject]@{Folder="Bplus";Count=600},
    [pscustomobject]@{Folder="C";Count=360},
    [pscustomobject]@{Folder="Cplus";Count=240},
    [pscustomobject]@{Folder="D";Count=360},
    [pscustomobject]@{Folder="Dplus";Count=240},
    [pscustomobject]@{Folder="E";Count=30},
    [pscustomobject]@{Folder="Eplus";Count=30}
)) {
    $count = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stadtlerRoot ($spec.Folder + "\instances")) `
            -Filter "*.xml" `
            -File `
            -ErrorAction SilentlyContinue
    ).Count

    if ($count -ne $spec.Count) {
        throw ("Stadtler invariant failed in " + $spec.Folder)
    }

    $stadtlerTotal += $count
}

if ($stadtlerTotal -ne 2100) {
    throw "Stadtler total invariant failed."
}

$clsplCatalogue = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)

if ($clsplRows.Count -ne 1281) {
    throw "CLSPL 1281/1281 invariant failed."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL: 1281 / 1281"

Write-Step "Acquiring Tempelmeier-Derstroff 1996 historical testdata"

$provenance = New-Object System.Collections.Generic.List[object]

$tdPages = @(
    "https://www.wiwi-online.de/Professoren/2274/Prof.%2BDr.%2Brer.%2Bpol.%2Bhabil.%2BHorst%2BTempelmeier",
    "https://www.wiwi-online.de/Professoren/2274/Prof.+Dr.+rer.+pol.+habil.+Horst+Tempelmeier"
)

$tdArchive = Join-Path $tdRoot "raw\upstream\testdata.zip"
$tdDownloadUrl = ""
$tdSourcePage = ""
$tdStatus = "NOT_FOUND"

foreach ($pageUrl in $tdPages) {
    if (-not [string]::IsNullOrWhiteSpace($tdDownloadUrl)) {
        break
    }

    $html = Invoke-GetText -Url $pageUrl

    if ([string]::IsNullOrWhiteSpace($html)) {
        continue
    }

    foreach ($href in Get-Hrefs -Html $html) {
        if ($href -notmatch "(?i)testdata\.zip") {
            continue
        }

        $candidateUrl = Resolve-Url -BaseUrl $pageUrl -Href $href

        if ([string]::IsNullOrWhiteSpace($candidateUrl)) {
            continue
        }

        Write-Host ("Discovered TD1996 archive candidate: " + $candidateUrl)

        if (-not $DryRun) {
            if (Invoke-DownloadFile -Url $candidateUrl -Destination $tdArchive) {
                $tdDownloadUrl = $candidateUrl
                $tdSourcePage = $pageUrl
                $tdStatus = "DOWNLOADED_FROM_LIVING_SOURCE_PAGE"
                break
            }
        }
        else {
            $tdDownloadUrl = $candidateUrl
            $tdSourcePage = $pageUrl
            $tdStatus = "DISCOVERED_DRY_RUN"
            break
        }
    }
}

# Wayback fallback discovers historical captures of testdata.zip URLs without
# guessing the archived payload URL.
if ([string]::IsNullOrWhiteSpace($tdDownloadUrl)) {
    Write-Host "Living TD1996 source link not downloadable; querying Internet Archive CDX."

    $cdxUrl = (
        "https://web.archive.org/cdx/search/cdx" +
        "?url=*.uni-koeln.de/*testdata.zip" +
        "&output=json&filter=statuscode:200&filter=mimetype:application/zip&collapse=urlkey"
    )

    $cdx = Invoke-GetText -Url $cdxUrl

    if (-not [string]::IsNullOrWhiteSpace($cdx)) {
        try {
            $rows = ConvertFrom-Json $cdx

            if ($rows.Count -gt 1) {
                for ($i = $rows.Count - 1; $i -ge 1; $i--) {
                    $capture = $rows[$i]
                    $timestamp = [string]$capture[1]
                    $original = [string]$capture[2]

                    if ([string]::IsNullOrWhiteSpace($timestamp) -or
                        [string]::IsNullOrWhiteSpace($original)) {
                        continue
                    }

                    $archiveUrl = (
                        "https://web.archive.org/web/" +
                        $timestamp +
                        "id_/" +
                        $original
                    )

                    Write-Host ("Wayback TD1996 candidate: " + $archiveUrl)

                    if ($DryRun) {
                        $tdDownloadUrl = $archiveUrl
                        $tdSourcePage = $cdxUrl
                        $tdStatus = "WAYBACK_DISCOVERED_DRY_RUN"
                        break
                    }

                    if (Invoke-DownloadFile -Url $archiveUrl -Destination $tdArchive -TimeoutSec 90) {
                        $tdDownloadUrl = $archiveUrl
                        $tdSourcePage = $cdxUrl
                        $tdStatus = "DOWNLOADED_FROM_WAYBACK"
                        break
                    }
                }
            }
        }
        catch {
        }
    }
}

$provenance.Add(
    (Get-FileProvenance `
        -Family "TD1996" `
        -Url $tdDownloadUrl `
        -Path $tdArchive `
        -SourcePage $tdSourcePage `
        -Status $tdStatus)
)

Write-Host ("TD1996 acquisition status: " + $tdStatus)

$tdExtracted = $false
$tdMaterialized = Join-Path $tdRoot "raw\materialized\testdata"

if (-not $DryRun -and
    (Test-Path -LiteralPath $tdArchive -PathType Leaf)) {

    $tdExtracted = Expand-ZipSafe `
        -Archive $tdArchive `
        -Destination $tdMaterialized
}

Write-Host ("TD1996 archive extracted: " + $tdExtracted)

Write-Step "Auditing acquired TD1996 contracts"

$tdContractRows = New-Object System.Collections.Generic.List[object]

if (-not $DryRun -and $tdExtracted) {
    foreach ($dir in Get-IndexDirectories -Root $tdMaterialized) {
        $classification = Classify-MLCLSPContract -Directory $dir

        $tdContractRows.Add([pscustomobject]@{
            directory = $dir
            contract = $classification
            file_signature = Get-DirectorySignature -Directory $dir
            file_count = @(
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue
            ).Count
        })
    }
}

$tdContractRows.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-acquired-contracts.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$tdRecognized = @(
    $tdContractRows.ToArray() |
    Where-Object { $_.contract -ne "UNKNOWN" }
)

Write-Host ("TD1996 INDEX.PRN directories: " + $tdContractRows.Count)
Write-Host ("TD1996 recognized contracts: " + $tdRecognized.Count)

Write-Step "Converting acquired TD1996 only when contract is proven"

$tdConverted = 0
$tdCheckerExit = -1

if (-not $DryRun -and $tdRecognized.Count -gt 0) {
    $converterProject = Join-Path $BenchmarkRepo `
        "tools\TempelmeierConverter\TempelmeierConverter.csproj"

    & dotnet build `
        $converterProject `
        -c Release `
        --nologo `
        -p:ModelRepo=$ModelRepo

    if ($LASTEXITCODE -ne 0) {
        throw "TempelmeierConverter build failed."
    }

    $stage = Join-Path $reportRoot "td1996-conversion-staging"

    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }

    Ensure-Directory -Path $stage

    $ordinal = 0

    foreach ($contract in $tdRecognized) {
        $ordinal++
        $target = Join-Path $stage ("source_" + $ordinal.ToString("D4"))
        Ensure-Directory -Path $target

        $mode = "stadtler"

        if ($contract.contract -eq "DATAB_BPLUS") {
            $mode = "datab"
        }

        & dotnet run `
            --project $converterProject `
            -c Release `
            --no-build `
            -p:ModelRepo=$ModelRepo `
            -- `
            $mode `
            $contract.directory `
            $target

        if ($LASTEXITCODE -ne 0) {
            continue
        }
    }

    $stageXml = @(
        Get-ChildItem -LiteralPath $stage -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue
    )

    $instancesRoot = Join-Path $tdRoot "instances"
    $hashes = @{}

    foreach ($file in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
        $hashes[(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash] = $true
    }

    $nextId = @(
        Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
    ).Count

    foreach ($file in $stageXml) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash

        if ($hashes.ContainsKey($hash)) {
            continue
        }

        $nextId++
        $dest = Join-Path $instancesRoot (
            "LSDM_TD1996_MLCLSP_unknown_unknown_ID" +
            $nextId.ToString("D4") +
            ".xml"
        )

        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        $hashes[$hash] = $true
        $tdConverted++
    }

    $tdXml = @(
        Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
    )

    if ($tdXml.Count -gt 0) {
        $checkerProject = Join-Path $ModelRepo `
            "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"

        $checkerOutput = Join-Path $tdRoot "checker-reports\v0.8.0"
        Ensure-Directory -Path $checkerOutput

        & dotnet run `
            --project $checkerProject `
            -c Release `
            -- `
            $instancesRoot `
            --level structural `
            --output $checkerOutput `
            --no-progress

        $tdCheckerExit = $LASTEXITCODE
    }
}

Write-Host ("New TD1996 XML converted: " + $tdConverted)
Write-Host ("TD1996 checker exit: " + $tdCheckerExit)

Write-Step "Fallback acquisition: Trigeiro 1989 public dataset"

$trigeiroArchive = Join-Path $triRoot "raw\upstream\trigeiro_fdata.zip"
$trigeiroUrl = "https://github.com/gsamaro/trigeiro_fdata/archive/refs/heads/master.zip"
$trigeiroStatus = "NOT_ATTEMPTED"

$needFallback = (
    $tdStatus -notmatch "DOWNLOADED" -or
    (-not $DryRun -and $tdRecognized.Count -eq 0)
)

if ($needFallback) {
    if ($DryRun) {
        $trigeiroStatus = "FALLBACK_PLANNED_DRY_RUN"
    }
    else {
        if (Invoke-DownloadFile -Url $trigeiroUrl -Destination $trigeiroArchive -TimeoutSec 90) {
            $trigeiroStatus = "DOWNLOADED_GITHUB_PUBLIC_REPOSITORY"
        }
        else {
            # Some repositories use main rather than master.
            $trigeiroUrl = "https://github.com/gsamaro/trigeiro_fdata/archive/refs/heads/main.zip"

            if (Invoke-DownloadFile -Url $trigeiroUrl -Destination $trigeiroArchive -TimeoutSec 90) {
                $trigeiroStatus = "DOWNLOADED_GITHUB_PUBLIC_REPOSITORY"
            }
            else {
                $trigeiroStatus = "DOWNLOAD_FAILED"
            }
        }
    }
}

$provenance.Add(
    (Get-FileProvenance `
        -Family "TRIGEIRO1989" `
        -Url $trigeiroUrl `
        -Path $trigeiroArchive `
        -SourcePage "https://github.com/gsamaro/trigeiro_fdata" `
        -Status $trigeiroStatus)
)

Write-Host ("Trigeiro fallback status: " + $trigeiroStatus)

$triExtracted = $false
$triMaterialized = Join-Path $triRoot "raw\materialized\github"

if (-not $DryRun -and
    (Test-Path -LiteralPath $trigeiroArchive -PathType Leaf)) {

    $triExtracted = Expand-ZipSafe `
        -Archive $trigeiroArchive `
        -Destination $triMaterialized
}

$triData = @()

if (-not $DryRun -and $triExtracted) {
    $triData = @(
        Get-ChildItem `
            -LiteralPath $triMaterialized `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -match "(?i)^\.(dat|txt)$"
        }
    )
}

Write-Host ("Trigeiro candidate data files acquired: " + $triData.Count)

$triInventory = New-Object System.Collections.Generic.List[object]

foreach ($file in $triData) {
    $preview = ""

    try {
        $preview = @(
            Get-Content -LiteralPath $file.FullName -TotalCount 6 -ErrorAction Stop
        ) -join " || "
    }
    catch {
    }

    $triInventory.Add([pscustomobject]@{
        path = $file.FullName
        file_name = $file.Name
        length = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        preview = [regex]::Replace($preview,"[^\x20-\x7E\t]","?")
        import_status = "ACQUIRED_FORMAT_AUDIT_REQUIRED"
    })
}

$triInventory.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $triRoot "metadata\TRIGEIRO1989-RAW-INVENTORY-v0.8.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Writing historical acquisition provenance"

$provenance.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $catalogRoot "historical-acquisition-v0.8.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$statusPage = New-Object System.Collections.Generic.List[string]
$statusPage.Add("# Historical benchmark acquisition v0.8.0")
$statusPage.Add("")
$statusPage.Add("| Family | Status |")
$statusPage.Add("|---|---|")
$statusPage.Add("| TD1996 | **" + $tdStatus + "** |")
$statusPage.Add("| Trigeiro 1989 fallback | **" + $trigeiroStatus + "** |")
$statusPage.Add("")
$statusPage.Add("## TD1996")
$statusPage.Add("")
$statusPage.Add("- Acquired INDEX.PRN directories: **" + $tdContractRows.Count + "**")
$statusPage.Add("- Recognized MLCLSP contracts: **" + $tdRecognized.Count + "**")
$statusPage.Add("- New canonical XML: **" + $tdConverted + "**")
$statusPage.Add("- Structural checker exit: **" + $tdCheckerExit + "**")
$statusPage.Add("")
$statusPage.Add("## Trigeiro 1989")
$statusPage.Add("")
$statusPage.Add("- Candidate raw data files acquired: **" + $triData.Count + "**")
$statusPage.Add("- Raw files are inventoried only; no CLSP parameters are guessed in v0.8.0.")

[IO.File]::WriteAllLines(
    (Join-Path $reportRoot "README.md"),
    $statusPage.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.8.0 final summary"
Write-Host ("TD1996 acquisition: " + $tdStatus)
Write-Host ("TD1996 contracts recognized: " + $tdRecognized.Count)
Write-Host ("TD1996 new XML: " + $tdConverted)
Write-Host ("TD1996 checker exit: " + $tdCheckerExit)
Write-Host ("Trigeiro acquisition: " + $trigeiroStatus)
Write-Host ("Trigeiro raw data files: " + $triData.Count)
Write-Host ("Reports: " + $reportRoot)
