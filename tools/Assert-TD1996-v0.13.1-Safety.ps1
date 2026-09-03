param(
    [string]$PackageRoot,
    [string]$TempDir = "D:\temp",
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$runner = Join-Path $PackageRoot "tools\Run-TD1996-Full-v0.13.1.ps1"
$project = Join-Path $PackageRoot "tools\TD1996Importer\TD1996Importer.csproj"
$program = Join-Path $PackageRoot "tools\TD1996Importer\Program.cs"
$source = Join-Path $TempDir "tempelmeir destroff.zip"

foreach ($required in @($runner,$project,$program,$source)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        [void]$issues.Add("Required file missing: " + $required)
    }
}

foreach ($dir in @($BenchmarkRepo,$ModelRepo)) {
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

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }
    throw "v0.13.1 static safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Required package/source/repository paths: PASS"

Write-Host ""
Write-Host "==> Compile guard: TD1996Importer"

& dotnet build `
    $project `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.13.1 C# compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "C# importer compile guard: PASS"

Write-Host ""
Write-Host "==> Semantic guard: auditing all 3450 source contracts with repaired importer"

$semanticRoot = Join-Path $TempDir (
    "_td1996_semantic_guard_" +
    [Guid]::NewGuid().ToString("N")
)

try {
    $semanticSource = Join-Path $semanticRoot "source"
    $semanticOut = Join-Path $semanticRoot "out"
    $semanticReport = Join-Path $semanticRoot "report"

    New-Item -ItemType Directory -Path $semanticSource -Force | Out-Null
    New-Item -ItemType Directory -Path $semanticOut -Force | Out-Null
    New-Item -ItemType Directory -Path $semanticReport -Force | Out-Null

    Expand-Archive `
        -LiteralPath $source `
        -DestinationPath $semanticSource `
        -Force

    & dotnet run `
        --project $project `
        -c Release `
        --no-build `
        -p:ModelRepo=$ModelRepo `
        -- `
        $semanticSource `
        $semanticOut `
        $semanticReport `
        --audit-only

    if ($LASTEXITCODE -ne 0) {
        throw (
            "v0.13.1 semantic source audit failed with exit code " +
            $LASTEXITCODE
        )
    }

    $semanticManifest = Join-Path $semanticReport `
        "TD1996-CONVERSION-MANIFEST.csv"

    $semanticRows = @(
        Import-Csv -LiteralPath $semanticManifest
    )

    $semanticBad = @(
        $semanticRows |
        Where-Object {
            $_.status -ne "AUDIT_VALID"
        }
    )

    $semanticInferred = (
        $semanticRows |
        Measure-Object `
            -Property inferred_resource_assignments `
            -Sum
    ).Sum

    $semanticDocumented = @(
        $semanticRows |
        Where-Object {
            $_.resource_assignment_evidence -like "DOCUMENTED_TEST_SET_C_*"
        }
    )

    if ($semanticRows.Count -ne 3450 -or
        $semanticBad.Count -ne 0 -or
        $semanticInferred -ne 1200 -or
        $semanticDocumented.Count -ne 1200) {
        throw (
            "v0.13.1 semantic guard postcondition failed: rows=" +
            $semanticRows.Count +
            " bad=" +
            $semanticBad.Count +
            " inferred=" +
            $semanticInferred +
            " documented=" +
            $semanticDocumented.Count
        )
    }

    Write-Host "Full 3450-source semantic audit: PASS"
    Write-Host "Documented item-29 resource reconstructions: 1200 / 1200"
}
finally {
    if (Test-Path -LiteralPath $semanticRoot) {
        Remove-Item `
            -LiteralPath $semanticRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "==> NonInteractive source/cardinality dry-run"

# The runner dry-run validates source cardinality and ecosystem invariants.
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
        "v0.13.1 dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "NonInteractive dry-run: PASS"
