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

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function First-TextLines {
    param([string]$Path,[int]$Count=8)
    try {
        return ((Get-Content -LiteralPath $Path -TotalCount $Count -ErrorAction Stop) -join " || ")
    }
    catch {
        return ""
    }
}

$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$rawRoot = Join-Path $clsRoot "raw\materialized"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.3.10"
$v039 = Join-Path $BenchmarkRepo "reports\v0.3.9"

Ensure-Dir $reportRoot

Write-Step "Reading v0.3.9 per-directory failures"

$v039Csv = Join-Path $v039 "datab-per-directory-conversion.csv"
$failed = @()

if (Test-Path -LiteralPath $v039Csv -PathType Leaf) {
    $failed = @(
        Import-Csv -LiteralPath $v039Csv |
        Where-Object { $_.conversion_status -ne "OK" }
    )
}

Write-Host ("Failed datab directories from v0.3.9: " + $failed.Count)

Write-Step "Auditing required CLSPL source-file contract"

$required = @(
    "INDEX.PRN",
    "P-BEDARF.PRN",
    "KAPAZ.PRN",
    "LAGKOST.PRN",
    "L0.PRN",
    "LT.PRN",
    "RUESTK.PRN",
    "UEBER-KS.PRN",
    "PRODKOEF.PRN",
    "RUESTZ.PRN",
    "DIREKT-B.PRN"
)

$contractRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $failed) {
    $dir = $row.raw_directory
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        continue
    }

    foreach ($name in $required) {
        $direct = Join-Path $dir $name
        $parent = Join-Path (Split-Path -Parent $dir) $name
        $grand = Join-Path (Split-Path -Parent (Split-Path -Parent $dir)) $name

        $location = "MISSING"
        $actual = ""

        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            $location = "DIRECT"
            $actual = $direct
        }
        elseif (Test-Path -LiteralPath $parent -PathType Leaf) {
            $location = "PARENT"
            $actual = $parent
        }
        elseif (Test-Path -LiteralPath $grand -PathType Leaf) {
            $location = "GRANDPARENT"
            $actual = $grand
        }
        else {
            # Case-insensitive / alternate spelling discovery.
            $searchRoots = @($dir,(Split-Path -Parent $dir))
            foreach ($searchRoot in $searchRoots) {
                if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
                    continue
                }

                $candidate = @(
                    Get-ChildItem -LiteralPath $searchRoot -File -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Name.Replace("_","-").ToUpperInvariant() -eq
                        $name.Replace("_","-").ToUpperInvariant()
                    } |
                    Select-Object -First 1
                )

                if ($candidate.Count -eq 1) {
                    $location = "ALTERNATE_NAME"
                    $actual = $candidate[0].FullName
                    break
                }
            }
        }

        $contractRows.Add([pscustomobject]@{
            raw_directory = $dir
            required_file = $name
            location = $location
            actual_path = $actual
            preview = $(if ([string]::IsNullOrWhiteSpace($actual)) { "" } else { First-TextLines -Path $actual })
        })
    }
}

$contractRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "datab-required-file-contract.csv") -NoTypeInformation -Encoding UTF8

$missingSummary = @(
    $contractRows |
    Where-Object { $_.location -eq "MISSING" } |
    Group-Object required_file |
    Sort-Object Count -Descending
)

Write-Host ""
Write-Host "Missing required files across datab:"
foreach ($g in $missingSummary) {
    Write-Host ("  " + $g.Name + ": missing in " + $g.Count + " directories")
}

Write-Step "Finding source directories that converted successfully in v0.3.3"

$v033Log = Join-Path $BenchmarkRepo "reports\tempelmeier-conversion\clspl-conversion.log"
$successDirs = New-Object System.Collections.Generic.List[string]

if (Test-Path -LiteralPath $v033Log -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $v033Log -ErrorAction SilentlyContinue) {
        if ($line -match "^OK\|(?<src>[^|]+)\|(?<xml>.+)$") {
            $successDirs.Add($Matches["src"])
        }
    }
}

Write-Host ("Successful source directories recorded by v0.3.3: " + $successDirs.Count)

$successContractRows = New-Object System.Collections.Generic.List[object]

