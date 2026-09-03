param(
    [string]$TempDir = "D:\temp",
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

$sourceArchive = Join-Path $TempDir "E1.zip"
$familyRoot = Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989"
$rawRoot = Join-Path $familyRoot "raw\user-E1"
$rawUpstream = Join-Path $rawRoot "upstream"
$rawExtracted = Join-Path $rawRoot "extracted"
$instancesRoot = Join-Path $familyRoot "instances"
$metadataRoot = Join-Path $familyRoot "metadata"
$checkerRoot = Join-Path $familyRoot "checker-reports\v0.10.0"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.10.0"
$fingerprintRoot = Join-Path $reportRoot "fingerprints"

foreach ($path in @(
    $familyRoot,
    $rawRoot,
    $rawUpstream,
    $rawExtracted,
    $instancesRoot,
    $metadataRoot,
    $checkerRoot,
    $reportRoot,
    $fingerprintRoot
)) {
    Ensure-Directory -Path $path
}

Write-Step "Preflight: established family invariants"

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$expected = @{
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

foreach ($folder in $expected.Keys) {
    $count = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stadtlerRoot ($folder + "\instances")) `
            -Filter "*.xml" `
            -File `
            -ErrorAction SilentlyContinue
    ).Count

    if ($count -ne $expected[$folder]) {
        throw ("Stadtler invariant failed in " + $folder)
    }

    $total += $count
}

if ($total -ne 2100) {
    throw "Stadtler total invariant failed."
}

$clsplCatalogue = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)

if ($clsplRows.Count -ne 1281) {
    throw "CLSPL invariant failed."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL: 1281 / 1281"

Write-Step "Validating user-provided E1.zip"

if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw (
        "E1.zip not found in D:\temp. Place the user-provided dual-format archive there."
    )
}

$sourceHash = (
    Get-FileHash `
        -LiteralPath $sourceArchive `
        -Algorithm SHA256
).Hash

$sourceLength = (
    Get-Item -LiteralPath $sourceArchive
).Length

Write-Host ("E1.zip SHA256: " + $sourceHash)
Write-Host ("E1.zip bytes : " + $sourceLength)

if ($DryRun) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archive = [IO.Compression.ZipFile]::OpenRead($sourceArchive)

    try {
        $datCount = @(
            $archive.Entries |
            Where-Object {
                $_.FullName -match "(?i)\.dat$"
            }
        ).Count

        $trigCount = @(
            $archive.Entries |
            Where-Object {
                $_.FullName -match "(?i)\.trig$"
            }
        ).Count

        Write-Host ("DAT entries : " + $datCount)
        Write-Host ("TRIG entries: " + $trigCount)

        if ($datCount -ne 751 -or $trigCount -ne 751) {
            throw (
                "E1.zip postcondition failed: expected 751 DAT and 751 TRIG."
            )
        }
    }
    finally {
        $archive.Dispose()
    }

    Write-Step "Dry-run complete"
    Write-Host "E1.zip dual-format cardinality is valid."
    exit 0
}

Write-Step "Preserving immutable source archive"

$archivedZip = Join-Path $rawUpstream "E1.zip"

if (Test-Path -LiteralPath $archivedZip -PathType Leaf) {
    $existingHash = (
        Get-FileHash `
            -LiteralPath $archivedZip `
            -Algorithm SHA256
    ).Hash

    if ($existingHash -ne $sourceHash) {
        throw (
            "Immutable source conflict: repository E1.zip differs from D:\temp\E1.zip."
        )
    }
}
else {
    Copy-Item `
        -LiteralPath $sourceArchive `
        -Destination $archivedZip `
        -Force
}

@(
    [pscustomobject]@{
        family = "TRIGEIRO1989"
        source = "USER_PROVIDED_E1_ZIP"
        source_path = $sourceArchive
        repository_path = $archivedZip
        sha256 = $sourceHash
        bytes = $sourceLength
        dat_expected = 751
        trig_expected = 751
        acquired_utc = [DateTime]::UtcNow.ToString("o")
    }
) |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-E1-PROVENANCE.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Extracting dual-format corpus"

if (Test-Path -LiteralPath $rawExtracted -PathType Container) {
    Remove-Item `
        -LiteralPath $rawExtracted `
        -Recurse `
        -Force
}

Ensure-Directory -Path $rawExtracted

Expand-Archive `
    -LiteralPath $archivedZip `
    -DestinationPath $rawExtracted `
    -Force

$datFiles = @(
    Get-ChildItem `
        -LiteralPath $rawExtracted `
        -Filter "*.dat" `
        -File `
        -Recurse
)

$trigFiles = @(
    Get-ChildItem `
        -LiteralPath $rawExtracted `
        -Filter "*.trig" `
        -File `
        -Recurse
)

Write-Host ("DAT files : " + $datFiles.Count)
Write-Host ("TRIG files: " + $trigFiles.Count)

if ($datFiles.Count -ne 751 -or $trigFiles.Count -ne 751) {
    throw (
        "Extracted corpus cardinality failed: expected 751 DAT + 751 TRIG."
    )
}

Write-Step "Building dedicated dual-format importer"

$importerProject = Join-Path $BenchmarkRepo `
    "tools\TrigeiroDualImporter\TrigeiroDualImporter.csproj"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TrigeiroDualImporter build failed."
}

Write-Step "Reconciling 751 DAT/TRIG pairs and converting canonical LSDM"

$stagingRoot = Join-Path $reportRoot "conversion-staging"

if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
    Remove-Item `
        -LiteralPath $stagingRoot `
        -Recurse `
        -Force
}

Ensure-Directory -Path $stagingRoot

& dotnet run `
    --project $importerProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    $rawExtracted `
    $stagingRoot `
    $reportRoot

$importExit = $LASTEXITCODE

if ($importExit -ne 0) {
    throw (
        "Dual-format reconciliation/import failed with exit code " +
        $importExit
    )
}

$reconciliationPath = Join-Path $reportRoot `
    "TRIGEIRO-DUAL-RECONCILIATION.csv"

$reconciliation = @(
    Import-Csv -LiteralPath $reconciliationPath
)

$accepted = @(
    $reconciliation |
    Where-Object {
        $_.status -like "DUAL_FORMAT_*" -and
        $_.status -ne "DUAL_FORMAT_REJECTED"
    }
)

$rejected = @(
    $reconciliation |
    Where-Object {
        $_.status -eq "DUAL_FORMAT_REJECTED" -or
        $_.status -eq "EXCEPTION" -or
        $_.status -like "MISSING_*"
    }
)

Write-Host ("Reconciled accepted: " + $accepted.Count)
Write-Host ("Rejected/missing    : " + $rejected.Count)

if ($accepted.Count -ne 751 -or $rejected.Count -ne 0) {
    throw (
        "Reconciliation postcondition failed: expected 751 accepted and 0 rejected."
    )
}

$setupLoss = @(
    $reconciliation |
    Where-Object {
        $_.status -eq "DUAL_FORMAT_RECONCILED_DAT_SETUP_TIME_LOSS"
    }
)

$exactDual = @(
    $reconciliation |
    Where-Object {
        $_.status -eq "DUAL_FORMAT_EXACT"
    }
)

Write-Host ("Exact dual-format pairs : " + $exactDual.Count)
Write-Host ("DAT setup-time loss pairs: " + $setupLoss.Count)

Write-Step "Replacing partial 31-instance canonical corpus with reconciled 751 corpus"

$backupRoot = Join-Path $reportRoot "previous-canonical-backup"

if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    Remove-Item `
        -LiteralPath $backupRoot `
        -Recurse `
        -Force
}

Ensure-Directory -Path $backupRoot

foreach ($file in Get-ChildItem `
    -LiteralPath $instancesRoot `
    -Filter "*.xml" `
    -File `
    -ErrorAction SilentlyContinue) {

    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination (Join-Path $backupRoot $file.Name) `
        -Force
}

