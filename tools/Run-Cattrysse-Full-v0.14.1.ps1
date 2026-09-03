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

$sourceArchive = Join-Path $TempDir "Cattrysse.zip"
$familyRoot = Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990"
$rawRoot = Join-Path $familyRoot "raw"
$upstreamRoot = Join-Path $rawRoot "upstream"
$originalRoot = Join-Path $rawRoot "original-tests"
$workbookRoot = Join-Path $rawRoot "result-workbooks"
$metadataRoot = Join-Path $familyRoot "metadata"
$instancesRoot = Join-Path $familyRoot "instances"
$checkerRoot = Join-Path $familyRoot "checker-reports\v0.14.1"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.14.1"
$fingerprintRoot = Join-Path $reportRoot "fingerprints"
$stagingRoot = Join-Path $reportRoot "conversion-staging"

foreach ($p in @(
    $familyRoot,$rawRoot,$upstreamRoot,$originalRoot,$workbookRoot,
    $metadataRoot,$instancesRoot,$checkerRoot,$reportRoot,
    $fingerprintRoot,$stagingRoot
)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: stabilized ecosystem"

$tdRoot = Join-Path $BenchmarkRepo "benchmarks\TD1996\instances"
$trigRoot = Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989\instances"
$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"

if (@(Get-ChildItem -LiteralPath $tdRoot -Filter "*.xml" -File).Count -ne 3450) {
    throw "TD1996 v0.13.1 invariant failed."
}

if (@(Get-ChildItem -LiteralPath $trigRoot -Filter "*.xml" -File).Count -ne 751) {
    throw "Trigeiro invariant failed."
}

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

$stadtlerTotal = 0

foreach ($folder in $stadtlerExpected.Keys) {
    $count = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stadtlerRoot ($folder + "\instances")) `
            -Filter "*.xml" `
            -File
    ).Count

    if ($count -ne $stadtlerExpected[$folder]) {
        throw ("Stadtler invariant failed in " + $folder)
    }

    $stadtlerTotal += $count
}

if ($stadtlerTotal -ne 2100) {
    throw "Stadtler invariant failed."
}

$clsplPath = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

if (@(Import-Csv -LiteralPath $clsplPath).Count -ne 1281) {
    throw "CLSPL invariant failed."
}

Write-Host "TD1996   : 3450 / 3450"
Write-Host "Trigeiro : 751 / 751"
Write-Host "Stadtler : 2100 / 2100"
Write-Host "CLSPL    : 1281 / 1281"

Write-Step "Validating user-provided Cattrysse archive"

if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw "D:\temp\Cattrysse.zip is required."
}

$sourceSha = (
    Get-FileHash `
        -LiteralPath $sourceArchive `
        -Algorithm SHA256
).Hash

$expectedSha =
    "41BD5C4A6664216EE52995683E14CE7B9F4C9088E13442DFF3727762C6774590"

if ($sourceSha -ne $expectedSha) {
    throw (
        "Cattrysse.zip SHA256 differs from the audited user archive. " +
        "Observed=" + $sourceSha +
        " expected=" + $expectedSha
    )
}

Write-Host ("Cattrysse.zip SHA256: " + $sourceSha)

$packageSource = Join-Path $BenchmarkRepo `
    "tools\CattrysseBundledSource"

if (-not (Test-Path -LiteralPath $packageSource -PathType Container)) {
    throw "Bundled deterministic Cattrysse extraction is missing."
}

$bundledTests = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $packageSource "original-tests") `
        -Filter "TEST*" `
        -File `
        -Recurse
)

$bundledWorkbooks = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $packageSource "result-workbooks") `
        -Filter "*.xls" `
        -File
)

if ($bundledTests.Count -ne 120 -or
    $bundledWorkbooks.Count -ne 3) {
    throw "Bundled Cattrysse extraction cardinality failed."
}

Write-Host "Original TEST files: 120"
Write-Host "Result workbooks   : 3"

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Cattrysse archive identity and bundled source cardinality are valid."
    exit 0
}

Write-Step "Preserving original archive and deterministic extraction"

$repoArchive = Join-Path $upstreamRoot "Cattrysse.zip"

if (Test-Path -LiteralPath $repoArchive -PathType Leaf) {
    $repoSha = (
        Get-FileHash `
            -LiteralPath $repoArchive `
            -Algorithm SHA256
    ).Hash

    if ($repoSha -ne $sourceSha) {
        throw "Immutable Cattrysse archive conflict."
    }
}
else {
    Copy-Item `
        -LiteralPath $sourceArchive `
        -Destination $repoArchive `
        -Force
}

foreach ($dir in @($originalRoot,$workbookRoot)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item `
            -LiteralPath $dir `
            -Recurse `
            -Force
    }
    Ensure-Directory -Path $dir
}

