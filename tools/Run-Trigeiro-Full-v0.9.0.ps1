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

function Get-TextSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Import-CsvSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    return @(Import-Csv -LiteralPath $Path)
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989"
$rawRoot = Join-Path $familyRoot "raw"
$materializedRoot = Join-Path $rawRoot "materialized"
$instancesRoot = Join-Path $familyRoot "instances"
$metadataRoot = Join-Path $familyRoot "metadata"
$checkerRoot = Join-Path $familyRoot "checker-reports\v0.9.0"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.9.0"
$fingerprintRoot = Join-Path $reportRoot "fingerprints"
$catalogRoot = Join-Path $BenchmarkRepo "catalog"

foreach ($path in @(
    $familyRoot,
    $rawRoot,
    $materializedRoot,
    $instancesRoot,
    $metadataRoot,
    $checkerRoot,
    $reportRoot,
    $fingerprintRoot,
    $catalogRoot
)) {
    Ensure-Directory -Path $path
}

Write-Step "Preflight: preserving established benchmark invariants"

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
    throw "Stadtler invariant failed: total is not 2100."
}

$clsplCatalogue = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)

if ($clsplRows.Count -ne 1281) {
    throw "CLSPL invariant failed: literature mapping is not 1281/1281."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL: 1281 / 1281"

Write-Step "Locating immutable Trigeiro raw files acquired by v0.8.0"

$rawFiles = @(
    Get-ChildItem `
        -LiteralPath $materializedRoot `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Extension -match "(?i)^\.(dat|txt)$"
    } |
    Sort-Object FullName
)

if ($rawFiles.Count -eq 0) {
    throw (
        "No Trigeiro raw .DAT/.TXT files were found under " +
        $materializedRoot +
        ". Run v0.8.0 acquisition first."
    )
}

Write-Host ("Raw candidate files: " + $rawFiles.Count)

$inventory = New-Object System.Collections.Generic.List[object]
$hashGroups = @{}

foreach ($file in $rawFiles) {
    $sha = Get-TextSha256 -Path $file.FullName

    if (-not $hashGroups.ContainsKey($sha)) {
        $hashGroups[$sha] =
            New-Object System.Collections.Generic.List[string]
    }

    $hashGroups[$sha].Add($file.FullName)

    $preview = ""
    try {
        $preview = @(
            Get-Content -LiteralPath $file.FullName -TotalCount 5 -ErrorAction Stop
        ) -join " || "
    }
    catch {
    }

    $inventory.Add([pscustomobject]@{
        source_path = $file.FullName
        source_file = $file.Name
        extension = $file.Extension
        length = $file.Length
        sha256 = $sha
        preview = [regex]::Replace($preview,"[^\x20-\x7E\t]","?")
    })
}

$inventory.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-RAW-INVENTORY-v0.9.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$uniqueRawCount = $hashGroups.Keys.Count
Write-Host ("Unique raw contents by SHA256: " + $uniqueRawCount)

Write-Step "Checking public-source reader evidence captured by v0.9.0"

$evidence = @(
    [pscustomobject]@{
        evidence_id = "TRI-FORMAT-READER-001"
        source = "gsamaro/trigeiro_fdata read_file.py"
        status = "FORMAT_CONTRACT_EVIDENCE"
        assertion = "First row contains item and period counts; numeric row 3 contains scalar capacity; next n rows contain unit production time, holding cost, setup time and setup cost; demand follows period-major."
        verified = "False"
        note = "Evidence is used to reconstruct the parser contract, not a best-known objective."
    },
    [pscustomobject]@{
        evidence_id = "TRI-PAPER-1989"
        source = "Trigeiro, Thomas and McClain (1989), Management Science 35(3):353-366"
        status = "BIBLIOGRAPHIC_SOURCE"
        assertion = "Capacitated lot sizing with setup times benchmark family."
        verified = "False"
        note = "No instance-level BKV is promoted from this citation alone."
    }
)

$evidence |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-SOURCE-EVIDENCE-v0.9.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Raw corpus, invariant checks and evidence prerequisites are ready."
    exit 0
}

Write-Step "Installing and building dedicated Trigeiro importer"

$toolProject = Join-Path $BenchmarkRepo `
    "tools\TrigeiroImporter\TrigeiroImporter.csproj"

if (-not (Test-Path -LiteralPath $toolProject -PathType Leaf)) {
    throw ("TrigeiroImporter project missing: " + $toolProject)
}

& dotnet build `
    $toolProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TrigeiroImporter build failed."
}

