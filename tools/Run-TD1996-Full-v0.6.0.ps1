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

function Normalize-PathKey {
    param([string]$Path)
    return ([IO.Path]::GetFullPath($Path)).ToLowerInvariant()
}

function Get-DirectoryFingerprint {
    param([string]$Directory)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $builder = New-Object Text.StringBuilder

        foreach ($file in (
            Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName
        )) {
            $relative = $file.FullName.Substring($Directory.Length).TrimStart('\')
            [void]$builder.Append($relative.ToLowerInvariant())
            [void]$builder.Append("|")
            [void]$builder.Append($file.Length)
            [void]$builder.Append("|")
            [void]$builder.Append(
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            )
            [void]$builder.AppendLine()
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-","").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-ExplicitClsplContract {
    param([string]$Directory)

    $required = @(
        "AUSLAST.PRN",
        "DIREKT-B.PRN",
        "INDEX.PRN",
        "L0.PRN",
        "LT.PRN",
        "MITT_BED.PRN",
        "P-BEDARF.PRN",
        "PRODKOEF.PRN",
        "RUESTZ.PRN",
        "TBO.PRN",
        "UEBER-KS.PRN",
        "ZFKOEF.PRN"
    )

    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Test-DatabContract {
    param([string]$Directory)

    $required = @(
        "AUSLAST.PRN",
        "DIREKT-B.PRN",
        "FLAGS.PRN",
        "INDEX.PRN",
        "L0.PRN",
        "LT.PRN",
        "MITT_BED.PRN",
        "P-BEDARF.PRN",
        "PRODKOEF.PRN",
        "RUESTZ.PRN",
        "SPARSE.PRN",
        "TBO.PRN",
        "UEBER-KS.PRN",
        "YFIX.PRN",
        "ZFIX.PRN",
        "ZFKOEF.PRN"
    )

    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Get-CandidateDirectories {
    param([string[]]$Roots)

    $dirs = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($file in Get-ChildItem -LiteralPath $root -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue) {
            $dir = $file.Directory.FullName
            $key = Normalize-PathKey -Path $dir

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $dirs.Add($dir)
            }
        }
    }

    return $dirs.ToArray()
}

function Expand-ArchivesRecursively {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    Ensure-Directory -Path $DestinationRoot

    $copied = New-Object System.Collections.Generic.List[string]

    foreach ($file in Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -ErrorAction SilentlyContinue) {
        $ext = $file.Extension.ToLowerInvariant()

        if ($ext -in @(".zip",".7z",".gz",".bz2",".tar")) {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.Substring(0,16)
            $target = Join-Path $DestinationRoot (
                [IO.Path]::GetFileNameWithoutExtension($file.Name) +
                "_" +
                $hash
            )

            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                Ensure-Directory -Path $target

                if ($ext -eq ".zip") {
                    try {
                        Expand-Archive -LiteralPath $file.FullName -DestinationPath $target -Force
                        $copied.Add($target)
                    }
                    catch {
                        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                else {
                    # Preserve unsupported archive types for audit; do not guess extraction.
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    return $copied.ToArray()
}

$tdRoot = Join-Path $BenchmarkRepo "benchmarks\TD1996"
$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$clsplRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.6.0"
$rawRoot = Join-Path $tdRoot "raw"
$materializedRoot = Join-Path $rawRoot "materialized-v0.6.0"
$instancesRoot = Join-Path $tdRoot "instances"
$metadataRoot = Join-Path $tdRoot "metadata"
$checkerRoot = Join-Path $tdRoot "checker-reports"

foreach ($p in @(
    $tdRoot,
    $reportRoot,
    $rawRoot,
    $materializedRoot,
    $instancesRoot,
    $metadataRoot,
    $checkerRoot
)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: stabilized benchmark state"

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
        throw ("Stadtler preflight regression in " + $spec.Folder)
    }

    $stadtlerTotal += $count
}

if ($stadtlerTotal -ne 2100) {
    throw "Stadtler must remain 2100."
}

$clsplCatalogue = Join-Path $clsplRoot "metadata\CLSPL-LITERATURE-REFERENCES.csv"
$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)

if ($clsplRows.Count -ne 1281) {
    throw "CLSPL must remain 1281."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL: 1281 / 1281"

Write-Step "Loading v0.5.0 local TD1996 discoveries"

$discoveryPath = Join-Path $tdRoot "metadata\local-discovery.csv"

if (-not (Test-Path -LiteralPath $discoveryPath -PathType Leaf)) {
    throw "v0.5.0 local-discovery.csv is missing."
}

$discoveries = @(Import-Csv -LiteralPath $discoveryPath)

Write-Host ("Candidate files from v0.5.0: " + $discoveries.Count)

$existingDiscoveries = @(
    $discoveries |
    Where-Object {
        Test-Path -LiteralPath $_.path -PathType Leaf
    }
)

Write-Host ("Candidate files still present: " + $existingDiscoveries.Count)

$inventory = New-Object System.Collections.Generic.List[object]

foreach ($row in $existingDiscoveries) {
    $file = Get-Item -LiteralPath $row.path

    $inventory.Add([pscustomobject]@{
        path = $file.FullName
        file_name = $file.Name
        extension = $file.Extension
        length = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        likely_archive = ($file.Extension.ToLowerInvariant() -in @(".zip",".7z",".tar",".gz",".bz2"))
        likely_document = ($file.Extension.ToLowerInvariant() -in @(".pdf",".doc",".docx",".txt",".htm",".html"))
        likely_data = ($file.Extension.ToLowerInvariant() -in @(".prn",".dat",".txt",".csv",".xml"))
    })
}

$inventory.ToArray() |
    Sort-Object path |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-candidate-file-inventory.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Materializing ZIP archives from local candidates"

$zipFiles = @(
    $inventory.ToArray() |
    Where-Object { $_.extension -ieq ".zip" }
)

$expanded = New-Object System.Collections.Generic.List[string]

foreach ($zipRow in $zipFiles) {
    $hashPrefix = $zipRow.sha256.Substring(0,16)
    $target = Join-Path $materializedRoot (
        [IO.Path]::GetFileNameWithoutExtension($zipRow.file_name) +
        "_" +
        $hashPrefix
    )

    if (Test-Path -LiteralPath $target -PathType Container) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }

    Ensure-Directory -Path $target

    try {
        Expand-Archive -LiteralPath $zipRow.path -DestinationPath $target -Force
        $expanded.Add($target)
        Write-Host ("Expanded: " + $zipRow.file_name)
    }
    catch {
        Write-Warning ("Could not expand " + $zipRow.path)
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ("ZIP archives expanded: " + $expanded.Count)

Write-Step "Scanning all candidate directories for known source contracts"

$scanRoots = New-Object System.Collections.Generic.List[string]

foreach ($row in $existingDiscoveries) {
    $parent = Split-Path -Parent $row.path
    if (Test-Path -LiteralPath $parent -PathType Container) {
        $scanRoots.Add($parent)
    }
}

foreach ($path in $expanded.ToArray()) {
    $scanRoots.Add($path)
}

$dirs = Get-CandidateDirectories -Roots $scanRoots.ToArray()

$contracts = New-Object System.Collections.Generic.List[object]

foreach ($dir in $dirs) {
    $contract = "UNKNOWN_INDEX_PRN_CONTRACT"

    if (Test-ExplicitClsplContract -Directory $dir) {
        $contract = "EXPLICIT_12_FILE_MLCLSP_CONTRACT"
    }
    elseif (Test-DatabContract -Directory $dir) {
        $contract = "DATAB_BPLUS_CONTRACT"
    }

    $contracts.Add([pscustomobject]@{
        directory = $dir
        contract = $contract
        directory_fingerprint = Get-DirectoryFingerprint -Directory $dir
        file_count = @(
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue
        ).Count
    })
}

$contracts.ToArray() |
    Sort-Object contract,directory |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-directory-contracts.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$knownContracts = @(
    $contracts.ToArray() |
    Where-Object {
        $_.contract -ne "UNKNOWN_INDEX_PRN_CONTRACT"
    }
)

Write-Host ("Directories containing INDEX.PRN: " + $contracts.Count)
Write-Host ("Recognized MLCLSP contracts: " + $knownContracts.Count)

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "No conversion or checker was executed."
    exit 0
}

Write-Step "Deduplicating recognized source directories"

$uniqueByFingerprint = @{}
$uniqueContracts = New-Object System.Collections.Generic.List[object]

foreach ($row in $knownContracts) {
    if (-not $uniqueByFingerprint.ContainsKey($row.directory_fingerprint)) {
        $uniqueByFingerprint[$row.directory_fingerprint] = $true
        $uniqueContracts.Add($row)
    }
}

Write-Host ("Unique recognized source directories: " + $uniqueContracts.Count)

$converterProject = Join-Path $BenchmarkRepo `
    "tools\TempelmeierConverter\TempelmeierConverter.csproj"

if (-not (Test-Path -LiteralPath $converterProject -PathType Leaf)) {
    throw "TempelmeierConverter is missing."
}

Write-Step "Building converter"

& dotnet build `
    $converterProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TempelmeierConverter build failed."
}

Write-Step "Converting every proven source contract to isolated TD1996 staging"

$conversionStage = Join-Path $reportRoot "converted-staging"

if (Test-Path -LiteralPath $conversionStage) {
    Remove-Item -LiteralPath $conversionStage -Recurse -Force
}

Ensure-Directory -Path $conversionStage

$conversion = New-Object System.Collections.Generic.List[object]
$ordinal = 0

foreach ($source in $uniqueContracts.ToArray()) {
    $ordinal++
    $target = Join-Path $conversionStage ("source_" + $ordinal.ToString("D4"))
    Ensure-Directory -Path $target

    $mode = "stadtler"

    if ($source.contract -eq "DATAB_BPLUS_CONTRACT") {
        $mode = "datab"
    }

    $console = @(
        & dotnet run `
            --project $converterProject `
            -c Release `
            --no-build `
            -p:ModelRepo=$ModelRepo `
            -- `
            $mode `
            $source.directory `
            $target 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    $xml = @(
        Get-ChildItem -LiteralPath $target -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue
    )

    $conversion.Add([pscustomobject]@{
        source_directory = $source.directory
        contract = $source.contract
        fingerprint = $source.directory_fingerprint
        converter_mode = $mode
        exit_code = $LASTEXITCODE
        xml_count = $xml.Count
        staging_directory = $target
    })

    Write-Host (
        "Source " +
        $ordinal +
        ": contract=" +
        $source.contract +
        " xml=" +
        $xml.Count +
        " exit=" +
        $LASTEXITCODE
    )
}

$conversion.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-conversion-report.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$convertedXml = @(
    Get-ChildItem -LiteralPath $conversionStage -Filter "*.xml" -File -Recurse -ErrorAction SilentlyContinue
)

Write-Host ("Converted candidate XML before deduplication: " + $convertedXml.Count)

Write-Step "Deduplicating converted XML by SHA256"

$xmlSeen = @{}
$canonicalXml = New-Object System.Collections.Generic.List[object]

foreach ($file in $convertedXml) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash

    if (-not $xmlSeen.ContainsKey($hash)) {
        $xmlSeen[$hash] = $true
        $canonicalXml.Add([pscustomobject]@{
            source_path = $file.FullName
            sha256 = $hash
        })
    }
}

Write-Host ("Unique converted XML by byte hash: " + $canonicalXml.Count)

# Preserve existing TD1996 canonical XML if any. Add only new unique content.
$existingHashes = @{}

foreach ($file in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $existingHashes[$hash] = $true
}

$added = 0

foreach ($row in $canonicalXml.ToArray()) {
    if ($existingHashes.ContainsKey($row.sha256)) {
        continue
    }

    $added++
    $name = "LSDM_TD1996_MLCLSP_unknown_unknown_ID" + $added.ToString("D4") + ".xml"
    $destination = Join-Path $instancesRoot $name
    Copy-Item -LiteralPath $row.source_path -Destination $destination -Force
}

Write-Host ("New TD1996 XML staged canonically: " + $added)

Write-Step "Running structural checker on TD1996 canonical XML"

$tdXml = @(
    Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
)

if ($tdXml.Count -gt 0) {
    $checkerProject = Join-Path $ModelRepo `
        "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"

    & dotnet run `
        --project $checkerProject `
        -c Release `
        -- `
        $instancesRoot `
        --level structural `
        --output $checkerRoot `
        --no-progress

    $checkerExit = $LASTEXITCODE
}
else {
    $checkerExit = -1
}

Write-Host ("TD1996 canonical XML: " + $tdXml.Count)
Write-Host ("Checker exit: " + $checkerExit)

Write-Step "Building crosswalk against Stadtler C/D/E by SupplyChainFingerprint"

$fingerprintProject = Join-Path $BenchmarkRepo `
    "tools\InstanceFingerprint\InstanceFingerprint.csproj"

$crosswalk = New-Object System.Collections.Generic.List[object]

if ($tdXml.Count -gt 0 -and (Test-Path -LiteralPath $fingerprintProject -PathType Leaf)) {
    & dotnet build `
        $fingerprintProject `
        -c Release `
        --nologo `
        -p:ModelRepo=$ModelRepo

    if ($LASTEXITCODE -eq 0) {
        $tdFp = @{}

        foreach ($file in $tdXml) {
            $lines = @(
                & dotnet run `
                    --project $fingerprintProject `
                    -c Release `
                    --no-build `
                    -p:ModelRepo=$ModelRepo `
                    -- `
                    $file.FullName 2>&1 |
                ForEach-Object { $_.ToString() }
            )

            foreach ($line in $lines) {
                if ($line -match "^OK\|(?<path>[^|]+)\|(?<iid>[^|]*)\|(?<name>[^|]*)\|(?<fp>.+)$") {
                    $tdFp[$Matches["fp"]] = $Matches["path"]
                }
            }
        }

        foreach ($folder in @("C","D","E")) {
            foreach ($file in Get-ChildItem `
                -LiteralPath (Join-Path $stadtlerRoot ($folder + "\instances")) `
                -Filter "*.xml" `
                -File) {

                $lines = @(
                    & dotnet run `
                        --project $fingerprintProject `
                        -c Release `
                        --no-build `
                        -p:ModelRepo=$ModelRepo `
                        -- `
                        $file.FullName 2>&1 |
                    ForEach-Object { $_.ToString() }
                )

                foreach ($line in $lines) {
                    if ($line -match "^OK\|(?<path>[^|]+)\|(?<iid>[^|]*)\|(?<name>[^|]*)\|(?<fp>.+)$") {
                        $fp = $Matches["fp"]

                        if ($tdFp.ContainsKey($fp)) {
                            $crosswalk.Add([pscustomobject]@{
                                fingerprint = $fp
                                td1996_xml = $tdFp[$fp]
                                stadtler_xml = $Matches["path"]
                                relation = "EXACT_SUPPLY_CHAIN_FINGERPRINT"
                            })
                        }
                    }
                }
            }
        }
    }
}

$crosswalk.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TD1996-STADTLER-CROSSWALK.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Exact TD1996 <-> Stadtler C/D/E pairs: " + $crosswalk.Count)

Write-Step "Installing literature-level benchmark results"

$literature = @(
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 2 G-NC"
        reference_type = "GROUP_AVERAGE_OPTIMAL_COST"
        value = "11163.5"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 2 G-C"
        reference_type = "GROUP_AVERAGE_OPTIMAL_COST"
        value = "11332.8"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 2 A-NC"
        reference_type = "GROUP_AVERAGE_OPTIMAL_COST"
        value = "10802.5"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 2 A-C"
        reference_type = "GROUP_AVERAGE_OPTIMAL_COST"
        value = "10347.1"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 3 G-NC"
        reference_type = "GROUP_BEST_AVAILABLE_COST"
        value = "380512"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 3 G-C"
        reference_type = "GROUP_BEST_AVAILABLE_COST"
        value = "393208"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 3 A-NC"
        reference_type = "GROUP_BEST_AVAILABLE_COST"
        value = "46047"
        instance_level = "False"
        verified = "False"
    },
    [pscustomobject]@{
        source = "Pitakaso et al. 2006"
        group = "TD1996 group 3 A-C"
        reference_type = "GROUP_BEST_AVAILABLE_COST"
        value = "44634"
        instance_level = "False"
        verified = "False"
    }
)

