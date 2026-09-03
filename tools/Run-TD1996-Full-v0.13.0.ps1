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

$sourceArchive = Join-Path $TempDir "tempelmeir destroff.zip"
$familyRoot = Join-Path $BenchmarkRepo "benchmarks\TD1996"
$rawRoot = Join-Path $familyRoot "raw\user-provided"
$upstreamRoot = Join-Path $rawRoot "upstream"
$extractedRoot = Join-Path $rawRoot "extracted"
$instancesRoot = Join-Path $familyRoot "instances"
$metadataRoot = Join-Path $familyRoot "metadata"
$checkerRoot = Join-Path $familyRoot "checker-reports\v0.13.0"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.13.0"
$fingerprintRoot = Join-Path $reportRoot "fingerprints"
$stagingRoot = Join-Path $reportRoot "conversion-staging"

foreach ($p in @(
    $familyRoot,$rawRoot,$upstreamRoot,$extractedRoot,$instancesRoot,
    $metadataRoot,$checkerRoot,$reportRoot,$fingerprintRoot,$stagingRoot
)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: stabilized ecosystem invariants"

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

$clsplPath = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

if (@(Import-Csv -LiteralPath $clsplPath).Count -ne 1281) {
    throw "CLSPL invariant failed."
}

$trigeiroRoot = Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989\instances"
if (@(Get-ChildItem -LiteralPath $trigeiroRoot -Filter "*.xml" -File).Count -ne 751) {
    throw "Trigeiro authoritative invariant failed."
}

Write-Host "Stadtler : 2100 / 2100"
Write-Host "CLSPL    : 1281 / 1281"
Write-Host "Trigeiro : 751 / 751"

Write-Step "Validating user-provided Tempelmeier-Derstroff archive"

if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw "Required source archive not found: D:\temp\tempelmeir destroff.zip"
}

$sourceSha = (
    Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256
).Hash

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($sourceArchive)

try {
    $datCount = @(
        $zip.Entries |
        Where-Object { $_.FullName -match "(?i)\.dat$" }
    ).Count
}
finally {
    $zip.Dispose()
}

Write-Host ("Source SHA256: " + $sourceSha)
Write-Host ("DAT entries  : " + $datCount)

if ($datCount -ne 3450) {
    throw (
        "TD1996 archive cardinality failed: expected 3450 DAT, found " +
        $datCount
    )
}

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "TD1996 source cardinality and ecosystem invariants are valid."
    exit 0
}

Write-Step "Preserving immutable source archive"

$repoArchive = Join-Path $upstreamRoot "tempelmeir destroff.zip"

if (Test-Path -LiteralPath $repoArchive -PathType Leaf) {
    $existingSha = (
        Get-FileHash -LiteralPath $repoArchive -Algorithm SHA256
    ).Hash

    if ($existingSha -ne $sourceSha) {
        throw "Immutable TD1996 source archive conflict."
    }
}
else {
    Copy-Item -LiteralPath $sourceArchive -Destination $repoArchive -Force
}

@(
    [pscustomobject]@{
        family = "TD1996"
        source_role = "USER_PROVIDED_BENCHMARK_CORPUS"
        file = "tempelmeir destroff.zip"
        sha256 = $sourceSha
        dat_instances = 3450
        acquired_utc = [DateTime]::UtcNow.ToString("o")
        source_signature = "Instance pour le MLSCLSP Tempelmeier"
    }
) |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TD1996-PROVENANCE-v0.13.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Extracting immutable source files"

if (Test-Path -LiteralPath $extractedRoot) {
    Remove-Item -LiteralPath $extractedRoot -Recurse -Force
}
Ensure-Directory -Path $extractedRoot

Expand-Archive `
    -LiteralPath $repoArchive `
    -DestinationPath $extractedRoot `
    -Force

$rawFiles = @(
    Get-ChildItem -LiteralPath $extractedRoot -Filter "*.dat" -File -Recurse
)

if ($rawFiles.Count -ne 3450) {
    throw "Extracted TD1996 corpus must contain 3450 DAT files."
}

Write-Step "Building dedicated TD1996 importer"

$importerProject = Join-Path $BenchmarkRepo `
    "tools\TD1996Importer\TD1996Importer.csproj"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TD1996Importer build failed."
}

Write-Step "Auditing all 3450 source files before conversion"

$auditRoot = Join-Path $reportRoot "audit"
Ensure-Directory -Path $auditRoot

& dotnet run `
    --project $importerProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    $extractedRoot `
    $stagingRoot `
    $auditRoot `
    --audit-only

