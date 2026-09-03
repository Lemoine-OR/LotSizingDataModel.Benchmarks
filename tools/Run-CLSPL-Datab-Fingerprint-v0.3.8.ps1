param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Normalize-Id {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    $v = $Value.ToLowerInvariant().Trim()
    $v = [regex]::Replace($v, "\.[a-z0-9]+$", "")
    $v = [regex]::Replace($v, "[^a-z0-9]", "")
    return $v
}

function Leaf-Numeric-Key {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    $leaf = $Value
    try {
        if ($Value.Contains("\") -or $Value.Contains("/")) {
            $leaf = Split-Path -Leaf $Value
        }
    } catch {}

    $numbers = @(
        [regex]::Matches($leaf, "\d+") |
        ForEach-Object { [int]$_.Value }
    )

    if ($numbers.Count -eq 0) { return "" }
    return ($numbers -join "-")
}

$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$rawRoot = Join-Path $clsRoot "raw\materialized"
$canonicalRoot = Join-Path $clsRoot "instances"
$metaRoot = Join-Path $clsRoot "metadata"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.3.8"
Ensure-Dir $reportRoot

$unmappedPath = Join-Path $metaRoot "CLSPL-LITERATURE-UNMAPPED.csv"
$mappedPath = Join-Path $metaRoot "CLSPL-LITERATURE-REFERENCES.csv"

if (-not (Test-Path -LiteralPath $unmappedPath -PathType Leaf)) {
    throw "Missing v0.3.6/v0.3.7 unmapped catalogue."
}

$databRefs = @(
    Import-Csv -LiteralPath $unmappedPath |
    Where-Object { $_.test_set -eq "datab" }
)

Write-Step "Locating the 60 raw datab source directories"

$rawDatab = New-Object System.Collections.Generic.List[object]

$indexes = @(
    Get-ChildItem -LiteralPath $rawRoot -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "(?i)datab" }
)

foreach ($idx in $indexes) {
    $dir = $idx.Directory.FullName
    $leaf = Split-Path -Leaf $dir

    $rawDatab.Add([pscustomobject]@{
        directory = $dir
        leaf = $leaf
        normalized_leaf = (Normalize-Id -Value $leaf)
        numeric_leaf_key = (Leaf-Numeric-Key -Value $leaf)
    })
}

Write-Host ("Raw datab directories: " + $rawDatab.Count)

$rawDatab |
    Export-Csv -LiteralPath (Join-Path $reportRoot "raw-datab-directory-identities.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Building official LotSizingDataModel fingerprint tool"

$fingerprintProject = Join-Path $BenchmarkRepo "tools\InstanceFingerprint\InstanceFingerprint.csproj"
& dotnet build $fingerprintProject -c Release --nologo -p:ModelRepo=$ModelRepo
if ($LASTEXITCODE -ne 0) {
    throw "InstanceFingerprint build failed."
}

Write-Step "Re-converting raw CLSPL to an isolated fingerprint staging area"

$converterProject = Join-Path $BenchmarkRepo "tools\TempelmeierConverter\TempelmeierConverter.csproj"
if (-not (Test-Path -LiteralPath $converterProject -PathType Leaf)) {
    throw "TempelmeierConverter missing. Install v0.3.3 first."
}

$stage = Join-Path $reportRoot "raw-reconversion"
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
Ensure-Dir $stage

& dotnet build $converterProject -c Release --nologo -p:ModelRepo=$ModelRepo
if ($LASTEXITCODE -ne 0) {
    throw "TempelmeierConverter build failed."
}

$conversionLog = @(
    & dotnet run --project $converterProject -c Release --no-build -p:ModelRepo=$ModelRepo -- clspl $rawRoot $stage 2>&1 |
    ForEach-Object { $_.ToString() }
)

[System.IO.File]::WriteAllLines(
    (Join-Path $reportRoot "raw-reconversion.log"),
    $conversionLog,
    (New-Object System.Text.UTF8Encoding($false))
)

$sourceToStage = New-Object System.Collections.Generic.List[object]

foreach ($line in $conversionLog) {
    if ($line -match "^OK\|(?<src>[^|]+)\|(?<xml>.+)$") {
        $src = $Matches["src"]
        $xml = $Matches["xml"]

        if ($src -match "(?i)datab") {
            $sourceToStage.Add([pscustomobject]@{
                raw_directory = $src
                stage_xml = $xml
            })
        }
    }
}

Write-Host ("Reconverted datab XML: " + $sourceToStage.Count)

Write-Step "Fingerprinting staged datab XML"

$stageFpLines = @(
    & dotnet run --project $fingerprintProject -c Release --no-build -p:ModelRepo=$ModelRepo -- $stage 2>&1 |
    ForEach-Object { $_.ToString() }
)

$stageByPath = @{}

foreach ($line in $stageFpLines) {
    if ($line -match "^OK\|(?<path>[^|]+)\|(?<iid>[^|]*)\|(?<name>[^|]*)\|(?<fp>.+)$") {
        $stageByPath[$Matches["path"]] = [pscustomobject]@{
            fingerprint = $Matches["fp"]
            instance_id = $Matches["iid"]
            name = $Matches["name"]
        }
    }
}

$rawFingerprintRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $sourceToStage) {
    if (-not $stageByPath.ContainsKey($row.stage_xml)) { continue }

    $leaf = Split-Path -Leaf $row.raw_directory
    $fp = $stageByPath[$row.stage_xml]

    $rawFingerprintRows.Add([pscustomobject]@{
        raw_directory = $row.raw_directory
        raw_leaf = $leaf
        normalized_raw_leaf = (Normalize-Id -Value $leaf)
        numeric_raw_leaf_key = (Leaf-Numeric-Key -Value $leaf)
        stage_xml = $row.stage_xml
        fingerprint = $fp.fingerprint
        generated_instance_id = $fp.instance_id
        generated_name = $fp.name
    })
}

$rawFingerprintRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "raw-datab-fingerprints.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Fingerprinting canonical 1291 CLSPL XML"

$canonicalFpLines = @(
    & dotnet run --project $fingerprintProject -c Release --no-build -p:ModelRepo=$ModelRepo -- $canonicalRoot 2>&1 |
    ForEach-Object { $_.ToString() }
)

$canonicalRows = New-Object System.Collections.Generic.List[object]

foreach ($line in $canonicalFpLines) {
    if ($line -match "^OK\|(?<path>[^|]+)\|(?<iid>[^|]*)\|(?<name>[^|]*)\|(?<fp>.+)$") {
        $canonicalRows.Add([pscustomobject]@{
            path = $Matches["path"]
            filename = (Split-Path -Leaf $Matches["path"])
            instance_id = $Matches["iid"]
            name = $Matches["name"]
            fingerprint = $Matches["fp"]
        })
    }
}

$canonicalByFp = @{}
foreach ($row in $canonicalRows) {
    if (-not $canonicalByFp.ContainsKey($row.fingerprint)) {
        $canonicalByFp[$row.fingerprint] = New-Object System.Collections.Generic.List[object]
    }
    $canonicalByFp[$row.fingerprint].Add($row)
}

Write-Step "Creating raw datab -> canonical XML fingerprint crosswalk"

$rawToXml = New-Object System.Collections.Generic.List[object]
$rawFingerprintAmbiguous = New-Object System.Collections.Generic.List[object]

foreach ($raw in $rawFingerprintRows) {
    $matches = @()
    if ($canonicalByFp.ContainsKey($raw.fingerprint)) {
        $matches = @($canonicalByFp[$raw.fingerprint])
    }

    if ($matches.Count -eq 1) {
        $rawToXml.Add([pscustomobject]@{
            raw_directory = $raw.raw_directory
            raw_leaf = $raw.raw_leaf
            numeric_raw_leaf_key = $raw.numeric_raw_leaf_key
            fingerprint = $raw.fingerprint
            lsdm_filename = $matches[0].filename
            canonical_instance_id = $matches[0].instance_id
            canonical_name = $matches[0].name
            mapping_status = "EXACT_SUPPLY_CHAIN_FINGERPRINT"
        })
    }
    else {
        $rawFingerprintAmbiguous.Add([pscustomobject]@{
            raw_directory = $raw.raw_directory
            fingerprint = $raw.fingerprint
            canonical_candidate_count = $matches.Count
            mapping_status = "FINGERPRINT_NOT_UNIQUE_OR_MISSING"
        })
    }
}

$rawToXml |
    Export-Csv -LiteralPath (Join-Path $reportRoot "raw-datab-to-lsdm-fingerprint-crosswalk.csv") -NoTypeInformation -Encoding UTF8

$rawFingerprintAmbiguous |
    Export-Csv -LiteralPath (Join-Path $reportRoot "raw-datab-fingerprint-ambiguous.csv") -NoTypeInformation -Encoding UTF8

Write-Host ("Unique raw->XML fingerprint mappings: " + $rawToXml.Count)
Write-Host ("Raw fingerprint unresolved: " + $rawFingerprintAmbiguous.Count)

Write-Step "Mapping solb workbook IDs to raw datab instance identities"

$workbookToRaw = New-Object System.Collections.Generic.List[object]
$workbookStillUnmapped = New-Object System.Collections.Generic.List[object]

