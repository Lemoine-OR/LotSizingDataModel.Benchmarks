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

function Read-Preview {
    param([string]$Path,[int]$MaxLines=20)
    try {
        return @(Get-Content -LiteralPath $Path -TotalCount $MaxLines -ErrorAction Stop)
    } catch {
        return @("<READ ERROR: " + $_.Exception.Message + ">")
    }
}

$reportRoot = Join-Path $BenchmarkRepo "reports\tempelmeier-format-audit"
Ensure-Dir $reportRoot

$families = @(
    [pscustomobject]@{
        Id="STADTLER2003"
        Root=(Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\extracted")
    },
    [pscustomobject]@{
        Id="SUERIE_CLSPL"
        Root=(Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\extracted")
    },
    [pscustomobject]@{
        Id="TB2009"
        Root=(Join-Path $BenchmarkRepo "benchmarks\TB2009\raw\extracted")
    }
)

$inventory = New-Object System.Collections.Generic.List[object]
$signatureRows = New-Object System.Collections.Generic.List[object]

Write-Step "Inventorying extracted upstream files"

foreach ($family in $families) {
    if (-not (Test-Path -LiteralPath $family.Root -PathType Container)) {
        Write-Host ($family.Id + ": extracted directory not present")
        continue
    }

    $files = @(Get-ChildItem -LiteralPath $family.Root -File -Recurse -ErrorAction SilentlyContinue)
    Write-Host ($family.Id + ": " + $files.Count + " files")

    foreach ($file in $files) {
        $rel = $file.FullName.Substring($family.Root.Length).TrimStart('\')
        $inventory.Add([pscustomobject]@{
            family_id = $family.Id
            relative_path = $rel
            extension = $file.Extension
            size_bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        })

        $upper = $file.Name.ToUpperInvariant()
        $known = @(
            "INDEX.PRN","AUSLAST.PRN","DIREKT-B.PRN","L0.PRN","LT.PRN",
            "MITT_BED.PRN","P-BEDARF.PRN","PRODKOEF.PRN","RUESTZ.PRN",
            "TBO.PRN","UEBER-KS.PRN","ZFKOEF.PRN","START_INI.BAT"
        )

        if ($known -contains $upper -or
            $file.Extension -match "(?i)\.(prn|dat|txt|bat|csv|sol|res)$") {

            $preview = Read-Preview -Path $file.FullName -MaxLines 12
            $previewText = ($preview -join " || ")

            $signatureRows.Add([pscustomobject]@{
                family_id = $family.Id
                relative_path = $rel
                file_name = $file.Name
                preview = $previewText
            })
        }
    }
}

$inventory |
    Sort-Object family_id,relative_path |
    Export-Csv -LiteralPath (Join-Path $reportRoot "file-inventory.csv") -NoTypeInformation -Encoding UTF8

$signatureRows |
    Sort-Object family_id,relative_path |
    Export-Csv -LiteralPath (Join-Path $reportRoot "text-signatures.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Auditing Stadtler master-file structure"

$stadtRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\extracted"
$stadtRows = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $stadtRoot -PathType Container) {
    $indexes = @(Get-ChildItem -LiteralPath $stadtRoot -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue)

    foreach ($idx in $indexes) {
        $dir = $idx.Directory.FullName
        $indexText = ((Get-Content -LiteralPath $idx.FullName -Raw) -replace "\s+"," ").Trim()

        $required = @(
            "AUSLAST.PRN","DIREKT-B.PRN","INDEX.PRN","L0.PRN","LT.PRN",
            "MITT_BED.PRN","P-BEDARF.PRN","PRODKOEF.PRN","RUESTZ.PRN",
            "TBO.PRN","UEBER-KS.PRN","ZFKOEF.PRN"
        )

        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($name in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf)) {
                $missing.Add($name)
            }
        }

        $relDir = $dir.Substring($stadtRoot.Length).TrimStart('\')

        $stadtRows.Add([pscustomobject]@{
            directory = $relDir
            index_values = $indexText
            required_file_count = $required.Count
            missing_count = $missing.Count
            missing_files = ($missing -join ";")
        })
    }
}

$stadtRows |
    Sort-Object directory |
    Export-Csv -LiteralPath (Join-Path $reportRoot "stadtler-master-groups.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Locating Stadtler generation scripts"

$batRows = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $stadtRoot -PathType Container) {
    $bats = @(Get-ChildItem -LiteralPath $stadtRoot -Filter "*.bat" -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($bat in $bats) {
        $content = @(Get-Content -LiteralPath $bat.FullName -ErrorAction SilentlyContinue)
        $params = @($content | Where-Object { $_ -match "%[1-9]" })
        $copies = @($content | Where-Object { $_ -match "(?i)\b(copy|xcopy|ren|rename)\b" })

        $batRows.Add([pscustomobject]@{
            relative_path = $bat.FullName.Substring($stadtRoot.Length).TrimStart('\')
            parameterized_lines = ($params -join " || ")
            copy_rename_lines = ($copies -join " || ")
        })
    }
}

$batRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "stadtler-batch-analysis.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Auditing CLSPL package"

$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\extracted"
$clsRows = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $clsRoot -PathType Container) {
    $dirs = @(Get-ChildItem -LiteralPath $clsRoot -Directory -Recurse -ErrorAction SilentlyContinue)

    foreach ($dir in $dirs) {
        $files = @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { continue }

        $names = @($files | ForEach-Object { $_.Name })
        $rel = $dir.FullName.Substring($clsRoot.Length).TrimStart('\')

        $clsRows.Add([pscustomobject]@{
            directory = $rel
            file_count = $files.Count
            extensions = ((@($files.Extension | Sort-Object -Unique)) -join ";")
            files = ($names -join ";")
        })
    }
}

$clsRows |
    Sort-Object directory |
    Export-Csv -LiteralPath (Join-Path $reportRoot "clspl-directory-groups.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Writing concise console summary"

$stadtFileCount = @($inventory | Where-Object { $_.family_id -eq "STADTLER2003" }).Count
$clsFileCount = @($inventory | Where-Object { $_.family_id -eq "SUERIE_CLSPL" }).Count
$tbFileCount = @($inventory | Where-Object { $_.family_id -eq "TB2009" }).Count
$indexCount = $stadtRows.Count
$batCount = $batRows.Count
$clsGroupCount = $clsRows.Count

$summary = @(
    "# Tempelmeier ecosystem format audit",
    "",
    ("- Stadtler extracted files: " + $stadtFileCount),
    ("- Stadtler INDEX.PRN groups: " + $indexCount),
    ("- Stadtler batch files: " + $batCount),
    ("- CLSPL extracted files: " + $clsFileCount),
    ("- CLSPL non-empty directory groups: " + $clsGroupCount),
    ("- TB2009 extracted files: " + $tbFileCount),
    "",
    "Generated audit files:",
    "- file-inventory.csv",
    "- text-signatures.csv",
    "- stadtler-master-groups.csv",
    "- stadtler-batch-analysis.csv",
    "- clspl-directory-groups.csv"
)

[System.IO.File]::WriteAllLines(
    (Join-Path $reportRoot "README.md"),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ""
Write-Host ("Stadtler extracted files: " + $stadtFileCount)
Write-Host ("Stadtler INDEX.PRN groups: " + $indexCount)
Write-Host ("Stadtler batch files: " + $batCount)
Write-Host ("CLSPL extracted files: " + $clsFileCount)
Write-Host ("CLSPL directory groups: " + $clsGroupCount)
Write-Host ("TB2009 extracted files: " + $tbFileCount)
Write-Host ("Audit directory: " + $reportRoot)