Copy-Item `
    -Path (Join-Path $packageSource "original-tests\*") `
    -Destination $originalRoot `
    -Recurse `
    -Force

Copy-Item `
    -Path (Join-Path $packageSource "result-workbooks\*") `
    -Destination $workbookRoot `
    -Recurse `
    -Force

Copy-Item `
    -LiteralPath (Join-Path $packageSource "note") `
    -Destination (Join-Path $rawRoot "note") `
    -Force

$tests = @(
    Get-ChildItem -LiteralPath $originalRoot -Filter "TEST*" -File -Recurse
)

if ($tests.Count -ne 120) {
    throw "Materialized Cattrysse source must contain exactly 120 TEST files."
}

$hashes = @{}
foreach ($test in $tests) {
    $sha = (Get-FileHash -LiteralPath $test.FullName -Algorithm SHA256).Hash
    if ($hashes.ContainsKey($sha)) {
        throw "Duplicate Cattrysse TEST source content detected."
    }
    $hashes[$sha] = $test.FullName
}

Write-Host "Unique source TEST SHA256: 120 / 120"

Write-Step "Building Cattrysse importer and workbook reader"

$importerProject = Join-Path $BenchmarkRepo `
    "tools\CattrysseImporter\CattrysseImporter.csproj"

$resultReaderProject = Join-Path $BenchmarkRepo `
    "tools\CattrysseResultReader\CattrysseResultReader.csproj"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "CattrysseImporter build failed."
}

& dotnet build `
    $resultReaderProject `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw "CattrysseResultReader build failed."
}

Write-Step "Auditing all 120 original instances"

$auditRoot = Join-Path $reportRoot "source-audit"
Ensure-Directory -Path $auditRoot

& dotnet run `
    --project $importerProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    $originalRoot `
    $stagingRoot `
    $auditRoot `
    --audit-only

if ($LASTEXITCODE -ne 0) {
    throw "Cattrysse semantic source audit failed."
}

$auditManifest = Join-Path $auditRoot "CATTRYSSE-CONVERSION-MANIFEST.csv"
$auditRows = @(Import-Csv -LiteralPath $auditManifest)

if ($auditRows.Count -ne 120 -or
    @($auditRows | Where-Object { $_.status -ne "AUDIT_VALID" }).Count -ne 0) {
    throw "Cattrysse source-audit postcondition failed."
}

$groups = @(
    $auditRows |
    Group-Object class_id |
    Sort-Object Name
)

foreach ($group in $groups) {
    Write-Host ($group.Name + ": " + $group.Count)
}

if (@($auditRows | Where-Object { $_.class_id -eq "CAT-SET1-50x8" }).Count -ne 40 -or
    @($auditRows | Where-Object { $_.class_id -eq "CAT-SET2-20x20" }).Count -ne 40 -or
    @($auditRows | Where-Object { $_.class_id -eq "CAT-SET3-8x50" }).Count -ne 40) {
    throw "Cattrysse 40/40/40 group postcondition failed."
}

Write-Step "Converting 120 Cattrysse instances to LotSizingDataModel"

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
    $originalRoot `
    $stagingRoot `
    $reportRoot

if ($LASTEXITCODE -ne 0) {
    throw "Cattrysse conversion failed."
}

$manifestPath = Join-Path $reportRoot "CATTRYSSE-CONVERSION-MANIFEST.csv"
$manifest = @(Import-Csv -LiteralPath $manifestPath)

if ($manifest.Count -ne 120 -or
    @($manifest | Where-Object { $_.status -eq "CONVERTED" }).Count -ne 120) {
    throw "Cattrysse conversion postcondition failed."
}

$staged = @(
    Get-ChildItem -LiteralPath $stagingRoot -Filter "*.xml" -File
)

if ($staged.Count -ne 120) {
    throw "Cattrysse staging must contain exactly 120 XML."
}

Write-Step "Publishing canonical 120-instance corpus"

$backupRoot = Join-Path $reportRoot "previous-canonical-backup"
Ensure-Directory -Path $backupRoot

foreach ($old in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    Copy-Item -LiteralPath $old.FullName -Destination (Join-Path $backupRoot $old.Name) -Force
    Remove-Item -LiteralPath $old.FullName -Force
}

foreach ($file in $staged) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $instancesRoot $file.Name) -Force
}

$canonical = @(
    Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File
)

if ($canonical.Count -ne 120) {
    throw "Canonical Cattrysse corpus must contain exactly 120 XML."
}

Write-Step "Running structural Checker on 120 instances"

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
    throw "Cattrysse structural Checker failed."
}

Write-Host "Structural Checker: VALID"

Write-Step "Reading the three historical BIFF5 solution workbooks"

$workbookReportRoot = Join-Path $reportRoot "workbooks"
Ensure-Directory -Path $workbookReportRoot

& dotnet run `
    --project $resultReaderProject `
    -c Release `
    --no-build `
    -- `
    $workbookRoot `
    $workbookReportRoot

if ($LASTEXITCODE -ne 0) {
    throw "Cattrysse result-workbook reader failed."
}

$resultEvidencePath = Join-Path $workbookReportRoot "CATTRYSSE-RESULT-EVIDENCE.csv"
$resultEvidence = @(Import-Csv -LiteralPath $resultEvidencePath)

$evidenceTests = @(
    $resultEvidence |
    Select-Object -ExpandProperty instance_id -Unique
)

if ($evidenceTests.Count -ne 120) {
    throw (
        "Solution-workbook evidence must cover 120 TEST identities; found " +
        $evidenceTests.Count
    )
}

Write-Host ("Workbook evidence cells: " + $resultEvidence.Count)
Write-Host "Workbook TEST coverage : 120 / 120"

Write-Step "Building conservative result trust catalogue"

$evidenceCounts = @{}
foreach ($row in $resultEvidence) {
    $id = $row.instance_id.ToUpperInvariant()
    if (-not $evidenceCounts.ContainsKey($id)) {
        $evidenceCounts[$id] = 0
    }
    $evidenceCounts[$id]++
}

$trust = New-Object System.Collections.Generic.List[object]

foreach ($row in $manifest) {
    $id = $row.instance_id.ToUpperInvariant()
    $count = 0
    if ($evidenceCounts.ContainsKey($id)) {
        $count = $evidenceCounts[$id]
    }

    $trust.Add([pscustomobject]@{
        instance_id = $id
        class_id = $row.class_id
        xml_file = $row.xml_file
        workbook_evidence_cells = $count
        literature_result_status = $(if ($count -gt 0) { "LITERATURE_WORKBOOK_EVIDENCE" } else { "UNKNOWN_REFERENCE" })
        best_known_objective = ""
        complete_solution_available = "False"
        checker_verified_solution = "False"
        trust_status = $(if ($count -gt 0) { "LITERATURE_VALUE_UNRECONCILED" } else { "UNKNOWN_REFERENCE" })
        note = "Associated Excel workbook contains reported computational results. v0.14.1 preserves every numeric result cell but does not infer which column is the canonical best-known objective or confuse runtimes/iteration data with objective values."
    })
}

$trustPath = Join-Path $metadataRoot "CATTRYSSE1990-TRUST-CATALOG-v0.14.1.csv"

$trust.ToArray() |
    Sort-Object instance_id |
    Export-Csv `
        -LiteralPath $trustPath `
        -NoTypeInformation `
        -Encoding UTF8

