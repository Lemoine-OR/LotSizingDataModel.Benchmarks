param(
    [string]$PackageRoot,
    [string]$TempDir = "D:\temp",
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$runner = Join-Path $PackageRoot "tools\Run-Cattrysse-Full-v0.14.1.ps1"
$importerProject = Join-Path $PackageRoot "tools\CattrysseImporter\CattrysseImporter.csproj"
$resultProject = Join-Path $PackageRoot "tools\CattrysseResultReader\CattrysseResultReader.csproj"
$sourceArchive = Join-Path $TempDir "Cattrysse.zip"
$bundledSource = Join-Path $PackageRoot "source\CATTRYSSE"

foreach ($required in @(
    $runner,
    $importerProject,
    $resultProject,
    $sourceArchive,
    (Join-Path $bundledSource "note")
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        [void]$issues.Add("Required file missing: " + $required)
    }
}

foreach ($dir in @(
    $BenchmarkRepo,
    $ModelRepo,
    (Join-Path $bundledSource "original-tests"),
    (Join-Path $bundledSource "result-workbooks")
)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void]$issues.Add("Required directory missing: " + $dir)
    }
}

$psFiles = @(
    Get-ChildItem -LiteralPath $PackageRoot -Filter "*.ps1" -File -Recurse
)

$reserved = @(
    "dir","ls","cat","type","copy","cp","move","mv","del","rm",
    "rmdir","echo","where","sort","select","foreach","percent"
)

foreach ($file in $psFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)

    foreach ($ch in $content.ToCharArray()) {
        if ([int][char]$ch -gt 127) {
            [void]$issues.Add($file.FullName + ": non-ASCII PowerShell content")
            break
        }
    }

    $tokens = $null
    $parseErrors = $null

    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        foreach ($e in $parseErrors) {
            [void]$issues.Add($file.FullName + ": parser error: " + $e.Message)
        }
    }

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*function\s+(?<name>[A-Za-z_][A-Za-z0-9_-]*)') {
            $name = $Matches["name"].ToLowerInvariant()
            if ($reserved -contains $name) {
                [void]$issues.Add($file.FullName + ": alias collision " + $name)
            }
        }
    }

    $genericNames = @()

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*New-Object\s+System\.Collections\.Generic\.List') {
            $genericNames += $Matches["name"]
        }
    }

    foreach ($name in $genericNames) {
        $pattern = '@\(\$' + [regex]::Escape($name) + '\)'
        if ([regex]::IsMatch($content,$pattern)) {
            [void]$issues.Add($file.FullName + ": unsafe Generic.List wrapper")
        }
    }

    if ($content -match '\.Replace\s*\(\s*\[char\]') {
        [void]$issues.Add($file.FullName + ": ambiguous String.Replace overload")
    }
}

$bundledTests = @(
    Get-ChildItem -LiteralPath (Join-Path $bundledSource "original-tests") -Filter "TEST*" -File -Recurse
)

$bundledBooks = @(
    Get-ChildItem -LiteralPath (Join-Path $bundledSource "result-workbooks") -Filter "*.xls" -File
)

if ($bundledTests.Count -ne 120) {
    [void]$issues.Add("Bundled original TEST cardinality is not 120.")
}

if ($bundledBooks.Count -ne 3) {
    [void]$issues.Add("Bundled result workbook cardinality is not 3.")
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }
    throw "v0.14.1 static safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Bundled source cardinality: PASS"
Write-Host "Required package/source/repository paths: PASS"

Write-Host ""
Write-Host "==> Compile guard: Cattrysse importer"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.14.1 Cattrysse importer compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "C# importer compile guard: PASS"

Write-Host ""
Write-Host "==> Compile guard: historical XLS result reader"

& dotnet build `
    $resultProject `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.14.1 result reader compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "ExcelDataReader BIFF5 result-reader compile guard: PASS"

Write-Host ""
Write-Host "==> Semantic guard: all 120 original TEST files"