Write-Step "Converting complete acquired Trigeiro corpus to LotSizingDataModel"

$stagingRoot = Join-Path $reportRoot "conversion-staging"
if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
Ensure-Directory -Path $stagingRoot

$manifest = Join-Path $reportRoot "TRIGEIRO-CONVERSION-MANIFEST.csv"

& dotnet run `
    --project $toolProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    $materializedRoot `
    $stagingRoot `
    $manifest

$importExit = $LASTEXITCODE

if ($importExit -ne 0) {
    throw ("TrigeiroImporter failed with exit code " + $importExit)
}

$conversionRows = @(Import-Csv -LiteralPath $manifest)
$convertedRows = @(
    $conversionRows |
    Where-Object { $_.status -eq "CONVERTED" }
)

$rejectedRows = @(
    $conversionRows |
    Where-Object { $_.status -like "REJECTED*" }
)

$duplicateRows = @(
    $conversionRows |
    Where-Object { $_.status -eq "DUPLICATE_SOURCE_CONTENT" }
)

Write-Host ("Converted raw instances: " + $convertedRows.Count)
Write-Host ("Rejected non-contract/failures: " + $rejectedRows.Count)
Write-Host ("Duplicate raw contents: " + $duplicateRows.Count)

if ($convertedRows.Count -eq 0) {
    throw "No Trigeiro instance was converted; refusing to publish an empty family."
}

Write-Step "Promoting canonical XML idempotently"

$existingByName = @{}
$existingByHash = @{}

foreach ($file in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    $existingByName[$file.Name.ToLowerInvariant()] = $file.FullName
    $existingByHash[(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash] = $file.FullName
}

$promoted = New-Object System.Collections.Generic.List[object]

foreach ($file in Get-ChildItem -LiteralPath $stagingRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $nameKey = $file.Name.ToLowerInvariant()

    if ($existingByHash.ContainsKey($hash)) {
        $promoted.Add([pscustomobject]@{
            source = $file.FullName
            destination = $existingByHash[$hash]
            status = "ALREADY_PRESENT_SAME_XML_HASH"
            xml_sha256 = $hash
        })
        continue
    }

    $destination = Join-Path $instancesRoot $file.Name

    if ($existingByName.ContainsKey($nameKey)) {
        $oldHash = (
            Get-FileHash `
                -LiteralPath $existingByName[$nameKey] `
                -Algorithm SHA256
        ).Hash

        if ($oldHash -ne $hash) {
            throw (
                "Idempotence conflict: canonical filename exists with different content: " +
                $file.Name
            )
        }
    }
    else {
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }

    $promoted.Add([pscustomobject]@{
        source = $file.FullName
        destination = $destination
        status = "PROMOTED"
        xml_sha256 = $hash
    })
}

$promoted.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-PROMOTION-v0.9.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$canonicalXml = @(
    Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
)

Write-Host ("Canonical Trigeiro XML: " + $canonicalXml.Count)

Write-Step "Running structural Checker on full Trigeiro corpus"

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
    throw ("Trigeiro structural checker failed with exit code " + $checkerExit)
}

Write-Host "Structural Checker: PASS"

Write-Step "Building instance reference catalogue"

$referenceCatalogue = New-Object System.Collections.Generic.List[object]

foreach ($row in $convertedRows) {
    $instanceId = [IO.Path]::GetFileNameWithoutExtension($row.output_file)

    $referenceCatalogue.Add([pscustomobject]@{
        source_instance = [IO.Path]::GetFileNameWithoutExtension($row.source_file).ToUpperInvariant()
        lsdm_filename = $row.output_file
        items = $row.items
        periods = $row.periods
        capacity = $row.capacity
        literature_value = ""
        lower_bound = ""
        best_known = ""
        status = "UNKNOWN_REFERENCE"
        verification = "NOT_VERIFIED"
        complete_solution_available = "False"
        source = "Trigeiro raw dataset only"
        note = "No objective value is promoted without instance-level published or checker-verified evidence."
    })
}

$referenceCatalogue.ToArray() |
    Sort-Object source_instance |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-REFERENCE-CATALOG-v0.9.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Scanning acquired repository for result/BKV evidence"

$resultFiles = @(
    Get-ChildItem `
        -LiteralPath $materializedRoot `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "(?i)(best|bound|result|solution|objective|opt|bkv|readme)"
    }
)

$resultEvidence = New-Object System.Collections.Generic.List[object]

foreach ($file in $resultFiles) {
    $preview = ""

    if ($file.Length -le 200000) {
        try {
            $preview = @(
                Get-Content -LiteralPath $file.FullName -TotalCount 30 -ErrorAction Stop
            ) -join " || "
        }
        catch {
        }
    }

    $resultEvidence.Add([pscustomobject]@{
        path = $file.FullName
        file_name = $file.Name
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        evidence_status = "UNRECONCILED_RESULT_SOURCE"
        preview = [regex]::Replace($preview,"[^\x20-\x7E\t]","?")
    })
}

$resultEvidence.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-RESULT-EVIDENCE-v0.9.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Potential local result/BKV evidence files: " + $resultEvidence.Count)

Write-Step "Computing canonical fingerprints in batch"

$batchProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

if (-not (Test-Path -LiteralPath $batchProject -PathType Leaf)) {
    throw (
        "Batch fingerprint tool is missing. Expected from v0.4.2: " +
        $batchProject
    )
}

$trigeiroManifest = Join-Path $fingerprintRoot "trigeiro-files.txt"

[IO.File]::WriteAllLines(
    $trigeiroManifest,
    @($canonicalXml | ForEach-Object { $_.FullName }),
    (New-Object Text.UTF8Encoding($false))
)

& dotnet build `
    $batchProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Batch fingerprint tool build failed."
}

