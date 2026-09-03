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

function Copy-DirectoryContent {
    param([string]$Source,[string]$Destination)
    Ensure-Dir $Destination
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Normalize-Id {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $v = $Value.ToLowerInvariant()
    $v = [regex]::Replace($v, "\.[a-z0-9]+$", "")
    $v = [regex]::Replace($v, "[^a-z0-9]", "")
    return $v
}

$reportRoot = Join-Path $BenchmarkRepo "reports\v0.3.5"
Ensure-Dir $reportRoot

# ============================================================
# A. STADTLER MATERIALIZATION FROM OFFICIAL BATCH INVOCATIONS
# ============================================================
Write-Step "Discovering official Stadtler start_ini invocations"

$stadtRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\materialized"
$stadtGenerated = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\generated-v0.3.5"
Ensure-Dir $stadtGenerated

$startScripts = @()
if (Test-Path -LiteralPath $stadtRoot -PathType Container) {
    $startScripts = @(Get-ChildItem -LiteralPath $stadtRoot -Filter "start_ini.bat" -File -Recurse -ErrorAction SilentlyContinue)
}

$invocationRows = New-Object System.Collections.Generic.List[object]
$executed = 0
$failedExec = 0

foreach ($start in $startScripts) {
    $sourceDir = $start.Directory.FullName

    # Only trust explicit invocations found in official .bat/.cmd files.
    $allScripts = @(Get-ChildItem -LiteralPath $sourceDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match "(?i)\.(bat|cmd)$" })

    $calls = New-Object System.Collections.Generic.List[string]

    foreach ($script in $allScripts) {
        foreach ($line in Get-Content -LiteralPath $script.FullName -ErrorAction SilentlyContinue) {
            $trim = $line.Trim()
            if ($trim.StartsWith("REM",[System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($trim.StartsWith("::")) { continue }

            if ($trim -match "(?i)(?:call\s+)?(?:\.\\)?start_ini\.bat\s+(?<args>.+)$") {
                $args = $Matches["args"].Trim()
                if ($args -notmatch "%[1-9]") {
                    $calls.Add($args)
                    $invocationRows.Add([pscustomobject]@{
                        start_ini = $start.FullName
                        discovered_in = $script.FullName
                        arguments = $args
                        status = "DISCOVERED_EXPLICIT_INVOCATION"
                    })
                }
            }
        }
    }

    # Deduplicate exact official invocations.
    $uniqueCalls = @($calls | Sort-Object -Unique)

    foreach ($args in $uniqueCalls) {
        $hash = [Math]::Abs($args.GetHashCode()).ToString()
        $target = Join-Path $stadtGenerated ((Split-Path -Leaf $sourceDir) + "_" + $hash)

        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Ensure-Dir $target

        # Execute only on an isolated copy.
        Copy-DirectoryContent -Source $sourceDir -Destination $target

        $targetStart = Join-Path $target "start_ini.bat"
        if (-not (Test-Path -LiteralPath $targetStart -PathType Leaf)) {
            continue
        }

        Write-Host ("Official invocation: " + $targetStart + " " + $args)

        Push-Location $target
        try {
            $cmdLine = '/d /c ""' + $targetStart + '" ' + $args + '"'
            & cmd.exe $cmdLine
            $code = $LASTEXITCODE

            if ($code -eq 0) {
                $executed++
                $status = "EXECUTED_OK"
            }
            else {
                $failedExec++
                $status = "EXECUTION_FAILED_" + $code
            }

            $invocationRows.Add([pscustomobject]@{
                start_ini = $targetStart
                discovered_in = "isolated-copy"
                arguments = $args
                status = $status
            })
        }
        finally {
            Pop-Location
        }
    }
}

$invocationRows |
    Export-Csv -LiteralPath (Join-Path $reportRoot "stadtler-official-invocations.csv") -NoTypeInformation -Encoding UTF8

$generatedIndex = @()
if (Test-Path -LiteralPath $stadtGenerated -PathType Container) {
    $generatedIndex = @(Get-ChildItem -LiteralPath $stadtGenerated -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue)
}

Write-Host ("start_ini scripts: " + $startScripts.Count)
Write-Host ("explicit official invocations found: " + @($invocationRows | Where-Object { $_.status -eq "DISCOVERED_EXPLICIT_INVOCATION" }).Count)
Write-Host ("official invocations executed: " + $executed)
Write-Host ("official invocations failed: " + $failedExec)
Write-Host ("generated INDEX.PRN files: " + $generatedIndex.Count)

# ============================================================
# B. RE-RUN STADTLER CONVERTER ON GENERATED FILES
# ============================================================
Write-Step "Re-running Stadtler converter on generated source instances"

$converterProject = Join-Path $BenchmarkRepo "tools\TempelmeierConverter\TempelmeierConverter.csproj"
$stadtOut = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\instances"
Ensure-Dir $stadtOut

if (Test-Path -LiteralPath $converterProject -PathType Leaf) {
    & dotnet build $converterProject -c Release --nologo -p:ModelRepo=$ModelRepo
    if ($LASTEXITCODE -ne 0) {
        throw "Existing TempelmeierConverter build failed."
    }

    $stadtLog = @(
        & dotnet run --project $converterProject -c Release --no-build -p:ModelRepo=$ModelRepo -- stadtler $stadtGenerated $stadtOut 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    [System.IO.File]::WriteAllLines(
        (Join-Path $reportRoot "stadtler-conversion-v0.3.5.log"),
        $stadtLog,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $stadtLog | ForEach-Object { Write-Host $_ }
}
else {
    Write-Warning "TempelmeierConverter is not installed; v0.3.3 must be installed first."
}

$stadtXmlCount = @(Get-ChildItem -LiteralPath $stadtOut -Filter "*.xml" -File -ErrorAction SilentlyContinue).Count

# ============================================================
# C. CLSPL XLS REFERENCE EXTRACTION
# ============================================================
Write-Step "Reading CLSPL reference workbooks"

$xlsReader = Join-Path $BenchmarkRepo "tools\ClsplReferenceReader\ClsplReferenceReader.csproj"
if (-not (Test-Path -LiteralPath $xlsReader -PathType Leaf)) {
    throw "CLSPL reference reader project missing."
}

& dotnet build $xlsReader -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    throw "CLSPL reference reader build failed."
}

$clsRaw = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\materialized"
$referenceRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\literature"
Ensure-Dir $referenceRoot

$books = @()
if (Test-Path -LiteralPath $clsRaw -PathType Container) {
    $books = @(Get-ChildItem -LiteralPath $clsRaw -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)^sol(m|b)?\.xls$" } |
        Sort-Object FullName -Unique)
}

foreach ($book in $books) {
    Write-Host ("Reading " + $book.FullName)
    & dotnet run --project $xlsReader -c Release --no-build -- $book.FullName $referenceRoot
    if ($LASTEXITCODE -ne 0) {
        throw ("Could not read workbook: " + $book.FullName)
    }
}

# ============================================================
# D. MAP RESOLVED REFERENCES TO 1291 CLSPL XML
# ============================================================
Write-Step "Mapping resolved CLSPL references to converted XML"

$clsXmlRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\instances"
$xmlFiles = @(Get-ChildItem -LiteralPath $clsXmlRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue)

$xmlIndex = @{}
foreach ($xml in $xmlFiles) {
    $normalizedFile = Normalize-Id -Value $xml.BaseName
    if (-not $xmlIndex.ContainsKey($normalizedFile)) {
        $xmlIndex[$normalizedFile] = $xml
    }
}

$resolvedCsvs = @(Get-ChildItem -LiteralPath $referenceRoot -Filter "*-resolved-references.csv" -File -ErrorAction SilentlyContinue)
$mapped = New-Object System.Collections.Generic.List[object]
$unmapped = New-Object System.Collections.Generic.List[object]

foreach ($csv in $resolvedCsvs) {
    $set = "unknown"
    if ($csv.Name -match "(?i)^solb-") { $set = "datab" }
    elseif ($csv.Name -match "(?i)^solm-") { $set = "datam" }
    elseif ($csv.Name -match "(?i)^sol-") { $set = "data" }

    foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
        $key = Normalize-Id -Value $row.source_instance_id

        $candidates = @($xmlFiles | Where-Object {
            $n = Normalize-Id -Value $_.BaseName
            $n.Contains($key) -or $key.Contains($n)
        })

        if ($candidates.Count -eq 1) {
            $mapped.Add([pscustomobject]@{
                test_set = $set
                source_instance_id = $row.source_instance_id
                lsdm_filename = $candidates[0].Name
                objective = $row.objective
                lower_bound = $row.lower_bound
                objective_status = $(if ([string]::IsNullOrWhiteSpace($row.objective)) { "" } else { "LITERATURE_BEST_KNOWN" })
                lower_bound_status = $(if ([string]::IsNullOrWhiteSpace($row.lower_bound)) { "" } else { "LITERATURE_LOWER_BOUND" })
                verified = "False"
                source_workbook = $row.workbook
                source_sheet = $row.sheet
                resolution_evidence = $row.resolution_evidence
            })
        }
        else {
            $unmapped.Add([pscustomobject]@{
                test_set = $set
                source_instance_id = $row.source_instance_id
                objective = $row.objective
                lower_bound = $row.lower_bound
                candidate_xml_count = $candidates.Count
                status = "UNMAPPED_OR_AMBIGUOUS"
            })
        }
    }
}

$metadataRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\metadata"
Ensure-Dir $metadataRoot

$mapped | Export-Csv -LiteralPath (Join-Path $metadataRoot "CLSPL-LITERATURE-REFERENCES.csv") -NoTypeInformation -Encoding UTF8
$unmapped | Export-Csv -LiteralPath (Join-Path $metadataRoot "CLSPL-LITERATURE-UNMAPPED.csv") -NoTypeInformation -Encoding UTF8

# ============================================================
# E. BUILD INSTANCES-WITH-REFERENCE WITHOUT FAKING KNOWNRESULT
# ============================================================
Write-Step "Creating reference-sidecar instances and GitHub pages"

$withRef = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\instances-with-reference"
Ensure-Dir $withRef

foreach ($xml in $xmlFiles) {
    Copy-Item -LiteralPath $xml.FullName -Destination (Join-Path $withRef $xml.Name) -Force
}

# Because these are value-only literature records, keep them as sidecar metadata.
# Do NOT inject a knownResult node claiming a verified solution.

$readme = New-Object System.Collections.Generic.List[string]
$readme.Add("# Suerie-Stadtler CLSPL benchmark")
$readme.Add("")
$readme.Add("> Converted to LotSizingDataModel XML. Published reference values are kept as literature evidence unless a complete solution is independently checked.")
$readme.Add("")
$readme.Add("| Metric | Count |")
$readme.Add("|---|---:|")
$readme.Add("| Converted LSDM instances | **$($xmlFiles.Count)** |")
$readme.Add("| Resolved literature rows | **$($mapped.Count)** |")
$readme.Add("| Unmapped/ambiguous literature rows | **$($unmapped.Count)** |")
$readme.Add("")
$readme.Add("Reference values are stored in `metadata/CLSPL-LITERATURE-REFERENCES.csv`.")
$readme.Add("")
$readme.Add("Statuses `LITERATURE_BEST_KNOWN` and `LITERATURE_LOWER_BOUND` are **not** equivalent to verified solutions.")

[System.IO.File]::WriteAllLines(
    (Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\README.md"),
    $readme,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "v0.3.5 summary"
Write-Host ("STADTLER2003 XML: " + $stadtXmlCount)
Write-Host ("SUERIE_CLSPL XML: " + $xmlFiles.Count)
Write-Host ("CLSPL resolved literature rows: " + $mapped.Count)
Write-Host ("CLSPL unmapped/ambiguous rows: " + $unmapped.Count)
Write-Host ("Reports: " + $reportRoot)