if ($LASTEXITCODE -ne 0) {
    throw "TD1996 full-source audit failed."
}

$auditManifest = Join-Path $auditRoot "TD1996-CONVERSION-MANIFEST.csv"
$auditRows = @(Import-Csv -LiteralPath $auditManifest)

if ($auditRows.Count -ne 3450 -or @($auditRows | Where-Object { $_.status -ne "AUDIT_VALID" }).Count -ne 0) {
    throw "TD1996 audit postcondition failed."
}

$classGroups = @(
    $auditRows |
    Group-Object class_id |
    Sort-Object Name
)

foreach ($group in $classGroups) {
    Write-Host ($group.Name + ": " + $group.Count)
}

$noResource = (
    $auditRows |
    Measure-Object -Property items_without_resource_signal -Sum
).Sum

$positiveSetupNoResource = (
    $auditRows |
    Measure-Object -Property positive_setup_time_without_resource_signal -Sum
).Sum

Write-Host ("Item rows without resource signal             : " + $noResource)
Write-Host ("... with positive setup time                 : " + $positiveSetupNoResource)

Write-Step "Converting all 3450 TD1996 instances to LotSizingDataModel"

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
Ensure-Directory -Path $stagingRoot

& dotnet run `
    --project $importerProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    $extractedRoot `
    $stagingRoot `
    $reportRoot

if ($LASTEXITCODE -ne 0) {
    throw "TD1996 conversion failed."
}

$manifest = Join-Path $reportRoot "TD1996-CONVERSION-MANIFEST.csv"
$rows = @(Import-Csv -LiteralPath $manifest)
$converted = @($rows | Where-Object { $_.status -eq "CONVERTED" })

if ($rows.Count -ne 3450 -or $converted.Count -ne 3450) {
    throw (
        "TD1996 conversion postcondition failed: rows=" +
        $rows.Count +
        " converted=" +
        $converted.Count
    )
}

$stagedXml = @(
    Get-ChildItem -LiteralPath $stagingRoot -Filter "*.xml" -File
)

if ($stagedXml.Count -ne 3450) {
    throw "TD1996 staging must contain exactly 3450 XML."
}

Write-Step "Publishing canonical TD1996 corpus idempotently"

$backupRoot = Join-Path $reportRoot "previous-TD1996-instances"
Ensure-Directory -Path $backupRoot

foreach ($old in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    Copy-Item -LiteralPath $old.FullName -Destination (Join-Path $backupRoot $old.Name) -Force
    Remove-Item -LiteralPath $old.FullName -Force
}

foreach ($file in $stagedXml) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $instancesRoot $file.Name) -Force
}

$canonical = @(
    Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File
)

if ($canonical.Count -ne 3450) {
    throw "Canonical TD1996 corpus must contain exactly 3450 XML."
}

Write-Step "Running structural Checker on 3450 canonical instances"

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

if ($LASTEXITCODE -ne 0) {
    throw "TD1996 structural Checker failed."
}

Write-Host "Structural Checker: VALID"

Write-Step "Computing TD1996 batch fingerprints"

$batchProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

if (-not (Test-Path -LiteralPath $batchProject -PathType Leaf)) {
    throw "Batch fingerprint tool required from v0.4.2."
}

& dotnet build `
    $batchProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Batch fingerprint tool build failed."
}

$fileManifest = Join-Path $fingerprintRoot "td1996-files.txt"
$fpCsv = Join-Path $fingerprintRoot "td1996-fingerprints.csv"

[IO.File]::WriteAllLines(
    $fileManifest,
    @($canonical | Sort-Object Name | ForEach-Object { $_.FullName }),
    (New-Object Text.UTF8Encoding($false))
)

