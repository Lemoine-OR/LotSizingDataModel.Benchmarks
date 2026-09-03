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
$rawRoot = Join-Path $familyRoot "raw"
$originalsRoot = Join-Path $rawRoot "originals"
$derivedRoot = Join-Path $rawRoot "derived"
$archiveRoot = Join-Path $rawRoot "user-E1\upstream"
$instancesRoot = Join-Path $familyRoot "instances"
$metadataRoot = Join-Path $familyRoot "metadata"
$validationRoot = Join-Path $familyRoot "validation"
$checkerRoot = Join-Path $familyRoot "checker-reports\v0.11.0"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.11.0"
$fingerprintRoot = Join-Path $reportRoot "fingerprints"
$oldBackup = Join-Path $reportRoot "v0.10.0-canonical-before-authoritative-rebuild"
$stagingRoot = Join-Path $reportRoot "authoritative-staging"

foreach ($path in @(
    $originalsRoot,
    $derivedRoot,
    $archiveRoot,
    $instancesRoot,
    $metadataRoot,
    $validationRoot,
    $checkerRoot,
    $reportRoot,
    $fingerprintRoot,
    $oldBackup,
    $stagingRoot
)) {
    Ensure-Directory -Path $path
}

Write-Step "Preflight: corpus and benchmark invariants"

if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw "D:\temp\E1.zip is required."
}

$existingXml = @(
    Get-ChildItem `
        -LiteralPath $instancesRoot `
        -Filter "*.xml" `
        -File `
        -ErrorAction SilentlyContinue
)

if ($existingXml.Count -ne 751) {
    throw (
        "Expected the validated v0.10.0 751-instance canonical corpus before authoritative rebuild; found " +
        $existingXml.Count
    )
}

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
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

$clsplCatalogue = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

if (@(Import-Csv -LiteralPath $clsplCatalogue).Count -ne 1281) {
    throw "CLSPL invariant failed."
}

Write-Host "Existing Trigeiro v0.10.0 XML: 751 / 751"
Write-Host "Stadtler                    : 2100 / 2100"
Write-Host "CLSPL                       : 1281 / 1281"

Write-Step "Validating authoritative archive cardinality"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($sourceArchive)

try {
    $trigCount = @(
        $zip.Entries |
        Where-Object { $_.FullName -match "(?i)\.trig$" }
    ).Count

    $datCount = @(
        $zip.Entries |
        Where-Object { $_.FullName -match "(?i)\.dat$" }
    ).Count
}
finally {
    $zip.Dispose()
}

Write-Host ("TRIG originals: " + $trigCount)
Write-Host ("DAT derived   : " + $datCount)

if ($trigCount -ne 751 -or $datCount -ne 751) {
    throw "E1.zip must contain 751 TRIG originals and 751 DAT derived files."
}

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Authoritative TRIG consolidation prerequisites are valid."
    exit 0
}

Write-Step "Preserving original archive and materializing provenance hierarchy"

$sourceSha = (
    Get-FileHash `
        -LiteralPath $sourceArchive `
        -Algorithm SHA256
).Hash

$repoArchive = Join-Path $archiveRoot "E1.zip"

if (Test-Path -LiteralPath $repoArchive -PathType Leaf) {
    $repoSha = (
        Get-FileHash `
            -LiteralPath $repoArchive `
            -Algorithm SHA256
    ).Hash

    if ($repoSha -ne $sourceSha) {
        throw "Immutable E1.zip provenance conflict."
    }
}
else {
    Copy-Item `
        -LiteralPath $sourceArchive `
        -Destination $repoArchive `
        -Force
}

$tempExtract = Join-Path $reportRoot "_source-extract"

if (Test-Path -LiteralPath $tempExtract) {
    Remove-Item `
        -LiteralPath $tempExtract `
        -Recurse `
        -Force
}

Ensure-Directory -Path $tempExtract

