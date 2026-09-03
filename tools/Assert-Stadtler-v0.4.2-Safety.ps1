param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    throw "PackageRoot is required."
}

$issues = New-Object System.Collections.ArrayList

$psFiles = @(
    Get-ChildItem -LiteralPath $PackageRoot -Filter "*.ps1" -File -Recurse
)

$reservedAliases = @(
    "dir","ls","cat","type","copy","cp","move","mv","del","rm",
    "rmdir","echo","where","sort","select","foreach","percent"
)

foreach ($file in $psFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName)

    foreach ($ch in $content.ToCharArray()) {
        if ([int][char]$ch -gt 127) {
            [void]$issues.Add($file.FullName + ": non-ASCII PowerShell content")
            break
        }
    }

    $tokens = $null
    $parseErrors = $null

    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            [void]$issues.Add(
                $file.FullName +
                ": parser error: " +
                $parseError.Message
            )
        }
    }

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*function\s+(?<name>[A-Za-z_][A-Za-z0-9_-]*)') {
            $name = $Matches["name"].ToLowerInvariant()

            if ($reservedAliases -contains $name) {
                [void]$issues.Add(
                    $file.FullName +
                    ": helper collides with PowerShell alias: " +
                    $name
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

        if ([regex]::IsMatch($content, $pattern)) {
            [void]$issues.Add(
                $file.FullName +
                ": unsafe Generic.List wrapper @($" +
                $name +
                ")"
            )
        }
    }

    if ($content -match '\.Replace\s*\(\s*\[char\]') {
        [void]$issues.Add(
            $file.FullName +
            ": ambiguous String.Replace overload using [char]"
        )
    }
}

$runner = Join-Path $PackageRoot "tools\Run-Stadtler-Stabilization-v0.4.2.ps1"

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    [void]$issues.Add("Missing v0.4.2 runner.")
}
else {
    $runnerText = [System.IO.File]::ReadAllText($runner)

    $forbidden = @(
        "start_ini.bat",
        "TempelmeierConverter",
        "LotSizingDataModel.Checker.Cli"
    )

    foreach ($term in $forbidden) {
        if ($runnerText.IndexOf(
            $term,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
            [void]$issues.Add(
                "Runner contains forbidden incremental operation token: " +
                $term
            )
        }
    }
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }

    throw "v0.4.2 safety harness failed."
}

Write-Host ("PowerShell parser guard: PASS (" + $psFiles.Count + " files)")
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "No-generator guard: PASS"
Write-Host "No-converter guard: PASS"
Write-Host "No-checker-rerun guard: PASS"

# Run a non-destructive dry-run through a separate non-interactive PowerShell process.
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
        "v0.4.2 non-interactive dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "NonInteractive dry-run: PASS"
