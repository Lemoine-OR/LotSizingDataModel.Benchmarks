param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$runner = Join-Path $PackageRoot `
    "tools\Run-Trigeiro-Full-v0.9.0.ps1"

$importerProject = Join-Path $PackageRoot `
    "tools\TrigeiroImporter\TrigeiroImporter.csproj"

$importerProgram = Join-Path $PackageRoot `
    "tools\TrigeiroImporter\Program.cs"

$requiredFiles = @(
    $runner,
    $importerProject,
    $importerProgram
)

foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        [void]$issues.Add(
            "Required package file missing: " +
            $requiredFile
        )
    }
}

if (-not (Test-Path -LiteralPath $BenchmarkRepo -PathType Container)) {
    [void]$issues.Add(
        "Benchmark repository missing: " +
        $BenchmarkRepo
    )
}

if (-not (Test-Path -LiteralPath $ModelRepo -PathType Container)) {
    [void]$issues.Add(
        "LotSizingDataModel repository missing: " +
        $ModelRepo
    )
}

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
    $content = [IO.File]::ReadAllText($file.FullName)

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

    [void][Management.Automation.Language.Parser]::ParseFile(
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

        if ([regex]::IsMatch($content,$pattern)) {
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

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }

    throw "v0.9.0-R2 safety harness failed before compilation."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Required package files: PASS"
Write-Host "Repository path guards: PASS"

Write-Host ""
Write-Host "==> Compile guard: building dedicated Trigeiro importer"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.9.0-R2 C# compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "C# importer compile guard: PASS"

Write-Host ""
Write-Host "==> NonInteractive integration dry-run"

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
        "v0.9.0-R2 non-interactive dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "NonInteractive dry-run: PASS"
