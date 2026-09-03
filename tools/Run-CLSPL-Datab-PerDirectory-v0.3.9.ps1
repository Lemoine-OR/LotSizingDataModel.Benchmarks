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

function Safe-Name {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
    $v = [regex]::Replace($Value, "[^A-Za-z0-9._-]", "-")
    $v = [regex]::Replace($v, "-+", "-")
    return $v.Trim("-")
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
    }
    catch {
    }

    $numbers = @(
        [regex]::Matches($leaf, "\d+") |
        ForEach-Object { [int]$_.Value }
    )

    if ($numbers.Count -eq 0) { return "" }
    return ($numbers -join "-")
}

function Invoke-Fingerprint {
    param(
        [string]$FingerprintProject,
        [string]$ModelRepo,
        [string]$InputPath
    )

    $lines = @(
        & dotnet run `
            --project $FingerprintProject `
            -c Release `
            --no-build `
            -p:ModelRepo=$ModelRepo `
            -- $InputPath 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    $ok = @(
        $lines |
        Where-Object { $_ -match "^OK\|" }
    )

    return $ok
}

$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$rawRoot = Join-Path $clsRoot "raw\materialized"
$canonicalRoot = Join-Path $clsRoot "instances"
$metaRoot = Join-Path $clsRoot "metadata"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.3.9"
$stageRoot = Join-Path $reportRoot "per-directory-stage"

Ensure-Dir $reportRoot

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
Ensure-Dir $stageRoot

$converterProject =
    Join-Path $BenchmarkRepo "tools\TempelmeierConverter\TempelmeierConverter.csproj"

$fingerprintProject =
    Join-Path $BenchmarkRepo "tools\InstanceFingerprint\InstanceFingerprint.csproj"

if (-not (Test-Path -LiteralPath $converterProject -PathType Leaf)) {
    throw "TempelmeierConverter missing. Install v0.3.3 first."
}

if (-not (Test-Path -LiteralPath $fingerprintProject -PathType Leaf)) {
    throw "InstanceFingerprint missing. Install v0.3.8 first."
}

Write-Step "Building converter and fingerprint tools"

& dotnet build $converterProject -c Release --nologo -p:ModelRepo=$ModelRepo
if ($LASTEXITCODE -ne 0) {
    throw "TempelmeierConverter build failed."
}

& dotnet build $fingerprintProject -c Release --nologo -p:ModelRepo=$ModelRepo
if ($LASTEXITCODE -ne 0) {
    throw "InstanceFingerprint build failed."
}

Write-Step "Locating raw datab directories"

$rawDatab = @(
    Get-ChildItem `
        -LiteralPath $rawRoot `
        -Filter "INDEX.PRN" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "(?i)datab" } |
    ForEach-Object { $_.Directory.FullName } |
    Sort-Object -Unique
)

Write-Host ("Raw datab directories: " + $rawDatab.Count)

Write-Step "Converting each datab directory independently"

$perDirRows = New-Object System.Collections.Generic.List[object]
$successCount = 0
$failureCount = 0

$ordinal = 0

foreach ($sourceDir in $rawDatab) {
    $ordinal++

    $leaf = Split-Path -Leaf $sourceDir
    $safe = Safe-Name -Value $leaf
    $target = Join-Path $stageRoot (
        $ordinal.ToString("D3") + "_" + $safe
    )

    Ensure-Dir $target

    $logLines = @(
        & dotnet run `
            --project $converterProject `
            -c Release `
            --no-build `
            -p:ModelRepo=$ModelRepo `
            -- clspl $sourceDir $target 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    $logPath = Join-Path $target "conversion.log"
    [System.IO.File]::WriteAllLines(
        $logPath,
        $logLines,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $xml = @(
        Get-ChildItem `
            -LiteralPath $target `
            -Filter "*.xml" `
            -File `
            -ErrorAction SilentlyContinue
    )

    if ($xml.Count -ne 1) {
        $failureCount++

        $perDirRows.Add([pscustomobject]@{
            ordinal = $ordinal
            raw_directory = $sourceDir
            raw_leaf = $leaf
            normalized_raw_leaf = (Normalize-Id -Value $leaf)
            numeric_raw_leaf_key = (Leaf-Numeric-Key -Value $leaf)
            conversion_status = "FAILED_OR_NON_UNIQUE_OUTPUT"
            generated_xml_count = $xml.Count
            generated_xml = ""
            fingerprint = ""
            log_path = $logPath
        })

        Write-Host (
            "FAIL " + $ordinal + "/60 " +
            $leaf + " xml=" + $xml.Count
        )
        continue
    }

    $fpLines = Invoke-Fingerprint `
        -FingerprintProject $fingerprintProject `
        -ModelRepo $ModelRepo `
        -InputPath $xml[0].FullName

    if ($fpLines.Count -ne 1) {
        $failureCount++

        $perDirRows.Add([pscustomobject]@{
            ordinal = $ordinal
            raw_directory = $sourceDir
            raw_leaf = $leaf
            normalized_raw_leaf = (Normalize-Id -Value $leaf)
            numeric_raw_leaf_key = (Leaf-Numeric-Key -Value $leaf)
            conversion_status = "FINGERPRINT_FAILED"
            generated_xml_count = 1
            generated_xml = $xml[0].FullName
            fingerprint = ""
            log_path = $logPath
        })

        Write-Host (
            "FAIL " + $ordinal + "/60 " +
            $leaf + " fingerprint"
        )
        continue
    }

    $line = $fpLines[0]

    if ($line -notmatch "^OK\|(?<path>[^|]+)\|(?<iid>[^|]*)\|(?<name>[^|]*)\|(?<fp>.+)$") {
        $failureCount++
        continue
    }

    $successCount++

    $perDirRows.Add([pscustomobject]@{
        ordinal = $ordinal
        raw_directory = $sourceDir
        raw_leaf = $leaf
        normalized_raw_leaf = (Normalize-Id -Value $leaf)
        numeric_raw_leaf_key = (Leaf-Numeric-Key -Value $leaf)
        conversion_status = "OK"
        generated_xml_count = 1
        generated_xml = $xml[0].FullName
        fingerprint = $Matches["fp"]
        log_path = $logPath
    })

    Write-Host (
        "OK   " + $ordinal + "/60 " + $leaf
    )
}

$perDirRows |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "datab-per-directory-conversion.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Per-directory conversion OK: " + $successCount)
Write-Host ("Per-directory conversion failed: " + $failureCount)

Write-Step "Fingerprinting canonical CLSPL XML"

$canonicalFpLines = Invoke-Fingerprint `
    -FingerprintProject $fingerprintProject `
    -ModelRepo $ModelRepo `
    -InputPath $canonicalRoot

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
        $canonicalByFp[$row.fingerprint] =
            New-Object System.Collections.Generic.List[object]
    }

    $canonicalByFp[$row.fingerprint].Add($row)
}

Write-Step "Mapping raw datab instances to canonical XML by native fingerprint"

$rawToCanonical = New-Object System.Collections.Generic.List[object]
$rawToCanonicalUnresolved = New-Object System.Collections.Generic.List[object]

foreach ($raw in ($perDirRows | Where-Object { $_.conversion_status -eq "OK" })) {
    $matches = @()

    if ($canonicalByFp.ContainsKey($raw.fingerprint)) {
        $matches = @($canonicalByFp[$raw.fingerprint])
    }

    if ($matches.Count -eq 1) {
        $rawToCanonical.Add([pscustomobject]@{
            raw_directory = $raw.raw_directory
            raw_leaf = $raw.raw_leaf
            normalized_raw_leaf = $raw.normalized_raw_leaf
            numeric_raw_leaf_key = $raw.numeric_raw_leaf_key
            fingerprint = $raw.fingerprint
            lsdm_filename = $matches[0].filename
            canonical_instance_id = $matches[0].instance_id
            canonical_name = $matches[0].name
            mapping_status = "EXACT_SUPPLY_CHAIN_FINGERPRINT"
        })
    }
    else {
        $rawToCanonicalUnresolved.Add([pscustomobject]@{
            raw_directory = $raw.raw_directory
            raw_leaf = $raw.raw_leaf
            fingerprint = $raw.fingerprint
            canonical_candidate_count = $matches.Count
            mapping_status = "FINGERPRINT_NOT_UNIQUE_OR_MISSING"
        })
    }
}

$rawToCanonical |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "raw-datab-to-canonical-fingerprint.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$rawToCanonicalUnresolved |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "raw-datab-to-canonical-unresolved.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Unique raw->canonical fingerprint mappings: " +
    $rawToCanonical.Count + " / " + $successCount
)