Expand-Archive `
    -LiteralPath $repoArchive `
    -DestinationPath $tempExtract `
    -Force

foreach ($dir in @($originalsRoot,$derivedRoot)) {
    foreach ($file in Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
}

foreach ($file in Get-ChildItem -LiteralPath $tempExtract -Filter "*.trig" -File -Recurse) {
    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination (Join-Path $originalsRoot $file.Name) `
        -Force
}

foreach ($file in Get-ChildItem -LiteralPath $tempExtract -Filter "*.dat" -File -Recurse) {
    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination (Join-Path $derivedRoot $file.Name) `
        -Force
}

$originalFiles = @(
    Get-ChildItem -LiteralPath $originalsRoot -Filter "*.trig" -File
)

$derivedFiles = @(
    Get-ChildItem -LiteralPath $derivedRoot -Filter "*.dat" -File
)

if ($originalFiles.Count -ne 751 -or $derivedFiles.Count -ne 751) {
    throw "Materialized provenance hierarchy cardinality failed."
}

Write-Host "originals/: 751 TRIG"
Write-Host "derived/  : 751 DAT"

Write-Step "Writing source-role provenance catalogue"

$roles = New-Object System.Collections.Generic.List[object]

foreach ($file in $originalFiles) {
    $roles.Add([pscustomobject]@{
        instance_id = $file.BaseName
        role = "ORIGINAL_SOURCE"
        authority = "AUTHORITATIVE"
        format = "TRIG"
        path = $file.FullName
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    })
}

foreach ($file in $derivedFiles) {
    $roles.Add([pscustomobject]@{
        instance_id = $file.BaseName
        role = "DERIVED_SECONDARY_FORMAT"
        authority = "VALIDATION_ONLY"
        format = "DAT"
        path = $file.FullName
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    })
}

$roles.ToArray() |
    Sort-Object instance_id,format |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-SOURCE-ROLES-v0.11.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Backing up v0.10.0 canonical XML before authoritative rebuild"

foreach ($file in Get-ChildItem -LiteralPath $oldBackup -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    Remove-Item -LiteralPath $file.FullName -Force
}

foreach ($file in $existingXml) {
    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination (Join-Path $oldBackup $file.Name) `
        -Force
}

Write-Step "Building authoritative TRIG-only importer"

$importerProject = Join-Path $BenchmarkRepo `
    "tools\TrigeiroAuthoritativeImporter\TrigeiroAuthoritativeImporter.csproj"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TrigeiroAuthoritativeImporter build failed."
}

Write-Step "Rebuilding 751 canonical instances exclusively from original TRIG"

if (Test-Path -LiteralPath $stagingRoot) {
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
    $originalsRoot `
    $derivedRoot `
    $stagingRoot `
    $validationRoot

if ($LASTEXITCODE -ne 0) {
    throw "Authoritative TRIG rebuild failed."
}

$validationPath = Join-Path $validationRoot `
    "TRIGEIRO-AUTHORITATIVE-VALIDATION.csv"

$validation = @(
    Import-Csv -LiteralPath $validationPath
)

$originalRejected = @(
    $validation |
    Where-Object { $_.canonical_source -eq "ORIGINAL_TRIG_REJECTED" }
)

if ($validation.Count -ne 751 -or $originalRejected.Count -ne 0) {
    throw (
        "Authoritative importer postcondition failed: rows=" +
        $validation.Count +
        " rejected originals=" +
        $originalRejected.Count
    )
}

$derivedKnownLoss = @(
    $validation |
    Where-Object { $_.derived_status -eq "DERIVED_DAT_KNOWN_SETUP_TIME_LOSS" }
)

$derivedValidated = @(
    $validation |
    Where-Object { $_.derived_status -eq "DERIVED_DAT_VALIDATED" }
)

$derivedOtherMismatch = @(
    $validation |
    Where-Object { $_.derived_status -eq "DERIVED_DAT_OTHER_MISMATCH" }
)

$derivedSetupMismatch = @(
    $validation |
    Where-Object { $_.derived_status -eq "DERIVED_DAT_SETUP_TIME_MISMATCH" }
)

Write-Host ("DAT fully validated           : " + $derivedValidated.Count)
Write-Host ("DAT known setup-time loss     : " + $derivedKnownLoss.Count)
Write-Host ("DAT other shared-field mismatch: " + $derivedOtherMismatch.Count)
Write-Host ("DAT other setup-time mismatch : " + $derivedSetupMismatch.Count)

Write-Step "Comparing v0.10.0 and v0.11.0 semantic fingerprints"

$batchProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

if (-not (Test-Path -LiteralPath $batchProject -PathType Leaf)) {
    throw "Batch fingerprint tool required for authoritative semantic migration."
}

& dotnet build `
    $batchProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Batch fingerprint tool build failed."
}