$literature |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TD1996-LITERATURE-GROUP-RESULTS.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating final TD1996 GitHub page"

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Tempelmeier-Derstroff 1996")
$page.Add("")
$page.Add("> Full-integration audit release v0.6.0.")
$page.Add("")
$page.Add("| Metric | Count |")
$page.Add("|---|---:|")
$page.Add("| Candidate files audited | **" + $inventory.Count + "** |")
$page.Add("| ZIP archives expanded | **" + $expanded.Count + "** |")
$page.Add("| INDEX.PRN directories found | **" + $contracts.Count + "** |")
$page.Add("| Recognized source contracts | **" + $knownContracts.Count + "** |")
$page.Add("| Unique recognized source directories | **" + $uniqueContracts.Count + "** |")
$page.Add("| Canonical TD1996 XML | **" + $tdXml.Count + "** |")
$page.Add("| Exact Stadtler C/D/E fingerprint pairs | **" + $crosswalk.Count + "** |")
$page.Add("")
$page.Add("## Provenance policy")
$page.Add("")
$page.Add("Only directories satisfying a known published MLCLSP source contract are converted. Unknown local files are inventoried but never interpreted by guesswork.")
$page.Add("")
$page.Add("## Literature results")
$page.Add("")
$page.Add("Group-level values from later literature are recorded separately from instance-level best-known objectives. They are never attached to individual XML files without an identity crosswalk.")
$page.Add("")
$page.Add("## Stadtler relation")
$page.Add("")
$page.Add("The published statement that some Stadtler C/D/E instances match Tempelmeier-Derstroff remains bibliographic evidence. Exact file-level mappings are promoted only when the native SupplyChainFingerprint agrees.")

[IO.File]::WriteAllLines(
    (Join-Path $tdRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.6.0 final summary"
Write-Host ("Candidate files audited: " + $inventory.Count)
Write-Host ("ZIP archives expanded: " + $expanded.Count)
Write-Host ("Recognized source contracts: " + $knownContracts.Count)
Write-Host ("Unique recognized source directories: " + $uniqueContracts.Count)
Write-Host ("TD1996 canonical XML: " + $tdXml.Count)
Write-Host ("Structural checker exit: " + $checkerExit)
Write-Host ("Exact TD1996 <-> Stadtler pairs: " + $crosswalk.Count)
Write-Host ("Reports: " + $reportRoot)