Write-Step "Mapping solb literature rows to raw datab directories"

$unmappedPath = Join-Path $metaRoot "CLSPL-LITERATURE-UNMAPPED.csv"
$mappedPath = Join-Path $metaRoot "CLSPL-LITERATURE-REFERENCES.csv"

$databRefs = @(
    Import-Csv -LiteralPath $unmappedPath |
    Where-Object { $_.test_set -eq "datab" }
)

$solbMapped = New-Object System.Collections.Generic.List[object]
$solbUnresolved = New-Object System.Collections.Generic.List[object]

foreach ($ref in $databRefs) {
    $norm = Normalize-Id -Value $ref.source_instance_id
    $num = Leaf-Numeric-Key -Value $ref.source_instance_id

    $exact = @(
        $rawToCanonical |
        Where-Object { $_.normalized_raw_leaf -eq $norm }
    )

    $numeric = @()

    if (-not [string]::IsNullOrWhiteSpace($num)) {
        $numeric = @(
            $rawToCanonical |
            Where-Object { $_.numeric_raw_leaf_key -eq $num }
        )
    }

    if ($exact.Count -eq 1) {
        $m = $exact[0]
        $method = "EXACT_SOLB_ID_TO_RAW_LEAF"
    }
    elseif ($numeric.Count -eq 1) {
        $m = $numeric[0]
        $method = "UNIQUE_SOLB_NUMERIC_ID_TO_RAW_LEAF"
    }
    else {
        $solbUnresolved.Add([pscustomobject]@{
            source_instance_id = $ref.source_instance_id
            normalized_id = $norm
            numeric_id_key = $num
            exact_candidate_count = $exact.Count
            numeric_candidate_count = $numeric.Count
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            status = "UNRESOLVED"
        })
        continue
    }

    $solbMapped.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $ref.source_instance_id
        raw_directory = $m.raw_directory
        raw_leaf = $m.raw_leaf
        lsdm_filename = $m.lsdm_filename
        supply_chain_fingerprint = $m.fingerprint
        mapping_method =
            ($method + "+EXACT_SUPPLY_CHAIN_FINGERPRINT")
        objective = $ref.objective
        lower_bound = $ref.lower_bound
        objective_status =
            $(if ([string]::IsNullOrWhiteSpace($ref.objective)) {
                ""
            }
            else {
                "LITERATURE_BEST_KNOWN"
            })
        lower_bound_status =
            $(if ([string]::IsNullOrWhiteSpace($ref.lower_bound)) {
                ""
            }
            else {
                "LITERATURE_LOWER_BOUND"
            })
        verified = "False"
    })
}

