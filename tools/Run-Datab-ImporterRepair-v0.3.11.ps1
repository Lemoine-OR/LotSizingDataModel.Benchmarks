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

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $v = $Value.ToLowerInvariant().Trim()
    $v = [regex]::Replace($v, "\.[a-z0-9]+$", "")
    $v = [regex]::Replace($v, "[^a-z0-9]", "")
    return $v
}

function Numeric-Key {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $numbers = @(
        [regex]::Matches($Value, "\d+") |
        ForEach-Object { [int]$_.Value }
    )

    if ($numbers.Count -eq 0) {
        return ""
    }

    return ($numbers -join "-")
}

$converterProject =
    Join-Path $BenchmarkRepo "tools\TempelmeierConverter\TempelmeierConverter.csproj"

$rawRoot =
    Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\materialized"

$familyRoot =
    Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"

$databRoot =
    Join-Path $familyRoot "TestSet3-datab"

$outRoot =
    Join-Path $databRoot "instances"

$withRefRoot =
    Join-Path $databRoot "instances-with-reference"

$metaRoot =
    Join-Path $databRoot "metadata"

$reportRoot =
    Join-Path $BenchmarkRepo "reports\v0.3.11"

foreach ($path in @($outRoot,$withRefRoot,$metaRoot,$reportRoot)) {
    Ensure-Dir $path
}

Write-Step "Installing repaired TempelmeierConverter"
Write-Host ("Project: " + $converterProject)

& dotnet build `
    $converterProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Repaired converter build failed."
}

Write-Step "Converting the 60 datab/B+ raw instances"

$tempInput =
    Join-Path $reportRoot "datab-source-links"

if (Test-Path -LiteralPath $tempInput) {
    Remove-Item -LiteralPath $tempInput -Recurse -Force
}
Ensure-Dir $tempInput

$rawDirs = @(
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

$rows = New-Object System.Collections.Generic.List[object]
$ordinal = 0

foreach ($src in $rawDirs) {
    $ordinal++

    $leaf = Split-Path -Leaf $src
    $stage = Join-Path $reportRoot (
        "instance-" + $ordinal.ToString("D3")
    )

    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }

    Ensure-Dir $stage

    $log = @(
        & dotnet run `
            --project $converterProject `
            -c Release `
            --no-build `
            -p:ModelRepo=$ModelRepo `
            -- datab $src $stage 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    $xml = @(
        Get-ChildItem `
            -LiteralPath $stage `
            -Filter "*.xml" `
            -File `
            -ErrorAction SilentlyContinue
    )

    if ($xml.Count -eq 1) {
        Copy-Item `
            -LiteralPath $xml[0].FullName `
            -Destination (Join-Path $outRoot $xml[0].Name) `
            -Force

        Copy-Item `
            -LiteralPath $xml[0].FullName `
            -Destination (Join-Path $withRefRoot $xml[0].Name) `
            -Force

        $rows.Add([pscustomobject]@{
            ordinal = $ordinal
            raw_directory = $src
            raw_leaf = $leaf
            normalized_raw_leaf = (Normalize-Id -Value $leaf)
            numeric_raw_key = (Numeric-Key -Value $leaf)
            lsdm_filename = $xml[0].Name
            status = "CONVERTED"
        })

        Write-Host (
            "OK " + $ordinal + "/60 " + $leaf
        )
    }
    else {
        $rows.Add([pscustomobject]@{
            ordinal = $ordinal
            raw_directory = $src
            raw_leaf = $leaf
            normalized_raw_leaf = (Normalize-Id -Value $leaf)
            numeric_raw_key = (Numeric-Key -Value $leaf)
            lsdm_filename = ""
            status = "FAILED"
        })

        Write-Host (
            "FAIL " + $ordinal + "/60 " + $leaf
        )
    }
}

$rows |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "datab-conversion-map.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$converted = @(
    $rows |
    Where-Object { $_.status -eq "CONVERTED" }
)

Write-Host ("Converted datab/B+ XML: " + $converted.Count + " / 60")

Write-Step "Running structural checker on datab/B+ XML"

$checker =
    Join-Path $ModelRepo "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"

$checkerReport =
    Join-Path $reportRoot "checker"

Ensure-Dir $checkerReport

