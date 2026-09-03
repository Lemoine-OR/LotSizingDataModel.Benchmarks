param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" }
function Ensure-Dir { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

$reportRoot = Join-Path $BenchmarkRepo "reports\tempelmeier-conversion"
$stadtLog = Join-Path $reportRoot "stadtler-conversion.log"
$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\materialized"
$stadtRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\materialized"
$outRoot = Join-Path $BenchmarkRepo "reports\v0.3.4"
Ensure-Dir $outRoot

Write-Step "Diagnosing Stadtler conversion failures"

$failureRows = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $stadtLog -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $stadtLog -ErrorAction SilentlyContinue) {
        if ($line -match "^FAIL\|(?<dir>[^|]+)\|(?<type>[^|]+)\|(?<message>.*)$") {
            $failureRows.Add([pscustomobject]@{
                directory = $Matches["dir"]
                exception_type = $Matches["type"]
                message = $Matches["message"]
            })
        }
    }
}

$failureRows | Export-Csv -LiteralPath (Join-Path $outRoot "stadtler-failures.csv") -NoTypeInformation -Encoding UTF8

$errorGroups = $failureRows | Group-Object exception_type,message | Sort-Object Count -Descending
$errorSummary = New-Object System.Collections.Generic.List[object]
foreach ($g in $errorGroups) {
    $first = $g.Group[0]
    $errorSummary.Add([pscustomobject]@{
        count = $g.Count
        exception_type = $first.exception_type
        message = $first.message
        example_directory = $first.directory
    })
}
$errorSummary | Export-Csv -LiteralPath (Join-Path $outRoot "stadtler-error-summary.csv") -NoTypeInformation -Encoding UTF8

Write-Host ("Stadtler failed directories: " + $failureRows.Count)
foreach ($e in ($errorSummary | Select-Object -First 10)) {
    Write-Host ("  x" + $e.count + " " + $e.exception_type + ": " + $e.message)
    Write-Host ("     example: " + $e.example_directory)
}

Write-Step "Capturing exact Stadtler source signatures"

$sourceRows = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $stadtRoot -PathType Container) {
    $indexes = @(Get-ChildItem -LiteralPath $stadtRoot -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($idx in $indexes) {
        $dir = $idx.Directory.FullName
        $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Sort-Object Name)

        foreach ($file in $files) {
            $preview = ""
            if ($file.Length -lt 5MB) {
                try {
                    $preview = ((Get-Content -LiteralPath $file.FullName -TotalCount 8 -ErrorAction Stop) -join " || ")
                } catch {}
            }

            $sourceRows.Add([pscustomobject]@{
                instance_directory = $dir
                file_name = $file.Name
                size_bytes = $file.Length
                preview = $preview
            })
        }
    }
}
$sourceRows | Export-Csv -LiteralPath (Join-Path $outRoot "stadtler-source-signatures.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Discovering CLSPL result and bound files"

$clsRefRows = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $clsRoot -PathType Container) {
    Get-ChildItem -LiteralPath $clsRoot -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        $kind = ""

        if ($name -match "(?i)(best|obj|sol|result|bound|lower|lb|upper|ub|wert|ziel)") {
            $kind = "candidate-reference-file"
        }

        if (-not [string]::IsNullOrWhiteSpace($kind)) {
            $preview = ""
            try {
                $preview = ((Get-Content -LiteralPath $_.FullName -TotalCount 15 -ErrorAction Stop) -join " || ")
            } catch {}

            $clsRefRows.Add([pscustomobject]@{
                relative_path = $_.FullName.Substring($clsRoot.Length).TrimStart('\')
                file_name = $name
                extension = $_.Extension
                size_bytes = $_.Length
                kind = $kind
                preview = $preview
            })
        }
    }
}

$clsRefRows | Sort-Object relative_path |
    Export-Csv -LiteralPath (Join-Path $outRoot "clspl-reference-files.csv") -NoTypeInformation -Encoding UTF8

Write-Host ("CLSPL candidate result/bound files: " + $clsRefRows.Count)
foreach ($r in ($clsRefRows | Select-Object -First 20)) {
    Write-Host ("  " + $r.relative_path)
}

Write-Step "Checking converted CLSPL filename coverage"

$clsXml = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\instances"
$xmlFiles = @()
if (Test-Path -LiteralPath $clsXml -PathType Container) {
    $xmlFiles = @(Get-ChildItem -LiteralPath $clsXml -Filter "*.xml" -File -ErrorAction SilentlyContinue)
}

$coverage = @(
    [pscustomobject]@{
        family_id = "SUERIE_CLSPL"
        converted_xml = $xmlFiles.Count
        candidate_reference_files = $clsRefRows.Count
        structural_load_status = "1291/1291 VALID in v0.3.3 checker campaign"
    }
)

$coverage | Export-Csv -LiteralPath (Join-Path $outRoot "coverage.csv") -NoTypeInformation -Encoding UTF8

$summary = @(
    "# v0.3.4 diagnostic summary",
    "",
    ("- Stadtler failed directories: " + $failureRows.Count),
    ("- Distinct Stadtler error signatures: " + $errorSummary.Count),
    ("- Stadtler source signature rows: " + $sourceRows.Count),
    ("- CLSPL converted XML: " + $xmlFiles.Count),
    ("- CLSPL candidate result/bound files: " + $clsRefRows.Count),
    "",
    "The next converter repair should be based on stadtler-error-summary.csv and stadtler-source-signatures.csv.",
    "CLSPL literature/BKV ingestion should be based on clspl-reference-files.csv; no result is promoted by this diagnostic step."
)

[System.IO.File]::WriteAllLines(
    (Join-Path $outRoot "README.md"),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "Done"
Write-Host ("Report directory: " + $outRoot)