$semanticRoot = Join-Path $TempDir (
    "_cattrysse_semantic_guard_" +
    [Guid]::NewGuid().ToString("N")
)

try {
    $out = Join-Path $semanticRoot "out"
    $rep = Join-Path $semanticRoot "report"
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    New-Item -ItemType Directory -Path $rep -Force | Out-Null

    & dotnet run `
        --project $importerProject `
        -c Release `
        --no-build `
        -p:ModelRepo=$ModelRepo `
        -- `
        (Join-Path $bundledSource "original-tests") `
        $out `
        $rep `
        --audit-only

    if ($LASTEXITCODE -ne 0) {
        throw "Cattrysse 120-source semantic audit failed."
    }

    $rows = @(
        Import-Csv -LiteralPath (Join-Path $rep "CATTRYSSE-CONVERSION-MANIFEST.csv")
    )

    if ($rows.Count -ne 120 -or
        @($rows | Where-Object { $_.status -ne "AUDIT_VALID" }).Count -ne 0 -or
        @($rows | Where-Object { $_.class_id -eq "CAT-SET1-50x8" }).Count -ne 40 -or
        @($rows | Where-Object { $_.class_id -eq "CAT-SET2-20x20" }).Count -ne 40 -or
        @($rows | Where-Object { $_.class_id -eq "CAT-SET3-8x50" }).Count -ne 40) {
        throw "Cattrysse semantic audit postcondition failed."
    }

    Write-Host "Full 120-source semantic audit: PASS"
}
finally {
    if (Test-Path -LiteralPath $semanticRoot) {
        Remove-Item -LiteralPath $semanticRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "==> Historical workbook guard: 3 BIFF5 files / 120 TEST identities"

$bookRoot = Join-Path $TempDir (
    "_cattrysse_workbook_guard_" +
    [Guid]::NewGuid().ToString("N")
)

try {
    New-Item -ItemType Directory -Path $bookRoot -Force | Out-Null

    & dotnet run `
        --project $resultProject `
        -c Release `
        --no-build `
        -- `
        (Join-Path $bundledSource "result-workbooks") `
        $bookRoot

    if ($LASTEXITCODE -ne 0) {
        throw "Cattrysse workbook semantic guard failed."
    }

    $evidence = @(
        Import-Csv -LiteralPath (Join-Path $bookRoot "CATTRYSSE-RESULT-EVIDENCE.csv")
    )

    if (@($evidence | Select-Object -ExpandProperty instance_id -Unique).Count -ne 120) {
        throw "Cattrysse workbook guard does not cover TEST1..TEST120."
    }

    Write-Host "Excel result workbook identity coverage: 120 / 120 PASS"
}
finally {
    if (Test-Path -LiteralPath $bookRoot) {
        Remove-Item -LiteralPath $bookRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "==> NonInteractive integration dry-run"

# The runner checks exact user archive SHA and all ecosystem invariants.
$repoBundled = Join-Path $BenchmarkRepo "tools\CattrysseBundledSource"
$createdRepoBundled = $false

if (-not (Test-Path -LiteralPath $repoBundled -PathType Container)) {
    New-Item -ItemType Directory -Path $repoBundled -Force | Out-Null
    $createdRepoBundled = $true
}

try {
    Copy-Item -Path (Join-Path $bundledSource "*") -Destination $repoBundled -Recurse -Force

    & powershell.exe `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $runner `
        -TempDir $TempDir `
        -BenchmarkRepo $BenchmarkRepo `
        -ModelRepo $ModelRepo `
        -DryRun

    if ($LASTEXITCODE -ne 0) {
        throw (
            "v0.14.1 non-interactive dry-run failed with exit code " +
            $LASTEXITCODE
        )
    }
}
finally {
    if ($createdRepoBundled -and (Test-Path -LiteralPath $repoBundled)) {
        Remove-Item -LiteralPath $repoBundled -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "NonInteractive dry-run: PASS"