$oldManifest = Join-Path $fingerprintRoot "v0.10.0-files.txt"
$newManifest = Join-Path $fingerprintRoot "v0.11.0-files.txt"
$oldFpCsv = Join-Path $fingerprintRoot "v0.10.0-fingerprints.csv"
$newFpCsv = Join-Path $fingerprintRoot "v0.11.0-fingerprints.csv"

[IO.File]::WriteAllLines(
    $oldManifest,
    @(
        Get-ChildItem -LiteralPath $oldBackup -Filter "*.xml" -File |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
    ),
    (New-Object Text.UTF8Encoding($false))
)

[IO.File]::WriteAllLines(
    $newManifest,
    @(
        Get-ChildItem -LiteralPath $stagingRoot -Filter "*.xml" -File |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
    ),
    (New-Object Text.UTF8Encoding($false))
)

& dotnet run `
    --project $batchProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    "TRIGEIRO1989-V010" `
    $oldManifest `
    $oldFpCsv

if ($LASTEXITCODE -ne 0) {
    throw "v0.10.0 fingerprint comparison failed."
}

& dotnet run `
    --project $batchProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    "TRIGEIRO1989-V011" `
    $newManifest `
    $newFpCsv

if ($LASTEXITCODE -ne 0) {
    throw "v0.11.0 fingerprint comparison failed."
}

$oldFp = @(Import-Csv -LiteralPath $oldFpCsv)
$newFp = @(Import-Csv -LiteralPath $newFpCsv)

if ($oldFp.Count -ne 751 -or $newFp.Count -ne 751) {
    throw "Fingerprint migration cardinality failed."
}

$oldByName = @{}

foreach ($row in $oldFp) {
    $oldByName[$row.filename.ToLowerInvariant()] = $row
}

$migration = New-Object System.Collections.Generic.List[object]
$semanticChanges = 0

foreach ($row in $newFp) {
    $key = $row.filename.ToLowerInvariant()

    if (-not $oldByName.ContainsKey($key)) {
        $migration.Add([pscustomobject]@{
            filename = $row.filename
            old_fingerprint = ""
            new_fingerprint = $row.fingerprint
            semantic_status = "NEW_FILENAME"
        })
        $semanticChanges++
        continue
    }

    $old = $oldByName[$key]
    $same = ($old.fingerprint -eq $row.fingerprint)

    if (-not $same) {
        $semanticChanges++
    }

    $migration.Add([pscustomobject]@{
        filename = $row.filename
        old_fingerprint = $old.fingerprint
        new_fingerprint = $row.fingerprint
        semantic_status = $(if ($same) { "SEMANTICALLY_IDENTICAL" } else { "SEMANTIC_CHANGE" })
    })
}

$migration.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "TRIGEIRO-v0.10-to-v0.11-MIGRATION.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Semantic fingerprint changes: " + $semanticChanges)

Write-Step "Publishing authoritative canonical corpus"

foreach ($file in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File) {
    Remove-Item -LiteralPath $file.FullName -Force
}