foreach ($ref in $databRefs) {
    $id = $ref.source_instance_id
    $norm = Normalize-Id -Value $id
    $numKey = Leaf-Numeric-Key -Value $id

    $exact = @(
        $rawToXml |
        Where-Object {
            (Normalize-Id -Value $_.raw_leaf) -eq $norm
        }
    )

    $numeric = @()
    if (-not [string]::IsNullOrWhiteSpace($numKey)) {
        $numeric = @(
            $rawToXml |
            Where-Object {
                $_.numeric_raw_leaf_key -eq $numKey
            }
        )
    }

    if ($exact.Count -eq 1) {
        $m = $exact[0]
        $method = "EXACT_WORKBOOK_ID_TO_RAW_LEAF"
    }
    elseif ($numeric.Count -eq 1) {
        $m = $numeric[0]
        $method = "UNIQUE_WORKBOOK_NUMERIC_ID_TO_RAW_LEAF"
    }
    else {
        $workbookStillUnmapped.Add([pscustomobject]@{
            source_instance_id = $id
            normalized_id = $norm
            numeric_id_key = $numKey
            exact_raw_candidates = $exact.Count
            numeric_raw_candidates = $numeric.Count
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            status = "UNRESOLVED"
        })
        continue
    }

    $workbookToRaw.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $id
        raw_directory = $m.raw_directory
        raw_leaf = $m.raw_leaf
        lsdm_filename = $m.lsdm_filename
        supply_chain_fingerprint = $m.fingerprint
        mapping_method = ($method + "+EXACT_SUPPLY_CHAIN_FINGERPRINT")
        objective = $ref.objective
        lower_bound = $ref.lower_bound
        objective_status = $(if ([string]::IsNullOrWhiteSpace($ref.objective)) { "" } else { "LITERATURE_BEST_KNOWN" })
        lower_bound_status = $(if ([string]::IsNullOrWhiteSpace($ref.lower_bound)) { "" } else { "LITERATURE_LOWER_BOUND" })
        verified = "False"
    })
}

$workbookToRaw |
    Export-Csv -LiteralPath (Join-Path $reportRoot "solb-to-lsdm-crosswalk.csv") -NoTypeInformation -Encoding UTF8

$workbookStillUnmapped |
    Export-Csv -LiteralPath (Join-Path $reportRoot "solb-still-unmapped.csv") -NoTypeInformation -Encoding UTF8

Write-Host ("solb->LSDM mappings: " + $workbookToRaw.Count)
Write-Host ("solb still unresolved: " + $workbookStillUnmapped.Count)

Write-Step "Promoting only uniquely proven solb mappings"

$existing = @()
if (Test-Path -LiteralPath $mappedPath -PathType Leaf) {
    $existing = @(
        Import-Csv -LiteralPath $mappedPath |
        Where-Object { $_.test_set -ne "datab" }
    )
}

$combined = New-Object System.Collections.Generic.List[object]
foreach ($row in $existing) {
    $combined.Add($row)
}

foreach ($row in $workbookToRaw) {
    $combined.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        lsdm_filename = $row.lsdm_filename
        xml_name = ""
        xml_instance_id = ""
        xml_source_information = $row.raw_directory
        xml_detected_test_set = "datab"
        mapping_method = $row.mapping_method
        mapping_evidence = $row.supply_chain_fingerprint
        objective = $row.objective
        lower_bound = $row.lower_bound
        objective_status = $row.objective_status
        lower_bound_status = $row.lower_bound_status
        verified = "False"
        source_workbook = "solb.xls"
        source_sheet = ""
    })
}

$combined |
    Sort-Object test_set,source_instance_id |
    Export-Csv -LiteralPath $mappedPath -NoTypeInformation -Encoding UTF8

$newUnmapped = @(
    Import-Csv -LiteralPath $unmappedPath |
    Where-Object { $_.test_set -ne "datab" }
)

foreach ($row in $workbookStillUnmapped) {
    $newUnmapped += [pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        normalized_key = $row.normalized_id
        exact_candidate_count = $row.exact_raw_candidates
        suffix_candidate_count = $row.numeric_raw_candidates
        objective = $row.objective
        lower_bound = $row.lower_bound
        status = "UNMAPPED_OR_AMBIGUOUS"
    }
}

$newUnmapped |
    Export-Csv -LiteralPath $unmappedPath -NoTypeInformation -Encoding UTF8

$totalMapped = @(Import-Csv -LiteralPath $mappedPath).Count
$totalUnmapped = @(Import-Csv -LiteralPath $unmappedPath).Count

Write-Step "v0.3.8 summary"
Write-Host ("Raw datab directories: " + $rawDatab.Count)
Write-Host ("Reconverted datab XML: " + $sourceToStage.Count)
Write-Host ("Unique raw->XML fingerprint mappings: " + $rawToXml.Count + " / 60")
Write-Host ("solb->LSDM mappings: " + $workbookToRaw.Count + " / 60")
Write-Host ("CLSPL total mapped: " + $totalMapped + " / 1281")
Write-Host ("CLSPL unresolved: " + $totalUnmapped)
Write-Host ("Reports: " + $reportRoot)
