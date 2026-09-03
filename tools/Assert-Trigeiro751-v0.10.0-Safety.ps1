param(
    [string]$PackageRoot,
    [string]$TempDir = "D:\temp",
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$runner = Join-Path $PackageRoot `
    "tools\Run-Trigeiro751-v0.10.0.ps1"

$importerProject = Join-Path $PackageRoot `
    "tools\TrigeiroDualImporter\TrigeiroDualImporter.csproj"

$importerProgram = Join-Path $PackageRoot `
    "tools\TrigeiroDualImporter\Program.cs"

$sourceArchive = Join-Path $TempDir "E1.zip"

foreach ($required in @(
    $runner,
    $importerProject,
    $importerProgram,
    $sourceArchive
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        [void]$issues.Add(
            "Required file missing: " +
            $required
        )
    }
}

foreach ($requiredDir in @(
    $BenchmarkRepo,
    $ModelRepo
)) {
    if (-not (Test-Path -LiteralPath $requiredDir -PathType Container)) {
        [void]$issues.Add(
            "Required directory missing: " +
            $requiredDir
        )
    }
}

$psFiles = @(
    Get-ChildItem `
        -LiteralPath $PackageRoot `
        -Filter "*.ps1" `
        -File `
        -Recurse
)

$reserved = @(
    "dir","ls","cat","type","copy","cp","move","mv","del","rm",
    "rmdir","echo","where","sort","select","foreach","percent"
)

foreach ($file in $psFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)

    foreach ($ch in $content.ToCharArray()) {
        if ([int][char]$ch -gt 127) {
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
        foreach ($e in $parseErrors) {
            [void]$issues.Add(
                $file.FullName +
                ": parser error: " +
                $e.Message
            )
        }
    }

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*function\s+(?<name>[A-Za-z_][A-Za-z0-9_-]*)') {
            $name = $Matches["name"].ToLowerInvariant()

            if ($reserved -contains $name) {
                [void]$issues.Add(
                    $file.FullName +
                    ": alias collision " +
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
                ": unsafe Generic.List wrapper"
            )
        }
    }

    if ($content -match '\.Replace\s*\(\s*\[char\]') {
        [void]$issues.Add(
            $file.FullName +
            ": ambiguous String.Replace overload"
        )
    }
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }

    throw "v0.10.0 static safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Required files/directories: PASS"

Write-Host ""
Write-Host "==> Compile guard: TrigeiroDualImporter"

& dotnet build `
    $importerProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.10.0 C# compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "C# dual importer compile guard: PASS"

Write-Host ""
Write-Host "==> NonInteractive dual-corpus dry-run"

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
        "v0.10.0 dry-run failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "NonInteractive dry-run: PASS"
