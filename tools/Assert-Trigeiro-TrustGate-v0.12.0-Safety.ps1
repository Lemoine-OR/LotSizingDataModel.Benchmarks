param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$runner = Join-Path $PackageRoot "tools\Run-Trigeiro-TrustGate-v0.12.0.ps1"
$seed = Join-Path $PackageRoot "catalog\TRIGEIRO1989-LITERATURE-SEED-v0.12.0.csv"

foreach ($required in @($runner,$seed)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        [void]$issues.Add("Required package file missing: " + $required)
    }
}

foreach ($dir in @($BenchmarkRepo,$ModelRepo)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void]$issues.Add("Required repository missing: " + $dir)
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
    throw "v0.12.0 static safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Required package/repository paths: PASS"

Write-Host ""
Write-Host "==> NonInteractive trust-gate dry-run"

# Install seed temporarily before dry-run expects it in repo catalog.
$catalogDir = Join-Path $BenchmarkRepo "catalog"
if (-not (Test-Path -LiteralPath $catalogDir -PathType Container)) {
    New-Item -ItemType Directory -Path $catalogDir -Force | Out-Null
}

$seedDestination = Join-Path $catalogDir "TRIGEIRO1989-LITERATURE-SEED-v0.12.0.csv"
Copy-Item -LiteralPath $seed -Destination $seedDestination -Force

& powershell.exe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File $runner `
    -BenchmarkRepo $BenchmarkRepo `
    -ModelRepo $ModelRepo `
    -DryRun

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.12.0 non-interactive dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "NonInteractive dry-run: PASS"
