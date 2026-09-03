param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
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

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$metaRoot = Join-Path $familyRoot "metadata"
$mappedPath = Join-Path $metaRoot "CLSPL-LITERATURE-REFERENCES.csv"
$unmappedPath = Join-Path $metaRoot "CLSPL-LITERATURE-UNMAPPED.csv"

if (-not (Test-Path -LiteralPath $mappedPath -PathType Leaf)) {
    throw "Missing CLSPL mapped reference catalogue."
}

$current = @(Import-Csv -LiteralPath $mappedPath)
$currentDatab = @($current | Where-Object { $_.test_set -eq "datab" })

Write-Step "Checking CLSPL reference catalogue before Stadtler v0.4.0"
Write-Host ("Current mapped rows: " + $current.Count)
Write-Host ("Current datab rows: " + $currentDatab.Count)

if ($current.Count -eq 1281 -and $currentDatab.Count -eq 60) {
    Write-Host "CLSPL reference catalogue already complete: 1281 / 1281."
    exit 0
}

# Prefer the exact successful v0.3.11 datab literature sidecar if it survived.
$sidecar = Join-Path $familyRoot "TestSet3-datab\metadata\literature-references.csv"
$databRows = @()

if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
    $candidate = @(Import-Csv -LiteralPath $sidecar)
    if ($candidate.Count -eq 60) {
        $databRows = $candidate
        Write-Host "Recovered 60 datab rows from TestSet3-datab metadata sidecar."
    }
}

# If sidecar was overwritten or empty, rebuild from solb resolved rows plus v0.3.11 conversion map.
if ($databRows.Count -ne 60) {
    Write-Step "Reconstructing datab references from solb workbook and conversion map"

    $solbResolved = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $familyRoot "literature") `
            -Filter "solb-resolved-references.csv" `
            -File `
            -ErrorAction SilentlyContinue |
        Select-Object -First 1
    )

    $conversionMap = Join-Path $BenchmarkRepo "reports\v0.3.11\datab-conversion-map.csv"

    if ($solbResolved.Count -ne 1) {
        throw "Cannot restore datab: solb-resolved-references.csv not found."
    }

    if (-not (Test-Path -LiteralPath $conversionMap -PathType Leaf)) {
        throw "Cannot restore datab: v0.3.11 datab-conversion-map.csv not found."
    }

    $refs = @(Import-Csv -LiteralPath $solbResolved[0].FullName)
    $conv = @(
        Import-Csv -LiteralPath $conversionMap |
        Where-Object { $_.status -eq "CONVERTED" }
    )

    if ($refs.Count -ne 60) {
        throw ("Expected 60 solb reference rows, found " + $refs.Count)
    }

    if ($conv.Count -ne 60) {
        throw ("Expected 60 converted datab instances, found " + $conv.Count)
    }

    $rebuilt = New-Object System.Collections.Generic.List[object]

    foreach ($ref in $refs) {
        $norm = Normalize-Id -Value $ref.source_instance_id
        $num = Numeric-Key -Value $ref.source_instance_id

        $exact = @(
            $conv |
            Where-Object { $_.normalized_raw_leaf -eq $norm }
        )

        $numeric = @()
        if (-not [string]::IsNullOrWhiteSpace($num)) {
            $numeric = @(
                $conv |
                Where-Object { $_.numeric_raw_key -eq $num }
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
            throw (
                "Could not uniquely restore datab reference " +
                $ref.source_instance_id +
                " exact=" + $exact.Count +
                " numeric=" + $numeric.Count
            )
        }

        $rebuilt.Add([pscustomobject]@{
            test_set = "datab"
            source_instance_id = $ref.source_instance_id
            raw_directory = $match.raw_directory
            lsdm_filename = $match.lsdm_filename
            mapping_method = $method
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            objective_status = $(if ([string]::IsNullOrWhiteSpace($ref.objective)) { "" } else { "LITERATURE_BEST_KNOWN" })
            lower_bound_status = $(if ([string]::IsNullOrWhiteSpace($ref.lower_bound)) { "" } else { "LITERATURE_LOWER_BOUND" })
            verified = "False"
            source_workbook = "solb.xls"
        })
    }

    $databRows = $rebuilt.ToArray()

    $databRows |
        Export-Csv `
            -LiteralPath $sidecar `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Host "Rebuilt and restored 60 datab literature references."
}

if ($databRows.Count -ne 60) {
    throw ("CLSPL datab repair did not produce 60 rows; got " + $databRows.Count)
}

Write-Step "Restoring global CLSPL 1281-row reference catalogue"

$nonDatab = @(
    $current |
    Where-Object { $_.test_set -ne "datab" }
)

if ($nonDatab.Count -ne 1221) {
    throw (
        "Expected 1221 non-datab mapped references before repair; found " +
        $nonDatab.Count
    )
}

$combined = New-Object System.Collections.Generic.List[object]

foreach ($row in $nonDatab) {
    $combined.Add($row)
}

foreach ($row in $databRows) {
    $combined.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        lsdm_filename = $row.lsdm_filename
        xml_name = ""
        xml_instance_id = ""
        xml_source_information = $row.raw_directory
        xml_detected_test_set = "datab"
        mapping_method = $row.mapping_method
        mapping_evidence = "RESTORED_FROM_V0.3.11_PROVEN_MAPPING"
        objective = $row.objective
        lower_bound = $row.lower_bound
        objective_status = $row.objective_status
        lower_bound_status = $row.lower_bound_status
        verified = "False"
        source_workbook = "solb.xls"
        source_sheet = ""
    })
}

$combined.ToArray() |
    Sort-Object test_set,source_instance_id |
    Export-Csv `
        -LiteralPath $mappedPath `
        -NoTypeInformation `
        -Encoding UTF8

# Ensure no stale datab rows remain in the unresolved catalogue.
if (Test-Path -LiteralPath $unmappedPath -PathType Leaf) {
    $remaining = @(
        Import-Csv -LiteralPath $unmappedPath |
        Where-Object { $_.test_set -ne "datab" }
    )

    if ($remaining.Count -gt 0) {
        $remaining |
            Export-Csv `
                -LiteralPath $unmappedPath `
                -NoTypeInformation `
                -Encoding UTF8
    }
    else {
        [System.IO.File]::WriteAllText(
            $unmappedPath,
            "",
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
}

$final = @(Import-Csv -LiteralPath $mappedPath)
$finalDatab = @($final | Where-Object { $_.test_set -eq "datab" })

Write-Host ("CLSPL mapped rows after repair: " + $final.Count)
Write-Host ("CLSPL datab rows after repair: " + $finalDatab.Count)

if ($final.Count -ne 1281 -or $finalDatab.Count -ne 60) {
    throw "CLSPL catalogue repair failed final validation."
}

Write-Host "CLSPL catalogue restored successfully: 1281 / 1281."
