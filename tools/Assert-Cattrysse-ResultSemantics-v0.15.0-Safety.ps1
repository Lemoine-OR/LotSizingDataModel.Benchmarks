param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.ArrayList

$runner = Join-Path $PackageRoot "tools\Run-Cattrysse-ResultSemantics-v0.15.0.ps1"
$project = Join-Path $PackageRoot "tools\CattrysseSemanticReader\CattrysseSemanticReader.csproj"
$program = Join-Path $PackageRoot "tools\CattrysseSemanticReader\Program.cs"

foreach ($required in @($runner,$project,$program)) {
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
    throw "v0.15.0 static safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Required package/repository paths: PASS"

Write-Host ""
Write-Host "==> Compile guard: Cattrysse semantic BIFF5 reader"

& dotnet build `
    $project `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.15.0 semantic reader compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "C# semantic reader compile guard: PASS"

$repoWorkbookRoot = Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990\raw\result-workbooks"

if (-not (Test-Path -LiteralPath $repoWorkbookRoot -PathType Container)) {
    throw "v0.14.1 historical workbook directory is missing."
}

Write-Host ""
Write-Host "==> Real BIFF5 semantic guard"

$tempOut = Join-Path ([IO.Path]::GetTempPath()) (
    "CattrysseV015_" +
    [Guid]::NewGuid().ToString("N")
)

try {
    New-Item -ItemType Directory -Path $tempOut -Force | Out-Null

    & dotnet run `
        --project $project `
        -c Release `
        --no-build `
        -- `
        $repoWorkbookRoot `
        $tempOut

    if ($LASTEXITCODE -ne 0) {
        throw "v0.15.0 semantic workbook guard failed."
    }

    $best = @(
        Import-Csv -LiteralPath (Join-Path $tempOut "CATTRYSSE-BEST-REPORTED-v0.15.0.csv")
    )

    $dev = @(
        Import-Csv -LiteralPath (Join-Path $tempOut "CATTRYSSE-DEVIATIONS-v0.15.0.csv")
    )

    $tim = @(
        Import-Csv -LiteralPath (Join-Path $tempOut "CATTRYSSE-TIMINGS-v0.15.0.csv")
    )

    if ($best.Count -ne 120 -or
        @($best | Select-Object -ExpandProperty instance_id -Unique).Count -ne 120 -or
        $dev.Count -le 0 -or
        $tim.Count -le 0) {
        throw "v0.15.0 semantic guard postcondition failed."
    }

    Write-Host "Workbook reference MIN checks: 120 / 120 PASS"
    Write-Host ("Deviation formula cells      : " + $dev.Count)
    Write-Host ("Timing cells classified      : " + $tim.Count)
}
finally {
    if (Test-Path -LiteralPath $tempOut) {
        Remove-Item -LiteralPath $tempOut -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "==> Full noninteractive semantic dry-run"

$readerDestination = Join-Path $BenchmarkRepo "tools\CattrysseSemanticReader"
$createdDestination = $false

if (-not (Test-Path -LiteralPath $readerDestination -PathType Container)) {
    New-Item -ItemType Directory -Path $readerDestination -Force | Out-Null
    $createdDestination = $true
}

try {
    Copy-Item `
        -Path (Join-Path $PackageRoot "tools\CattrysseSemanticReader\*") `
        -Destination $readerDestination `
        -Recurse `
        -Force

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
            "v0.15.0 semantic dry-run failed with exit code " +
            $LASTEXITCODE
        )
    }
}
finally {
    if ($createdDestination -and (Test-Path -LiteralPath $readerDestination)) {
        Remove-Item -LiteralPath $readerDestination -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "NonInteractive semantic dry-run: PASS"