foreach ($dir in ($successDirs | Select-Object -First 100)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        continue
    }

    foreach ($name in $required) {
        $path = Join-Path $dir $name

        $successContractRows.Add([pscustomobject]@{
            raw_directory = $dir
            required_file = $name
            present = (Test-Path -LiteralPath $path -PathType Leaf)
            actual_path = $(if (Test-Path -LiteralPath $path -PathType Leaf) { $path } else { "" })
        })
    }
}

$successContractRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "successful-clspl-required-file-contract.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Capturing exact per-directory converter errors"

$errorRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $failed) {
    $log = $row.log_path

    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
        continue
    }

    foreach ($line in Get-Content -LiteralPath $log -ErrorAction SilentlyContinue) {
        if ($line -match "^FAIL\|(?<src>[^|]+)\|(?<type>[^|]+)\|(?<message>.*)$") {
            $errorRows.Add([pscustomobject]@{
                raw_directory = $row.raw_directory
                exception_type = $Matches["type"]
                message = $Matches["message"]
                log_path = $log
            })
        }
    }
}

$errorRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "datab-exact-converter-errors.csv") -NoTypeInformation -Encoding UTF8

$errorGroups = @(
    $errorRows |
    Group-Object exception_type,message |
    Sort-Object Count -Descending
)

Write-Host ""
Write-Host "Exact converter error groups:"
foreach ($g in $errorGroups) {
    $x = $g.Group[0]
    Write-Host ("  x" + $g.Count + " " + $x.exception_type + ": " + $x.message)
}

Write-Step "Looking for alternate datab file names"

$fileNames = @{}

foreach ($row in $failed) {
    $dir = $row.raw_directory
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

    foreach ($file in Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue) {
        $key = $file.Name.ToUpperInvariant()

        if (-not $fileNames.ContainsKey($key)) {
            $fileNames[$key] = 0
        }

        $fileNames[$key]++
    }
}

$nameRows = New-Object System.Collections.Generic.List[object]
foreach ($key in ($fileNames.Keys | Sort-Object)) {
    $nameRows.Add([pscustomobject]@{
        file_name = $key
        directory_count = $fileNames[$key]
    })
}

$nameRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "datab-file-name-frequency.csv") -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Files present in all 60 datab directories:"
foreach ($n in ($nameRows | Where-Object { [int]$_.directory_count -eq 60 })) {
    Write-Host ("  " + $n.file_name)
}

Write-Step "Generating repair recommendation"

$missingFiles = @($missingSummary | ForEach-Object { $_.Name })
$recommendation = "UNKNOWN"

if ($missingFiles.Count -eq 0 -and $errorRows.Count -gt 0) {
    $recommendation = "FORMAT_CONTENT_MISMATCH"
}
elseif ($missingFiles.Count -gt 0) {
    $parentResolvable = @(
        $contractRows |
        Where-Object {
            $_.location -eq "PARENT" -or
            $_.location -eq "GRANDPARENT" -or
            $_.location -eq "ALTERNATE_NAME"
        }
    ).Count

    if ($parentResolvable -gt 0) {
        $recommendation = "REPAIR_SEARCH_PATH_OR_ALTERNATE_NAMES"
    }
    else {
        $recommendation = "DATAB_HAS_DIFFERENT_SOURCE_CONTRACT"
    }
}

$summary = @(
    "# v0.3.10 datab contract audit",
    "",
    ("Failed datab directories: " + $failed.Count),
    ("Exact converter errors captured: " + $errorRows.Count),
    ("Missing-file groups: " + $missingSummary.Count),
    ("Repair recommendation: " + $recommendation),
    "",
    "No benchmark data were changed by this pack.",
    "The next importer patch should be based on the exact contract audit rather than further identity heuristics."
)

[System.IO.File]::WriteAllLines(
    (Join-Path $reportRoot "README.md"),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "v0.3.10 summary"
Write-Host ("Failed datab directories: " + $failed.Count)
Write-Host ("Converter error signatures: " + $errorGroups.Count)
Write-Host ("Missing required file types: " + $missingSummary.Count)
Write-Host ("Repair recommendation: " + $recommendation)
Write-Host ("Reports: " + $reportRoot)
