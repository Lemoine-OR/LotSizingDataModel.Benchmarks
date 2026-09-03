param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$psFiles = @(
    Get-ChildItem `
        -LiteralPath $PackageRoot `
        -Filter "*.ps1" `
        -File `
        -Recurse
)

$reservedAliases = @(
    "dir","ls","cat","type","copy","cp","move","mv","del","rm",
    "rmdir","echo","where","sort","select","foreach","percent"
)

foreach ($file in $psFiles) {
    $content = [System.IO.File]::ReadAllText(
        $file.FullName
    )

    foreach ($character in $content.ToCharArray()) {
        if ([int][char]$character -gt 127) {
            [void]$issues.Add(
                $file.FullName +
                ": non-ASCII PowerShell content"
            )
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
            $functionName = $Matches["name"].ToLowerInvariant()

            if ($reservedAliases -contains $functionName) {
                [void]$issues.Add(
                    $file.FullName +
                    ": function collides with PowerShell alias: " +
                    $functionName
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
            ": ambiguous .NET Replace([char],...) overload"
        )
    }
}

$runner = Join-Path $PackageRoot `
    "tools\Run-Stadtler-Literature-v0.4.3.ps1"

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    [void]$issues.Add("Missing v0.4.3 runner.")
}
else {
    $runnerText = [System.IO.File]::ReadAllText($runner)

    foreach ($forbidden in @(
        "start_ini.bat",
        "TempelmeierConverter",
        "LotSizingDataModel.Checker.Cli"
    )) {
        if ($runnerText.IndexOf(
            $forbidden,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
            [void]$issues.Add(
                "Incremental runner contains forbidden token: " +
                $forbidden
            )
        }
    }
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }

    throw "v0.4.3 safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "No-generator guard: PASS"
Write-Host "No-converter guard: PASS"
Write-Host "No-checker-rerun guard: PASS"

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
        "v0.4.3 non-interactive dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "Corpus/literature dry-run: PASS"