$trigeiroFpCsv = Join-Path $fingerprintRoot "trigeiro-fingerprints.csv"

& dotnet run `
    --project $batchProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    "TRIGEIRO1989" `
    $trigeiroManifest `
    $trigeiroFpCsv

if ($LASTEXITCODE -ne 0) {
    throw "Trigeiro batch fingerprint failed."
}

$trigeiroFp = @(Import-Csv -LiteralPath $trigeiroFpCsv)

if ($trigeiroFp.Count -ne $canonicalXml.Count) {
    throw "Trigeiro fingerprint postcondition failed."
}

Write-Step "Cross-family duplicate search"

$otherFingerprintCsvs = @(
    [pscustomobject]@{
        family = "STADTLER2003"
        path = (Join-Path $BenchmarkRepo "reports\v0.4.2\fingerprints\stadtler-fingerprints.csv")
    },
    [pscustomobject]@{
        family = "SUERIE_CLSPL"
        path = (Join-Path $BenchmarkRepo "reports\v0.4.2\fingerprints\clspl-fingerprints.csv")
    }
)

$crosswalk = New-Object System.Collections.Generic.List[object]

$triByFp = @{}

foreach ($row in $trigeiroFp) {
    if (-not $triByFp.ContainsKey($row.fingerprint)) {
        $triByFp[$row.fingerprint] =
            New-Object System.Collections.Generic.List[object]
    }

    $triByFp[$row.fingerprint].Add($row)
}

foreach ($source in $otherFingerprintCsvs) {
    if (-not (Test-Path -LiteralPath $source.path -PathType Leaf)) {
        continue
    }

    foreach ($other in Import-Csv -LiteralPath $source.path) {
        if (-not $triByFp.ContainsKey($other.fingerprint)) {
            continue
        }

        foreach ($tri in $triByFp[$other.fingerprint].ToArray()) {
            $crosswalk.Add([pscustomobject]@{
                fingerprint = $other.fingerprint
                trigeiro_filename = $tri.filename
                other_family = $source.family
                other_filename = $other.filename
                relation = "EXACT_SUPPLY_CHAIN_FINGERPRINT"
            })
        }
    }
}

$crosswalk.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "TRIGEIRO1989-CROSS-FAMILY-DUPLICATES-v0.9.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Exact cross-family fingerprint pairs: " + $crosswalk.Count)

Write-Step "Generating family GitHub page and open challenges"

$bySize = @(
    $convertedRows |
    Group-Object items,periods |
    Sort-Object Name
)

$page = New-Object System.Collections.Generic.List[string]

$page.Add("# Trigeiro et al. 1989 CLSP benchmark")
$page.Add("")
$page.Add("> LotSizingDataModel full integration v0.9.0.")
$page.Add("")
$page.Add("| Metric | Count |")
$page.Add("|---|---:|")
$page.Add("| Raw candidate files | **" + $rawFiles.Count + "** |")
$page.Add("| Unique raw SHA-256 contents | **" + $uniqueRawCount + "** |")
$page.Add("| Successfully converted instances | **" + $convertedRows.Count + "** |")
$page.Add("| Canonical LotSizingDataModel XML | **" + $canonicalXml.Count + "** |")
$page.Add("| Structural Checker failures | **0** |")
$page.Add("| Exact cross-family duplicates | **" + $crosswalk.Count + "** |")
$page.Add("| Instance-level verified BKV | **0 unless separately evidenced** |")
$page.Add("")
$page.Add("## Source contract")
$page.Add("")
$page.Add("The importer implements the contract documented by the public `gsamaro/trigeiro_fdata` reader: item count, period count, scalar machine capacity, per-item production time, holding cost, setup time, setup cost, followed by period-major demand.")
$page.Add("")
$page.Add("For instances with more than 15 items, the historical demand matrix is reconstructed from the two horizontal period blocks documented by the public reader.")
$page.Add("")
$page.Add("## Corpus composition")
$page.Add("")
$page.Add("| Items / periods | Converted |")
$page.Add("|---|---:|")

foreach ($group in $bySize) {
    $example = $group.Group[0]
    $page.Add(
        "| " +
        $example.items +
        " / " +
        $example.periods +
        " | " +
        $group.Count +
        " |"
    )
}

$page.Add("")
$page.Add("## Reference-value trust model")
$page.Add("")
$page.Add("- `LITERATURE_VALUE`: published value not yet independently verified.")
$page.Add("- `BEST_KNOWN`: current strongest reconciled upper bound.")
$page.Add("- `VERIFIED_FEASIBLE`: complete solution passed through LotSizingDataModel.Checker.")
$page.Add("- `VERIFIED_PROVEN_OPTIMAL`: checked complete solution plus an accepted optimality proof/reference.")
$page.Add("- `REJECTED`: claim or solution rejected by the trust gate.")
$page.Add("")
$page.Add("No objective is promoted merely because a number appears in a paper or auxiliary file.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

$open = New-Object System.Collections.Generic.List[string]
$open.Add("# Trigeiro 1989 open challenges")
$open.Add("")
$open.Add("The raw corpus is converted and structurally checked. The remaining reference challenge is instance-level reconciliation of published upper/lower bounds and complete solution certificates.")
$open.Add("")
$open.Add("| Instance | Status |")
$open.Add("|---|---|")

foreach ($row in ($referenceCatalogue.ToArray() | Sort-Object source_instance)) {
    $open.Add(
        "| " +
        $row.source_instance +
        " | " +
        $row.status +
        " |"
    )
}

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "OPEN-CHALLENGES.md"),
    $open.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "Updating global benchmark catalogue"

$globalRow = [pscustomobject]@{
    family = "TRIGEIRO1989"
    problem = "single-level multi-item capacitated lot sizing with setup times"
    raw_files = $rawFiles.Count
    canonical_instances = $canonicalXml.Count
    checker_status = "VALID"
    reference_values = "INSTANCE_LEVEL_UNRECONCILED"
    source = "gsamaro/trigeiro_fdata public repository; Trigeiro et al. 1989"
    integration_version = "v0.9.0"
}

$globalPath = Join-Path $catalogRoot "benchmark-families-v0.9.0.csv"

@($globalRow) |
    Export-Csv `
        -LiteralPath $globalPath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "v0.9.0 final postconditions"