& dotnet run `
    --project $batchProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    "TD1996" `
    $fileManifest `
    $fpCsv

if ($LASTEXITCODE -ne 0) {
    throw "TD1996 fingerprint campaign failed."
}

$fps = @(Import-Csv -LiteralPath $fpCsv)

if ($fps.Count -ne 3450) {
    throw "TD1996 fingerprint postcondition failed."
}

Write-Host "Fingerprints: 3450 / 3450"

Write-Step "Building exact cross-family fingerprint catalogue"

$otherSources = @(
    [pscustomobject]@{
        family = "STADTLER2003"
        path = (Join-Path $BenchmarkRepo "reports\v0.4.2\fingerprints\stadtler-fingerprints.csv")
    },
    [pscustomobject]@{
        family = "SUERIE_CLSPL"
        path = (Join-Path $BenchmarkRepo "reports\v0.4.2\fingerprints\clspl-fingerprints.csv")
    },
    [pscustomobject]@{
        family = "TRIGEIRO1989"
        path = (Join-Path $BenchmarkRepo "reports\v0.11.0\fingerprints\v0.11.0-fingerprints.csv")
    }
)

$tdByFp = @{}
foreach ($row in $fps) {
    if (-not $tdByFp.ContainsKey($row.fingerprint)) {
        $tdByFp[$row.fingerprint] =
            New-Object System.Collections.Generic.List[object]
    }
    $tdByFp[$row.fingerprint].Add($row)
}

$cross = New-Object System.Collections.Generic.List[object]

foreach ($source in $otherSources) {
    if (-not (Test-Path -LiteralPath $source.path -PathType Leaf)) {
        continue
    }

    foreach ($other in Import-Csv -LiteralPath $source.path) {
        if (-not $tdByFp.ContainsKey($other.fingerprint)) {
            continue
        }

        foreach ($td in $tdByFp[$other.fingerprint].ToArray()) {
            $cross.Add([pscustomobject]@{
                fingerprint = $td.fingerprint
                td1996_filename = $td.filename
                other_family = $source.family
                other_filename = $other.filename
                relation = "EXACT_SUPPLY_CHAIN_FINGERPRINT"
            })
        }
    }
}

$cross.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TD1996-CROSS-FAMILY-FINGERPRINTS-v0.13.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Exact cross-family pairs: " + $cross.Count)

Write-Step "Generating class catalogues and GitHub pages"

$catalog = New-Object System.Collections.Generic.List[object]

foreach ($row in $rows) {
    $catalog.Add([pscustomobject]@{
        instance_id = $row.instance_id
        class_id = $row.class_id
        items = $row.items
        periods = $row.periods
        resources = $row.resources
        finished_products = $row.finished_products
        bom_arcs = $row.bom_arcs
        items_without_resource_signal = $row.items_without_resource_signal
        positive_setup_time_without_resource_signal = $row.positive_setup_time_without_resource_signal
        xml_file = $row.xml_file
        source_sha256 = $row.source_sha256
        reference_status = "UNKNOWN_REFERENCE"
    })
}

$catalog.ToArray() |
    Sort-Object class_id,instance_id |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TD1996-CANONICAL-CATALOG-v0.13.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Tempelmeier-Derstroff 1996 benchmark")
$page.Add("")
$page.Add("> Complete user-provided 3450-instance corpus integrated in LotSizingDataModel.Benchmarks v0.13.0.")
$page.Add("")
$page.Add("| Metric | Count |")
$page.Add("|---|---:|")
$page.Add("| Source DAT files | **3450** |")
$page.Add("| Canonical LotSizingDataModel XML | **3450** |")
$page.Add("| Structural Checker invalid | **0** |")
$page.Add("| Fingerprinted XML | **3450** |")
$page.Add("| Exact cross-family fingerprint pairs | **" + $cross.Count + "** |")
$page.Add("")
$page.Add("## Structural classes")
$page.Add("")
$page.Add("| Class | Instances |")
$page.Add("|---|---:|")

foreach ($group in $classGroups) {
    $page.Add("| " + $group.Name + " | **" + $group.Count + "** |")
}

$page.Add("")
$page.Add("## Source-format ambiguity")
$page.Add("")
$page.Add("Resource membership is explicit when a `CL_Produit` resource component is nonzero. The supplied format contains " + $noResource + " item rows whose entire setup-cost resource vector is zero. Of these, " + $positiveSetupNoResource + " have a positive scalar setup time. v0.13.0 does not invent a resource for those rows; the ambiguity is retained explicitly in the metadata catalogue.")
$page.Add("")
$page.Add("## Reference values")
$page.Add("")
$page.Add("No best-known objective or optimality status is promoted by this release. Reference status remains `UNKNOWN_REFERENCE` pending a dedicated trust-gate reconciliation.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.13.0 final postconditions"

Write-Host "Tempelmeier-Derstroff 1996 Full Integration"
Write-Host "==========================================="
Write-Host "Source DAT instances        : 3450"
Write-Host "Canonical LSDM XML          : 3450"
Write-Host "Structural Checker          : VALID"
Write-Host "Fingerprints                : 3450 / 3450"
Write-Host ("Item rows no resource signal: " + $noResource)
Write-Host ("Positive setup/no resource  : " + $positiveSetupNoResource)
Write-Host ("Cross-family exact pairs    : " + $cross.Count)
Write-Host "Reference values            : UNRECONCILED"
Write-Host ("Reports                     : " + $reportRoot)
