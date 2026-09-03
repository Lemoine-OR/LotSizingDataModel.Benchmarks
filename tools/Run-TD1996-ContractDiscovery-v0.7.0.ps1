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

function Get-SafeHead {
    param(
        [string]$Path,
        [int]$MaxLines = 8
    )

    $lines = New-Object System.Collections.Generic.List[string]

    try {
        foreach ($line in Get-Content `
            -LiteralPath $Path `
            -TotalCount $MaxLines `
            -ErrorAction Stop) {

            $safe = [regex]::Replace(
                [string]$line,
                "[^\x09\x20-\x7E]",
                "?"
            )

            $lines.Add($safe)
        }
    }
    catch {
    }

    return $lines.ToArray()
}

function Get-DirectoryContractSignature {
    param([string]$Directory)

    $names = @(
        Get-ChildItem `
            -LiteralPath $Directory `
            -File `
            -ErrorAction SilentlyContinue |
        ForEach-Object {
            $_.Name.ToUpperInvariant()
        } |
        Sort-Object
    )

    return ($names -join ";")
}

function Get-DirectoryFingerprint {
    param([string]$Directory)

    $builder = New-Object Text.StringBuilder

    foreach ($file in (
        Get-ChildItem `
            -LiteralPath $Directory `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object Name
    )) {
        [void]$builder.Append(
            $file.Name.ToUpperInvariant()
        )
        [void]$builder.Append("|")
        [void]$builder.Append($file.Length)
        [void]$builder.Append("|")
        [void]$builder.Append(
            (Get-FileHash `
                -LiteralPath $file.FullName `
                -Algorithm SHA256
            ).Hash
        )
        [void]$builder.AppendLine()
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes(
        $builder.ToString()
    )

    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)

        return (
            [BitConverter]::ToString($hash)
        ).Replace("-","").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Classify-KnownContract {
    param([string]$Directory)

    $names = @(
        Get-ChildItem `
            -LiteralPath $Directory `
            -File `
            -ErrorAction SilentlyContinue |
        ForEach-Object {
            $_.Name.ToUpperInvariant()
        }
    )

    $set = @{}

    foreach ($name in $names) {
        $set[$name] = $true
    }

    $explicit = @(
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

    $datab = @(
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

    $isExplicit = $true

    foreach ($required in $explicit) {
        if (-not $set.ContainsKey($required)) {
            $isExplicit = $false
            break
        }
    }

    if ($isExplicit) {
        return "EXPLICIT_12_FILE_MLCLSP"
    }

    $isDatab = $true

    foreach ($required in $datab) {
        if (-not $set.ContainsKey($required)) {
            $isDatab = $false
            break
        }
    }

    if ($isDatab) {
        return "DATAB_BPLUS"
    }

    return "UNKNOWN"
}

function Extract-IndexDimensions {
    param([string]$IndexPath)

    $text = ""

    try {
        $text = [IO.File]::ReadAllText($IndexPath)
    }
    catch {
        return [pscustomobject]@{
            first_integers = ""
            raw_head = ""
        }
    }

    $ints = @(
        [regex]::Matches($text,"\d+") |
        Select-Object -First 20 |
        ForEach-Object {
            $_.Value
        }
    )

    $head = @(
        Get-SafeHead -Path $IndexPath -MaxLines 8
    ) -join " || "

    return [pscustomobject]@{
        first_integers = ($ints -join ";")
        raw_head = $head
    }
}

$tdRoot = Join-Path $BenchmarkRepo "benchmarks\TD1996"
$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$clsplRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.7.0"
$metadataRoot = Join-Path $tdRoot "metadata"
$instancesRoot = Join-Path $tdRoot "instances"
$checkerRoot = Join-Path $tdRoot "checker-reports"

foreach ($p in @(
    $tdRoot,
    $reportRoot,
    $metadataRoot,
    $instancesRoot,
    $checkerRoot
)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: preserving stabilized benchmark state"

$stadtlerExpected = @{
    "Aplus" = 240
    "Bplus" = 600
    "C" = 360
    "Cplus" = 240
    "D" = 360
    "Dplus" = 240
    "E" = 30
    "Eplus" = 30
}

$total = 0

foreach ($folder in $stadtlerExpected.Keys) {
    $count = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stadtlerRoot ($folder + "\instances")) `
            -Filter "*.xml" `
            -File `
            -ErrorAction SilentlyContinue
    ).Count

    if ($count -ne $stadtlerExpected[$folder]) {
        throw (
            "Stadtler regression in " +
            $folder
        )
    }

    $total += $count
}

if ($total -ne 2100) {
    throw "Stadtler total must remain 2100."
}

$clsplCatalogue = Join-Path $clsplRoot `
    "metadata\CLSPL-LITERATURE-REFERENCES.csv"

$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)

if ($clsplRows.Count -ne 1281) {
    throw "CLSPL must remain 1281 / 1281."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL: 1281 / 1281"

Write-Step "Building clean source search roots"

$roots = @(
    "D:\Dev",
    "D:\temp",
    (Join-Path $env:USERPROFILE "Documents"),
    (Join-Path $env:USERPROFILE "Downloads")
)

$indexFiles = New-Object System.Collections.Generic.List[object]
$seenDirectory = @{}

foreach ($rootPath in $roots) {
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        continue
    }

    foreach ($index in Get-ChildItem `
        -LiteralPath $rootPath `
        -Filter "INDEX.PRN" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue) {

        $full = $index.FullName

        if ($full -like ($BenchmarkRepo + "\benchmarks\STADTLER2003\*")) {
            continue
        }

        if ($full -like ($BenchmarkRepo + "\benchmarks\SUERIE_CLSPL\*")) {
            continue
        }

        if ($full -like ($BenchmarkRepo + "\reports\*")) {
            continue
        }

        if ($full -like ($BenchmarkRepo + "\tools\*")) {
            continue
        }

        $directory = $index.Directory.FullName
        $key = $directory.ToLowerInvariant()

        if (-not $seenDirectory.ContainsKey($key)) {
            $seenDirectory[$key] = $true

            $indexFiles.Add([pscustomobject]@{
                directory = $directory
                index_path = $full
            })
        }
    }
}

Write-Host ("Unique non-Stadtler/non-CLSPL INDEX.PRN directories: " + $indexFiles.Count)

Write-Step "Auditing unknown INDEX.PRN contracts by content"

$audit = New-Object System.Collections.Generic.List[object]
$fileAudit = New-Object System.Collections.Generic.List[object]

foreach ($entry in $indexFiles.ToArray()) {
    $dir = $entry.directory
    $classification = Classify-KnownContract -Directory $dir
    $signature = Get-DirectoryContractSignature -Directory $dir
    $fingerprint = Get-DirectoryFingerprint -Directory $dir
    $dimensions = Extract-IndexDimensions -IndexPath $entry.index_path

    $files = @(
        Get-ChildItem `
            -LiteralPath $dir `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object Name
    )

    $audit.Add([pscustomobject]@{
        directory = $dir
        classification = $classification
        file_count = $files.Count
        file_signature = $signature
        directory_fingerprint = $fingerprint
        index_first_integers = $dimensions.first_integers
        index_head = $dimensions.raw_head
    })

    foreach ($file in $files) {
        $head = @(
            Get-SafeHead -Path $file.FullName -MaxLines 5
        ) -join " || "

        $fileAudit.Add([pscustomobject]@{
            directory = $dir
            file_name = $file.Name
            length = $file.Length
            sha256 = (
                Get-FileHash `
                    -LiteralPath $file.FullName `
                    -Algorithm SHA256
            ).Hash
            safe_head = $head
        })
    }
}

$audit.ToArray() |
    Sort-Object classification,directory |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-contract-audit.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$fileAudit.ToArray() |
    Sort-Object directory,file_name |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-file-audit.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Grouping directories by file contract signature"

$contractGroups = @(
    $audit.ToArray() |
    Group-Object file_signature |
    Sort-Object Count -Descending
)

$groupRows = New-Object System.Collections.Generic.List[object]
$groupId = 0

foreach ($group in $contractGroups) {
    $groupId++

    $sample = $group.Group[0]

    $groupRows.Add([pscustomobject]@{
        contract_group = "G" + $groupId.ToString("D2")
        directory_count = $group.Count
        classification = $sample.classification
        file_count = $sample.file_count
        file_signature = $sample.file_signature
        sample_directory = $sample.directory
        sample_index_integers = $sample.index_first_integers
    })

    Write-Host (
        "G" +
        $groupId.ToString("D2") +
        ": directories=" +
        $group.Count +
        " classification=" +
        $sample.classification +
        " files=" +
        $sample.file_count
    )
}

$groupRows.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-contract-groups.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Comparing contract signatures with historical datab contract"

$databSignature = (
    "AUSLAST.PRN;DIREKT-B.PRN;FLAGS.PRN;INDEX.PRN;L0.PRN;LT.PRN;" +
    "MITT_BED.PRN;P-BEDARF.PRN;PRODKOEF.PRN;RUESTZ.PRN;SPARSE.PRN;" +
    "TBO.PRN;UEBER-KS.PRN;YFIX.PRN;ZFIX.PRN;ZFKOEF.PRN"
)

$comparison = New-Object System.Collections.Generic.List[object]

foreach ($group in $groupRows.ToArray()) {
    $names = @(
        $group.file_signature -split ";"
    )

    $databNames = @(
        $databSignature -split ";"
    )

    $missingFromGroup = @(
        $databNames |
        Where-Object {
            $names -notcontains $_
        }
    )

    $extraInGroup = @(
        $names |
        Where-Object {
            $databNames -notcontains $_
        }
    )

    $comparison.Add([pscustomobject]@{
        contract_group = $group.contract_group
        classification = $group.classification
        missing_vs_datab = ($missingFromGroup -join ";")
        extra_vs_datab = ($extraInGroup -join ";")
        exact_datab_signature = (
            $missingFromGroup.Count -eq 0 -and
            $extraInGroup.Count -eq 0
        )
    })
}

$comparison.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-contract-vs-datab.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$recognized = @(
    $audit.ToArray() |
    Where-Object {
        $_.classification -ne "UNKNOWN"
    }
)

$unknown = @(
    $audit.ToArray() |
    Where-Object {
        $_.classification -eq "UNKNOWN"
    }
)

Write-Host ("Recognized known contracts: " + $recognized.Count)
Write-Host ("Unknown contracts requiring evidence: " + $unknown.Count)

Write-Step "Classifying the 75 unresolved Stadtler literature codes"

$unmappedPath = Join-Path $stadtlerRoot `
    "metadata\STADTLER-LITERATURE-UNMAPPED-v0.4.3-R2.csv"

$unmapped = @(Import-Csv -LiteralPath $unmappedPath)

$classification75 = New-Object System.Collections.Generic.List[object]

foreach ($row in $unmapped) {
    $code = [string]$row.canonical_code
    $reason = "OUTSIDE_GENERATED_STADTLER_CAMPAIGN"
    $tdRelation = "NOT_PROVEN"

    if (-not [string]::IsNullOrWhiteSpace($code)) {
        if ($row.test_set -in @("C","D","E")) {
            $tdRelation = "POSSIBLE_TD1996_RELATED_CLASS"
        }

        if ($row.test_set -eq "LEGACY-CM") {
            $reason = "LEGACY_CLASSCM"
        }
    }

    $classification75.Add([pscustomobject]@{
        test_set = $row.test_set
        canonical_code = $code
        objective = $row.objective
        lower_bound = $row.lower_bound
        source_workbook = $row.source_workbook
        classification = $reason
        td1996_relation = $tdRelation
    })
}

$classification75.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-75-td1996-classification.csv") `
        -NoTypeInformation `
        -Encoding UTF8

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Contract audit and corpus preconditions are valid."
    exit 0
}

Write-Step "Converting only proven known contracts"

$converterProject = Join-Path $BenchmarkRepo `
    "tools\TempelmeierConverter\TempelmeierConverter.csproj"

if (-not (Test-Path -LiteralPath $converterProject -PathType Leaf)) {
    throw "TempelmeierConverter is missing."
}

& dotnet build `
    $converterProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TempelmeierConverter build failed."
}

$stageRoot = Join-Path $reportRoot "converted-staging"

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}

Ensure-Directory -Path $stageRoot

$conversion = New-Object System.Collections.Generic.List[object]
$ordinal = 0

foreach ($source in $recognized) {
    $ordinal++
    $target = Join-Path $stageRoot ("source_" + $ordinal.ToString("D4"))
    Ensure-Directory -Path $target

    $mode = "stadtler"

    if ($source.classification -eq "DATAB_BPLUS") {
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
        ForEach-Object {
            $_.ToString()
        }
    )

    $xmlCount = @(
        Get-ChildItem `
            -LiteralPath $target `
            -Filter "*.xml" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
    ).Count

    $conversion.Add([pscustomobject]@{
        source_directory = $source.directory
        classification = $source.classification
        converter_mode = $mode
        exit_code = $LASTEXITCODE
        xml_count = $xmlCount
        target = $target
    })

    Write-Host (
        "Converted " +
        $source.directory +
        ": xml=" +
        $xmlCount +
        " exit=" +
        $LASTEXITCODE
    )
}

$conversion.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "td1996-proven-contract-conversions.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$convertedXml = @(
    Get-ChildItem `
        -LiteralPath $stageRoot `
        -Filter "*.xml" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue
)

Write-Host ("Converted XML from proven contracts: " + $convertedXml.Count)

Write-Step "Promoting only unique converted XML"

$existingHashes = @{}

foreach ($file in Get-ChildItem `
    -LiteralPath $instancesRoot `
    -Filter "*.xml" `
    -File `
    -ErrorAction SilentlyContinue) {

    $hash = (
        Get-FileHash `
            -LiteralPath $file.FullName `
            -Algorithm SHA256
    ).Hash

    $existingHashes[$hash] = $true
}

$sourceHashes = @{}
$added = 0

foreach ($file in $convertedXml) {
    $hash = (
        Get-FileHash `
            -LiteralPath $file.FullName `
            -Algorithm SHA256
    ).Hash

    if ($sourceHashes.ContainsKey($hash)) {
        continue
    }

    $sourceHashes[$hash] = $true

    if ($existingHashes.ContainsKey($hash)) {
        continue
    }

    $added++
    $destination = Join-Path $instancesRoot (
        "LSDM_TD1996_MLCLSP_unknown_unknown_ID" +
        $added.ToString("D4") +
        ".xml"
    )

    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination $destination `
        -Force
}

$tdXml = @(
    Get-ChildItem `
        -LiteralPath $instancesRoot `
        -Filter "*.xml" `
        -File `
        -ErrorAction SilentlyContinue
)

Write-Host ("Canonical TD1996 XML after promotion: " + $tdXml.Count)

Write-Step "Running structural checker when XML exist"

$checkerExit = -1

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

Write-Host ("Checker exit: " + $checkerExit)

Write-Step "Generating GitHub contract-discovery page"

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Tempelmeier-Derstroff 1996")
$page.Add("")
$page.Add("> Contract discovery and conservative full-import release v0.7.0.")
$page.Add("")
$page.Add("| Metric | Count |")
$page.Add("|---|---:|")
$page.Add("| Non-Stadtler/non-CLSPL INDEX.PRN directories audited | **" + $audit.Count + "** |")
$page.Add("| Contract signature groups | **" + $contractGroups.Count + "** |")
$page.Add("| Recognized known contracts | **" + $recognized.Count + "** |")
$page.Add("| Unknown contracts | **" + $unknown.Count + "** |")
$page.Add("| Canonical TD1996 XML | **" + $tdXml.Count + "** |")
$page.Add("")
$page.Add("## Contract-first policy")
$page.Add("")
$page.Add("Unknown INDEX.PRN directories are not converted by guesswork. Their filenames, byte hashes, safe first records and structural signatures are retained in the v0.7.0 audit.")
$page.Add("")
$page.Add("The next parser extension, if needed, must be derived from these audited signatures rather than inferred from file names.")

[IO.File]::WriteAllLines(
    (Join-Path $tdRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.7.0 final summary"
Write-Host ("INDEX.PRN directories audited: " + $audit.Count)
Write-Host ("Contract groups: " + $contractGroups.Count)
Write-Host ("Recognized known contracts: " + $recognized.Count)
Write-Host ("Unknown contracts: " + $unknown.Count)
Write-Host ("Converted XML from proven contracts: " + $convertedXml.Count)
Write-Host ("Canonical TD1996 XML: " + $tdXml.Count)
Write-Host ("Checker exit: " + $checkerExit)
Write-Host ("Reports: " + $reportRoot)