foreach ($file in Get-ChildItem -LiteralPath $stagingRoot -Filter "*.xml" -File) {
    Copy-Item `
        -LiteralPath $file.FullName `
        -Destination (Join-Path $instancesRoot $file.Name) `
        -Force
}

$canonical = @(
    Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File
)

if ($canonical.Count -ne 751) {
    throw "Authoritative canonical corpus must contain exactly 751 XML."
}

Write-Step "Running structural Checker on authoritative 751-instance corpus"

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
    throw "Authoritative Trigeiro structural Checker failed."
}

Write-Host "Structural Checker: VALID"

Write-Step "Generating authoritative catalogues and GitHub pages"

$catalog = New-Object System.Collections.Generic.List[object]

foreach ($row in $validation) {
    $series = ""

    if ($row.instance_id -match "^(?<s>[A-Za-z]+)") {
        $series = $Matches["s"].ToUpperInvariant()
    }

    $catalog.Add([pscustomobject]@{
        instance_id = $row.instance_id
        series = $series
        canonical_source = "ORIGINAL_TRIG_AUTHORITATIVE"
        derived_dat_status = $row.derived_status
        shared_fields_valid = $row.shared_fields_valid
        trig_sha256 = $row.trig_sha256
        dat_sha256 = $row.dat_sha256
        xml_file = $row.xml_file
        xml_sha256 = $row.xml_sha256
        reference_status = "UNKNOWN_REFERENCE"
    })
}

$catalog.ToArray() |
    Sort-Object series,instance_id |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-CANONICAL-CATALOG-v0.11.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$seriesGroups = @(
    $catalog.ToArray() |
    Group-Object series |
    Sort-Object Name
)

$page = New-Object System.Collections.Generic.List[string]

$page.Add("# Trigeiro et al. 1989 benchmark")
$page.Add("")
$page.Add("> Authoritative original-source consolidation, v0.11.0.")
$page.Add("")
$page.Add("## Provenance rule")
$page.Add("")
$page.Add("- `.trig` = **ORIGINAL_SOURCE / AUTHORITATIVE**")
$page.Add("- `.dat` = **DERIVED_SECONDARY_FORMAT / VALIDATION_ONLY**")
$page.Add("- canonical LSDM XML are rebuilt exclusively from `.trig` parameters")
$page.Add("- fields present only in `.dat` are never injected into the canonical model without primary-source proof")
$page.Add("")
$page.Add("| Metric | Count |")
$page.Add("|---|---:|")
$page.Add("| Original TRIG files | **751** |")
$page.Add("| Derived DAT files | **751** |")
$page.Add("| Canonical LSDM XML | **751** |")
$page.Add("| Structural Checker invalid | **0** |")
$page.Add("| DAT known setup-time-loss | **" + $derivedKnownLoss.Count + "** |")
$page.Add("| DAT other shared-field mismatch | **" + $derivedOtherMismatch.Count + "** |")
$page.Add("| Semantic changes vs v0.10.0 | **" + $semanticChanges + "** |")
$page.Add("")
$page.Add("## Series")
$page.Add("")
$page.Add("| Series | Instances |")
$page.Add("|---|---:|")

foreach ($group in $seriesGroups) {
    $page.Add(
        "| " + $group.Name +
        " | **" + $group.Count + "** |"
    )
}

$page.Add("")
$page.Add("Reference objectives remain `UNKNOWN_REFERENCE` until the dedicated result trust gate reconciles instance-level literature or checker-verified complete solutions.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.11.0 final postconditions"

Write-Host "Trigeiro 1989 Authoritative Consolidation"
Write-Host "=========================================="
Write-Host "Original source format       : TRIG"
Write-Host "Original TRIG files          : 751"
Write-Host "Derived DAT files            : 751"
Write-Host ("DAT validated                : " + $derivedValidated.Count)
Write-Host ("DAT known setup-time loss    : " + $derivedKnownLoss.Count)
Write-Host ("DAT other shared mismatches  : " + $derivedOtherMismatch.Count)
Write-Host ("Semantic changes vs v0.10.0  : " + $semanticChanges)
Write-Host "Canonical LSDM XML           : 751"
Write-Host "Structural Checker           : VALID"
Write-Host "Reference values             : UNRECONCILED"
Write-Host ("Reports                      : " + $reportRoot)