$solbMapped |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "solb-to-canonical.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$solbUnresolved |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "solb-unresolved.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "solb->canonical mappings: " +
    $solbMapped.Count + " / " + $databRefs.Count
)

Write-Step "Promoting only unique demonstrated datab mappings"

$existingNonDatab = @(
    Import-Csv -LiteralPath $mappedPath |
    Where-Object { $_.test_set -ne "datab" }
)

$combined = New-Object System.Collections.Generic.List[object]

foreach ($row in $existingNonDatab) {
    $combined.Add($row)
}

foreach ($row in $solbMapped) {
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
    Export-Csv `
        -LiteralPath $mappedPath `
        -NoTypeInformation `
        -Encoding UTF8

$remainingNonDatab = @(
    Import-Csv -LiteralPath $unmappedPath |
    Where-Object { $_.test_set -ne "datab" }
)

foreach ($row in $solbUnresolved) {
    $remainingNonDatab += [pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        normalized_key = $row.normalized_id
        exact_candidate_count = $row.exact_candidate_count
        suffix_candidate_count = $row.numeric_candidate_count
        objective = $row.objective
        lower_bound = $row.lower_bound
        status = "UNMAPPED_OR_AMBIGUOUS"
    }
}

$remainingNonDatab |
    Export-Csv `
        -LiteralPath $unmappedPath `
        -NoTypeInformation `
        -Encoding UTF8

$totalMapped = @(Import-Csv -LiteralPath $mappedPath).Count
$totalUnmapped = @(Import-Csv -LiteralPath $unmappedPath).Count

Write-Step "v0.3.9 summary"
Write-Host ("Raw datab directories: " + $rawDatab.Count)
Write-Host ("Per-directory conversion OK: " + $successCount + " / 60")
Write-Host ("Per-directory conversion failed: " + $failureCount)
Write-Host ("Unique raw->canonical fingerprint mappings: " + $rawToCanonical.Count + " / " + $successCount)
Write-Host ("solb->canonical mappings: " + $solbMapped.Count + " / 60")
Write-Host ("CLSPL total mapped: " + $totalMapped + " / 1281")
Write-Host ("CLSPL unresolved: " + $totalUnmapped)
Write-Host ("Reports: " + $reportRoot)
