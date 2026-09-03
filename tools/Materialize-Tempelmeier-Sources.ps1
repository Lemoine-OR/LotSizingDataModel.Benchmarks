param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" }
function Ensure-Dir { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

function Expand-RecursiveArchives {
    param(
        [string]$Root,
        [string]$DestinationRoot
    )

    Ensure-Dir $DestinationRoot
    $queue = New-Object System.Collections.Generic.Queue[string]

    Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match "(?i)\.zip$|\.tar$|\.tar\.gz$|\.tgz$|\.tar\.bz2$") {
            $queue.Enqueue($_.FullName)
        }
    }

    $processed = @{}
    $count = 0

    while ($queue.Count -gt 0) {
        $archive = $queue.Dequeue()
        if ($processed.ContainsKey($archive)) { continue }
        $processed[$archive] = $true

        $base = [System.IO.Path]::GetFileName($archive)
        $safe = [regex]::Replace($base, "[^A-Za-z0-9._-]", "-")
        $target = Join-Path $DestinationRoot ($safe + ".extracted")
        Ensure-Dir $target

        try {
            if ($archive -match "(?i)\.zip$") {
                Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
            }
            else {
                $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
                if ($null -eq $tar) {
                    Write-Warning ("tar.exe unavailable for " + $archive)
                    continue
                }
                & tar.exe -xf $archive -C $target
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning ("tar.exe failed for " + $archive)
                    continue
                }
            }

            $count++
            Write-Host ("Expanded: " + $archive)

            Get-ChildItem -LiteralPath $target -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match "(?i)\.zip$|\.tar$|\.tar\.gz$|\.tgz$|\.tar\.bz2$") {
                    if (-not $processed.ContainsKey($_.FullName)) {
                        $queue.Enqueue($_.FullName)
                    }
                }
            }
        }
        catch {
            Write-Warning ("Could not expand " + $archive + ": " + $_.Exception.Message)
        }
    }

    return $count
}

$stadtRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw"
$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw"
$reportRoot = Join-Path $BenchmarkRepo "reports\tempelmeier-materialization"
Ensure-Dir $reportRoot

Write-Step "Recursively expanding Stadtler source archives"
$stadtMaterialized = Join-Path $stadtRoot "materialized"
$stadtExpanded = Expand-RecursiveArchives -Root $stadtRoot -DestinationRoot $stadtMaterialized

Write-Step "Recursively expanding CLSPL source archives"
$clsMaterialized = Join-Path $clsRoot "materialized"
$clsExpanded = Expand-RecursiveArchives -Root $clsRoot -DestinationRoot $clsMaterialized

Write-Step "Inventorying fully materialized sources"

$inventory = New-Object System.Collections.Generic.List[object]

foreach ($familySpec in @(
    [pscustomobject]@{Family="STADTLER2003"; Root=$stadtMaterialized},
    [pscustomobject]@{Family="SUERIE_CLSPL"; Root=$clsMaterialized}
)) {
    if (-not (Test-Path -LiteralPath $familySpec.Root -PathType Container)) { continue }

    Get-ChildItem -LiteralPath $familySpec.Root -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $inventory.Add([pscustomobject]@{
            family_id = $familySpec.Family
            relative_path = $_.FullName.Substring($familySpec.Root.Length).TrimStart('\')
            name = $_.Name
            extension = $_.Extension
            size_bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        })
    }
}

$inventory | Sort-Object family_id,relative_path |
    Export-Csv -LiteralPath (Join-Path $reportRoot "materialized-file-inventory.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Locating Stadtler generation assets"

$stadtScripts = @()
$stadtIndexes = @()
$stadtMasters = @()

if (Test-Path -LiteralPath $stadtMaterialized -PathType Container) {
    $stadtScripts = @(Get-ChildItem -LiteralPath $stadtMaterialized -Filter "start_ini.bat" -File -Recurse -ErrorAction SilentlyContinue)
    $stadtIndexes = @(Get-ChildItem -LiteralPath $stadtMaterialized -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue)

    $masterNames = @(
        "AUSLAST.PRN","DIREKT-B.PRN","L0.PRN","LT.PRN","MITT_BED.PRN",
        "P-BEDARF.PRN","PRODKOEF.PRN","RUESTZ.PRN","TBO.PRN",
        "UEBER-KS.PRN","ZFKOEF.PRN"
    )

    $stadtMasters = @(Get-ChildItem -LiteralPath $stadtMaterialized -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $masterNames -contains $_.Name.ToUpperInvariant() })
}