foreach ($file in Get-ChildItem `
    -LiteralPath $instancesRoot `
    -Filter "*.xml" `
    -File `
    -ErrorAction SilentlyContinue) {

    Remove-Item `
        -LiteralPath $file.FullName `
        -Force
}

foreach ($file in Get-ChildItem `
    -LiteralPath $stagingRoot `
    -Filter "*.xml" `
    -File) {

    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination (Join-Path $instancesRoot $file.Name) `
        -Force
}

$canonical = @(
    Get-ChildItem `
        -LiteralPath $instancesRoot `
        -Filter "*.xml" `
        -File
)

if ($canonical.Count -ne 751) {
    throw (
        "Canonical corpus postcondition failed: expected 751 XML, found " +
        $canonical.Count
    )
}

Write-Host "Canonical Trigeiro corpus: 751 / 751"

Write-Step "Running full structural Checker campaign"

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

if ($checkerExit -ne 0) {
    throw (
        "Trigeiro 751 structural Checker failed with exit code " +
        $checkerExit
    )
}

Write-Host "Structural Checker: VALID"

Write-Step "Building series and size catalogue"

$catalogue = New-Object System.Collections.Generic.List[object]

foreach ($row in $reconciliation) {
    if ([string]::IsNullOrWhiteSpace($row.xml_file)) {
        continue
    }

    $series = ""

    if ($row.instance_id -match "^(?<s>[A-Za-z]+)") {
        $series = $Matches["s"].ToUpperInvariant()
    }

    $catalogue.Add([pscustomobject]@{
        instance_id = $row.instance_id
        series = $series
        items = $row.items
        periods = $row.periods
        reconciliation_status = $row.status
        xml_file = $row.xml_file
        dat_sha256 = $row.dat_sha256
        trig_sha256 = $row.trig_sha256
        xml_sha256 = $row.xml_sha256
        reference_status = "UNKNOWN_REFERENCE"
    })
}

$catalogue.ToArray() |
    Sort-Object series,instance_id |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-CANONICAL-CATALOG-v0.10.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$seriesGroups = @(
    $catalogue.ToArray() |
    Group-Object series |
    Sort-Object Name
)

foreach ($group in $seriesGroups) {
    Write-Host (
        "Series " +
        $group.Name +
        ": " +
        $group.Count
    )
}

Write-Step "Computing batch fingerprints"

$batchProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

if (Test-Path -LiteralPath $batchProject -PathType Leaf) {
    $manifestPath = Join-Path $fingerprintRoot "trigeiro751-files.txt"

    [IO.File]::WriteAllLines(
        $manifestPath,
        @($canonical | ForEach-Object { $_.FullName }),
        (New-Object Text.UTF8Encoding($false))
    )

    $fpCsv = Join-Path $fingerprintRoot "trigeiro751-fingerprints.csv"

    & dotnet build `
        $batchProject `
        -c Release `
        --nologo `
        -p:ModelRepo=$ModelRepo

    if ($LASTEXITCODE -ne 0) {
        throw "Batch fingerprint tool build failed."
    }

    & dotnet run `
        --project $batchProject `
        -c Release `
        --no-build `
        -p:ModelRepo=$ModelRepo `
        -- `
        "TRIGEIRO1989" `
        $manifestPath `
        $fpCsv

    if ($LASTEXITCODE -ne 0) {
        throw "Trigeiro 751 batch fingerprint failed."
    }

    $fpRows = @(
        Import-Csv -LiteralPath $fpCsv
    )

    if ($fpRows.Count -ne 751) {
        throw (
            "Fingerprint postcondition failed: expected 751, found " +
            $fpRows.Count
        )
    }

    Write-Host "Fingerprints: 751 / 751"
}
else {
    Write-Warning "Batch fingerprint tool unavailable; conversion remains valid."
}

Write-Step "Generating GitHub family pages"

$page = New-Object System.Collections.Generic.List[string]

$page.Add("# Trigeiro et al. 1989 benchmark")
$page.Add("")
$page.Add("> Complete dual-format user corpus integrated by LotSizingDataModel.Benchmarks v0.10.0.")
$page.Add("")
$page.Add("| Metric | Count |")
$page.Add("|---|---:|")
$page.Add("| Canonical instance identities | **751** |")
$page.Add("| DAT representations | **751** |")
$page.Add("| TRIG representations | **751** |")
$page.Add("| Canonical LotSizingDataModel XML | **751** |")
$page.Add("| Structural Checker invalid | **0** |")
$page.Add("| Exact DAT/TRIG field reconciliation | **" + $exactDual.Count + "** |")
$page.Add("| Reconciled DAT setup-time-loss cases | **" + $setupLoss.Count + "** |")
$page.Add("")
$page.Add("## Series")
$page.Add("")
$page.Add("| Series | Instances |")
$page.Add("|---|---:|")

foreach ($group in $seriesGroups) {
    $page.Add(
        "| " +
        $group.Name +
        " | **" +
        $group.Count +
        "** |"
    )
}

$page.Add("")
$page.Add("## Dual-format trust rule")
$page.Add("")
$page.Add("DAT and TRIG must agree on dimensions, demand, scalar capacity, unit production times, holding costs and setup costs.")
$page.Add("")
$page.Add("The complete DAT corpus stores zero values in `C_t_l_Produit*`. When all shared fields match, this systematic DAT loss is explicitly recorded and the TRIG setup-time field is retained canonically. Any non-systematic mismatch rejects the pair.")
$page.Add("")
$page.Add("## Reference values")
$page.Add("")
$page.Add("Best-known objectives are intentionally left `UNKNOWN_REFERENCE` until reconciled from instance-level literature or complete solutions checked by LotSizingDataModel.Checker.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

$open = New-Object System.Collections.Generic.List[string]
$open.Add("# Trigeiro 1989 reference-value challenges")
$open.Add("")
$open.Add("The complete 751-instance structural corpus is integrated. The next trust-gate stage is the reconciliation of best-known objectives, lower bounds and complete solutions.")
$open.Add("")
$open.Add("| Series | Instances | Reference status |")
$open.Add("|---|---:|---|")

foreach ($group in $seriesGroups) {
    $open.Add(
        "| " +
        $group.Name +
        " | " +
        $group.Count +
        " | UNKNOWN_REFERENCE |"
    )
}

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "OPEN-CHALLENGES.md"),
    $open.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.10.0 final postconditions"

Write-Host "Trigeiro 1989 Complete Dual-Format Corpus"
Write-Host "=========================================="
Write-Host "Source archive              : E1.zip"
Write-Host ("Source SHA256               : " + $sourceHash)
Write-Host "Canonical identities        : 751"
Write-Host "DAT files                   : 751"
Write-Host "TRIG files                  : 751"
Write-Host ("Exact dual pairs            : " + $exactDual.Count)
Write-Host ("Setup-loss reconciled pairs : " + $setupLoss.Count)
Write-Host "Canonical LSDM XML          : 751"
Write-Host "Structural Checker          : VALID"
Write-Host "Reference values            : UNRECONCILED / no invented values"
Write-Host ("Reports                     : " + $reportRoot)
