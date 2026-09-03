param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList
$files = @(
    Get-ChildItem -LiteralPath $PackageRoot -Filter "*.ps1" -File -Recurse
)

$reserved = @(
    "dir","ls","cat","type","copy","cp","move","mv","del",
    "rm","rmdir","echo","where","sort","select","foreach","percent"
)

foreach ($file in $files) {
    $content = [IO.File]::ReadAllText($file.FullName)

    foreach ($ch in $content.ToCharArray()) {
        if ([int][char]$ch -gt 127) {
            [void]$issues.Add($file.FullName + ": non-ASCII content")
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
            [void]$issues.Add(
                $file.FullName + ": parser error: " + $e.Message
            )
        }
    }

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*function\s+(?<name>[A-Za-z_][A-Za-z0-9_-]*)') {
            $name = $Matches["name"].ToLowerInvariant()

            if ($reserved -contains $name) {
                [void]$issues.Add(
                    $file.FullName + ": alias collision: " + $name
                )
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
            [void]$issues.Add(
                $file.FullName + ": unsafe Generic.List @($" + $name + ")"
            )
        }
    }

    if ($content -match '\.Replace\s*\(\s*\[char\]') {
        [void]$issues.Add(
            $file.FullName + ": ambiguous Replace([char],...)"
        )
    }
}

$runner = Join-Path $PackageRoot "tools\Run-Stadtler-Literature-v0.4.3-R2.ps1"

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    [void]$issues.Add("Missing v0.4.3 R2 runner.")
}
else {
    $runnerText = [IO.File]::ReadAllText($runner)

    foreach ($forbidden in @(
        "start_ini.bat",
        "TempelmeierConverter",
        "LotSizingDataModel.Checker.Cli"
    )) {
        if ($runnerText.IndexOf(
            $forbidden,
            [StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
            [void]$issues.Add(
                "Forbidden incremental token: " + $forbidden
            )
        }
    }
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }

    throw "v0.4.3 R2 safety guard failed."
}

Write-Host "PowerShell 5.1 parser: PASS"
Write-Host "ASCII: PASS"
Write-Host "Alias collisions: PASS"
Write-Host "Generic.List: PASS"
Write-Host ".NET overloads: PASS"
Write-Host "No generator/converter/checker rerun: PASS"

& powershell.exe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File $runner `
    -BenchmarkRepo $BenchmarkRepo `
    -DryRun

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.4.3 R2 dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "NonInteractive dry-run: PASS"