$scriptRows = New-Object System.Collections.Generic.List[object]
foreach ($script in $stadtScripts) {
    $lines = @(Get-Content -LiteralPath $script.FullName -ErrorAction SilentlyContinue)
    $scriptRows.Add([pscustomobject]@{
        relative_path = $script.FullName.Substring($stadtMaterialized.Length).TrimStart('\')
        line_count = $lines.Count
        environment_lines = (($lines | Where-Object { $_ -match "(?i)^\s*set\s+" }) -join " || ")
        parameter_lines = (($lines | Where-Object { $_ -match "%[1-9]" }) -join " || ")
        copy_lines = (($lines | Where-Object { $_ -match "(?i)\bcopy\b|\bxcopy\b" }) -join " || ")
        rename_lines = (($lines | Where-Object { $_ -match "(?i)\bren\b|\brename\b" }) -join " || ")
    })
}
$scriptRows | Export-Csv -LiteralPath (Join-Path $reportRoot "stadtler-start-ini-analysis.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Classifying CLSPL package files"

$clsRows = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $clsMaterialized -PathType Container) {
    Get-ChildItem -LiteralPath $clsMaterialized -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $kind = "other"
        if ($_.Name -match "(?i)^data") { $kind = "instance-data" }
        if ($_.Name -match "(?i)^sol") { $kind = "solution-or-reference" }
        if ($_.Name -match "(?i)^conv_") { $kind = "lineage-mapping" }
        if ($_.Name -match "(?i)format|descr|readme") { $kind = "documentation" }

        $preview = ""
        if ($_.Extension -match "(?i)\.(txt|dat|csv)$") {
            try {
                $preview = ((Get-Content -LiteralPath $_.FullName -TotalCount 8) -join " || ")
            } catch {}
        }

        $clsRows.Add([pscustomobject]@{
            relative_path = $_.FullName.Substring($clsMaterialized.Length).TrimStart('\')
            file_name = $_.Name
            kind = $kind
            extension = $_.Extension
            preview = $preview
        })
    }
}
$clsRows | Sort-Object relative_path |
    Export-Csv -LiteralPath (Join-Path $reportRoot "clspl-materialized-assets.csv") -NoTypeInformation -Encoding UTF8

Write-Step "Creating conversion-readiness manifest"

$readiness = @(
    [pscustomobject]@{
        family_id="STADTLER2003"
        recursively_expanded_archives=$stadtExpanded
        materialized_files=@($inventory | Where-Object { $_.family_id -eq "STADTLER2003" }).Count
        start_ini_scripts=$stadtScripts.Count
        generated_index_files=$stadtIndexes.Count
        direct_master_prn_files=$stadtMasters.Count
        readiness=$(if ($stadtScripts.Count -gt 0 -or $stadtIndexes.Count -gt 0) { "READY_FOR_EXACT_IMPORTER" } else { "MASTER_FORMAT_STILL_NEEDS_MAPPING" })
    },
    [pscustomobject]@{
        family_id="SUERIE_CLSPL"
        recursively_expanded_archives=$clsExpanded
        materialized_files=@($inventory | Where-Object { $_.family_id -eq "SUERIE_CLSPL" }).Count
        start_ini_scripts=0
        generated_index_files=0
        direct_master_prn_files=0
        readiness=$(if ($clsRows.Count -gt 0) { "READY_FOR_EXACT_IMPORTER" } else { "NO_MATERIALIZED_FILES" })
    }
)

$readiness | Export-Csv -LiteralPath (Join-Path $reportRoot "conversion-readiness.csv") -NoTypeInformation -Encoding UTF8

$summary = @(
    "# Tempelmeier ecosystem source materialization",
    "",
    ("- Stadtler recursively expanded archives: " + $stadtExpanded),
    ("- Stadtler materialized files: " + @($inventory | Where-Object { $_.family_id -eq "STADTLER2003" }).Count),
    ("- Stadtler start_ini.bat scripts: " + $stadtScripts.Count),
    ("- Stadtler INDEX.PRN files already materialized: " + $stadtIndexes.Count),
    ("- Stadtler direct PRN master/final files: " + $stadtMasters.Count),
    ("- CLSPL recursively expanded archives: " + $clsExpanded),
    ("- CLSPL materialized files: " + @($inventory | Where-Object { $_.family_id -eq "SUERIE_CLSPL" }).Count),
    "",
    "This step does not fabricate LotSizingDataModel XML. It determines the exact source representation that the importer must parse."
)

[System.IO.File]::WriteAllLines(
    (Join-Path $reportRoot "README.md"),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ""
Write-Host ("Stadtler recursively expanded archives: " + $stadtExpanded)
Write-Host ("Stadtler materialized files: " + @($inventory | Where-Object { $_.family_id -eq "STADTLER2003" }).Count)
Write-Host ("Stadtler start_ini.bat scripts: " + $stadtScripts.Count)
Write-Host ("Stadtler INDEX.PRN files: " + $stadtIndexes.Count)
Write-Host ("Stadtler PRN master/final files: " + $stadtMasters.Count)
Write-Host ("CLSPL recursively expanded archives: " + $clsExpanded)
Write-Host ("CLSPL materialized files: " + @($inventory | Where-Object { $_.family_id -eq "SUERIE_CLSPL" }).Count)
Write-Host ("Report directory: " + $reportRoot)