$finalXmlCount = @(
    Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File
).Count

if ($finalXmlCount -ne $convertedRows.Count) {
    Write-Warning (
        "Canonical XML count differs from this-run converted raw count. " +
        "This is acceptable only when prior idempotent XML already existed."
    )
}

if ($checkerExit -ne 0) {
    throw "Final Checker postcondition failed."
}

Write-Host "Trigeiro 1989 Full Integration"
Write-Host "==============================="
Write-Host ("Raw candidate files        : " + $rawFiles.Count)
Write-Host ("Unique raw contents        : " + $uniqueRawCount)
Write-Host ("Converted instances        : " + $convertedRows.Count)
Write-Host ("Canonical LSDM XML         : " + $finalXmlCount)
Write-Host ("Rejected source files      : " + $rejectedRows.Count)
Write-Host ("Duplicate source files     : " + $duplicateRows.Count)
Write-Host ("Structural Checker         : VALID")
Write-Host ("Fingerprinted XML          : " + $trigeiroFp.Count)
Write-Host ("Cross-family exact pairs   : " + $crosswalk.Count)
Write-Host ("Local result evidence files: " + $resultEvidence.Count)
Write-Host ("Instance BKV status        : UNRECONCILED / no invented values")
Write-Host ("Reports                    : " + $reportRoot)