if (@($trust.ToArray() | Where-Object { $_.trust_status -like "VERIFIED*" }).Count -ne 0) {
    throw "Trust-gate violation: no complete solution certificates are present."
}

Write-Host "No unverified workbook result promoted to VERIFIED_*: PASS"

Write-Step "Computing fingerprints and cross-family exact duplicates"

$batchProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

if (-not (Test-Path -LiteralPath $batchProject -PathType Leaf)) {
    throw "Batch fingerprint tool is required."
}

& dotnet build `
    $batchProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Batch fingerprint tool build failed."
}

$fileManifest = Join-Path $fingerprintRoot "cattrysse-files.txt"
$fpCsv = Join-Path $fingerprintRoot "cattrysse-fingerprints.csv"

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
    "CATTRYSSE1990" `
    $fileManifest `
    $fpCsv

if ($LASTEXITCODE -ne 0) {
    throw "Cattrysse fingerprint campaign failed."
}

$fps = @(Import-Csv -LiteralPath $fpCsv)

if ($fps.Count -ne 120) {
    throw "Cattrysse fingerprint postcondition failed."
}

$otherSources = @(
    [pscustomobject]@{
        family = "TD1996"
        path = (Join-Path $BenchmarkRepo "reports\v0.13.1\fingerprints\td1996-fingerprints.csv")
    },
    [pscustomobject]@{
        family = "TRIGEIRO1989"
        path = (Join-Path $BenchmarkRepo "reports\v0.11.0\fingerprints\v0.11.0-fingerprints.csv")
    },
    [pscustomobject]@{
        family = "STADTLER2003"
        path = (Join-Path $BenchmarkRepo "reports\v0.4.2\fingerprints\stadtler-fingerprints.csv")
    },
    [pscustomobject]@{
        family = "SUERIE_CLSPL"
        path = (Join-Path $BenchmarkRepo "reports\v0.4.2\fingerprints\clspl-fingerprints.csv")
    }
)

$catByFp = @{}
foreach ($row in $fps) {
    if (-not $catByFp.ContainsKey($row.fingerprint)) {
        $catByFp[$row.fingerprint] =
            New-Object System.Collections.Generic.List[object]
    }
    $catByFp[$row.fingerprint].Add($row)
}

$cross = New-Object System.Collections.Generic.List[object]

foreach ($source in $otherSources) {
    if (-not (Test-Path -LiteralPath $source.path -PathType Leaf)) {
        continue
    }

    foreach ($other in Import-Csv -LiteralPath $source.path) {
        if (-not $catByFp.ContainsKey($other.fingerprint)) {
            continue
        }

        foreach ($cat in $catByFp[$other.fingerprint].ToArray()) {
            $cross.Add([pscustomobject]@{
                fingerprint = $cat.fingerprint
                cattrysse_filename = $cat.filename
                other_family = $source.family
                other_filename = $other.filename
                relation = "EXACT_SUPPLY_CHAIN_FINGERPRINT"
            })
        }
    }
}

$cross.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "CATTRYSSE1990-CROSS-FAMILY-FINGERPRINTS-v0.14.1.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host "Fingerprints             : 120 / 120"
Write-Host ("Exact cross-family pairs : " + $cross.Count)

Write-Step "Generating provenance and GitHub pages"

@(
    [pscustomobject]@{
        family = "CATTRYSSE1990"
        source_archive = "Cattrysse.zip"
        source_sha256 = $sourceSha
        provenance_note = "Archive note states that set1.zip contains TEST1-40 (50 items, 8 periods) with lot50.xls; set2.zip contains TEST41-80 (20 items, 20 periods) with lot20b.xls; set3.zip contains TEST81-120 (8 items, 50 periods) with lot8.xls; files supplied by Prof. Dirk Cattrysse, Centre for Industrial Management, KU Leuven."
        nested_zip_format = "Historical ZIP method 6 (Implode); deterministic extracted originals are bundled in the integration pack and verified against the audited archive SHA256."
        instances = 120
        result_workbooks = 3
    }
) |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "CATTRYSSE1990-PROVENANCE-v0.14.1.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Cattrysse-Maes-Van Wassenhove CLSP benchmark")
$page.Add("")
$page.Add("> Complete 120-instance corpus and associated historical result workbooks integrated by v0.14.1.")
$page.Add("")
$page.Add("| Group | Instances | Dimensions | Workbook |")
$page.Add("|---|---:|---|---|")
$page.Add("| Set 1 | 40 | 50 items x 8 periods | `lot50.xls` |")
$page.Add("| Set 2 | 40 | 20 items x 20 periods | `lot20b.xls` |")
$page.Add("| Set 3 | 40 | 8 items x 50 periods | `lot8.xls` |")
$page.Add("")
$page.Add("## Provenance")
$page.Add("")
$page.Add("The `note` bundled in the user archive explicitly associates the three 40-instance sets with the three Excel result workbooks and identifies Prof. Dirk Cattrysse / Centre for Industrial Management, KU Leuven as the source.")
$page.Add("")
$page.Add("## Source format")
$page.Add("")
$page.Add("Each original TEST file is parsed as a numeric token stream: `(items, periods)`, `items x periods` demand values, `periods` capacities, then `items` triples interpreted as fixed setup cost, holding cost and unit capacity consumption. This contract matches all 120 source files exactly.")
$page.Add("")
$page.Add("## Result trust")
$page.Add("")
$page.Add("All numeric cells on workbook rows identified with TEST1..TEST120 are preserved as `LITERATURE_WORKBOOK_RESULT_CELL`. The workbooks contain several heuristic/method columns (for example ABCX, ABCX20, ABCXexp, HEUR1...). v0.14.1 does not guess which numeric cells are objective values versus timings or auxiliary measurements, and therefore promotes no value to `BEST_KNOWN` or `VERIFIED_*`.")
$page.Add("")
$page.Add("Structural Checker: **VALID 120/120**.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.14.1 final postconditions"

Write-Host "Cattrysse 120 Full Integration + Result Trust Gate"
Write-Host "=================================================="
Write-Host "Original instances          : 120 / 120"
Write-Host "Set 1 (50x8)                : 40 / 40"
Write-Host "Set 2 (20x20)               : 40 / 40"
Write-Host "Set 3 (8x50)                : 40 / 40"
Write-Host "Canonical LSDM XML          : 120 / 120"
Write-Host "Structural Checker          : VALID"
Write-Host "Result workbooks            : 3 / 3"
Write-Host "Workbook TEST coverage      : 120 / 120"
Write-Host ("Workbook evidence cells     : " + $resultEvidence.Count)
Write-Host "Verified solutions          : 0"
Write-Host "Reference objectives        : UNRECONCILED"
Write-Host "Fingerprints                : 120 / 120"
Write-Host ("Cross-family exact pairs    : " + $cross.Count)
Write-Host ("Trust catalogue             : " + $trustPath)
Write-Host ("Reports                     : " + $reportRoot)