if ($converted.Count -gt 0) {
    & dotnet run `
        --project $checker `
        -c Release `
        -- `
        $outRoot `
        --level structural `
        --output $checkerReport `
        --no-progress

    Write-Host (
        "Checker exit: " + $LASTEXITCODE
    )
}

Write-Step "Mapping solb literature references to repaired datab XML"

$unmappedPath =
    Join-Path $familyRoot "metadata\CLSPL-LITERATURE-UNMAPPED.csv"

$globalMappedPath =
    Join-Path $familyRoot "metadata\CLSPL-LITERATURE-REFERENCES.csv"

$solbRefs = @(
    Import-Csv -LiteralPath $unmappedPath |
    Where-Object { $_.test_set -eq "datab" }
)

$mapped = New-Object System.Collections.Generic.List[object]
$still = New-Object System.Collections.Generic.List[object]

foreach ($ref in $solbRefs) {
    $norm = Normalize-Id -Value $ref.source_instance_id
    $num = Numeric-Key -Value $ref.source_instance_id

    $exact = @(
        $converted |
        Where-Object {
            $_.normalized_raw_leaf -eq $norm
        }
    )

    $numeric = @()

    if (-not [string]::IsNullOrWhiteSpace($num)) {
        $numeric = @(
            $converted |
            Where-Object {
                $_.numeric_raw_key -eq $num
            }
        )
    }

    if ($exact.Count -eq 1) {
        $match = $exact[0]
        $method = "EXACT_SOLB_ID_TO_RAW_DATAB"
    }
    elseif ($numeric.Count -eq 1) {
        $match = $numeric[0]
        $method = "UNIQUE_SOLB_NUMERIC_ID_TO_RAW_DATAB"
    }
    else {
        $still.Add([pscustomobject]@{
            source_instance_id = $ref.source_instance_id
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            exact_candidates = $exact.Count
            numeric_candidates = $numeric.Count
            status = "UNRESOLVED"
        })

        continue
    }

    $mapped.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $ref.source_instance_id
        raw_directory = $match.raw_directory
        lsdm_filename = $match.lsdm_filename
        mapping_method = $method
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
        source_workbook = "solb.xls"
    })
}

$mapped |
    Export-Csv `
        -LiteralPath (Join-Path $metaRoot "literature-references.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$still |
    Export-Csv `
        -LiteralPath (Join-Path $metaRoot "literature-unresolved.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("solb mapped: " + $mapped.Count + " / 60")
Write-Host ("solb unresolved: " + $still.Count)

Write-Step "Updating global CLSPL reference catalogue"

$nonDatab = @(
    Import-Csv -LiteralPath $globalMappedPath |
    Where-Object { $_.test_set -ne "datab" }
)

$combined = New-Object System.Collections.Generic.List[object]

foreach ($row in $nonDatab) {
    $combined.Add($row)
}

foreach ($row in $mapped) {
    $combined.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        lsdm_filename = $row.lsdm_filename
        xml_name = ""
        xml_instance_id = ""
        xml_source_information = $row.raw_directory
        xml_detected_test_set = "datab"
        mapping_method = $row.mapping_method
        mapping_evidence = "DIRECT_RAW_DATAB_RECONVERSION"
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
        -LiteralPath $globalMappedPath `
        -NoTypeInformation `
        -Encoding UTF8

$remaining = @(
    Import-Csv -LiteralPath $unmappedPath |
    Where-Object { $_.test_set -ne "datab" }
)

foreach ($row in $still) {
    $remaining += [pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        normalized_key = ""
        exact_candidate_count = $row.exact_candidates
        suffix_candidate_count = $row.numeric_candidates
        objective = $row.objective
        lower_bound = $row.lower_bound
        status = "UNMAPPED_OR_AMBIGUOUS"
    }
}

$remaining |
    Export-Csv `
        -LiteralPath $unmappedPath `
        -NoTypeInformation `
        -Encoding UTF8

$totalMapped = @(
    Import-Csv -LiteralPath $globalMappedPath
).Count

$totalUnmapped = @(
    Import-Csv -LiteralPath $unmappedPath
).Count

Write-Step "Generating datab GitHub page"

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# CLSPL TestSet3 - datab")
$lines.Add("")
$lines.Add("> 60 MLCLSP instances from Stadtler class B+, represented in the CLSPL benchmark package.")
$lines.Add("")
$lines.Add("| Metric | Count |")
$lines.Add("|---|---:|")
$lines.Add("| Raw datab directories | **$($rawDirs.Count)** |")
$lines.Add("| Converted LSDM XML | **$($converted.Count)** |")
$lines.Add("| Literature rows mapped | **$($mapped.Count)** |")
$lines.Add("| Literature rows unresolved | **$($still.Count)** |")
$lines.Add("")
$lines.Add("The missing explicit `KAPAZ.PRN`, `LAGKOST.PRN` and `RUESTK.PRN` values are reconstructed from the official Stadtler generation variables and formulas.")
$lines.Add("")
$lines.Add("Published objective values and lower bounds remain **LITERATURE / UNVERIFIED** until a complete solution is independently checked.")

[System.IO.File]::WriteAllLines(
    (Join-Path $databRoot "README.md"),
    $lines,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "v0.3.11 summary"
Write-Host ("Raw datab directories: " + $rawDirs.Count)
Write-Host ("Converted datab/B+ XML: " + $converted.Count + " / 60")
Write-Host ("solb mapped: " + $mapped.Count + " / 60")
Write-Host ("solb unresolved: " + $still.Count)
Write-Host ("CLSPL total literature mappings: " + $totalMapped + " / 1281")
Write-Host ("CLSPL unresolved literature rows: " + $totalUnmapped)
Write-Host ("Reports: " + $reportRoot)
