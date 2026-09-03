param(
    [string]$PackageRoot,
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$issues =
    New-Object System.Collections.ArrayList

$runner =
    Join-Path $PackageRoot `
        "tools\Run-Global-Benchmark-Registry-v0.16.4.ps1"

$validatorProject =
    Join-Path $PackageRoot `
        "tools\GlobalRegistryValidator\GlobalRegistryValidator.csproj"

$validatorProgram =
    Join-Path $PackageRoot `
        "tools\GlobalRegistryValidator\Program.cs"

$sharedResolver =
    Join-Path $PackageRoot `
        "tools\CanonicalCorpus-v0.16.4.ps1"

foreach ($required in @(
    $runner,
    $validatorProject,
    $validatorProgram,
    $sharedResolver
)) {
    if (-not (
        Test-Path `
            -LiteralPath $required `
            -PathType Leaf
    )) {
        [void]$issues.Add(
            "Required package file missing: " +
            $required
        )
    }
}

foreach ($directory in @(
    $BenchmarkRepo,
    $ModelRepo
)) {
    if (-not (
        Test-Path `
            -LiteralPath $directory `
            -PathType Container
    )) {
        [void]$issues.Add(
            "Required repository missing: " +
            $directory
        )
    }
}

$psFiles =
    @(
        Get-ChildItem `
            -LiteralPath $PackageRoot `
            -Filter "*.ps1" `
            -File `
            -Recurse
    )

$reserved = @(
    "dir","ls","cat","type","copy","cp",
    "move","mv","del","rm","rmdir","echo",
    "where","sort","select","foreach","percent"
)

foreach ($file in $psFiles) {
    $content =
        [IO.File]::ReadAllText(
            $file.FullName
        )

    foreach ($ch in $content.ToCharArray()) {
        if (
            [int][char]$ch -gt 127
        ) {
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
        foreach ($errorItem in $parseErrors) {
            [void]$issues.Add(
                $file.FullName +
                ": parser error: " +
                $errorItem.Message
            )
        }
    }

    foreach ($line in ($content -split "`r?`n")) {
        if (
            $line -match
            '^\s*function\s+(?<name>[A-Za-z_][A-Za-z0-9_-]*)'
        ) {
            $matchedName =
                $Matches["name"]

            $name =
                $matchedName.ToLowerInvariant()

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
        if (
            $line -match
            '^\s*\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*New-Object\s+System\.Collections\.Generic\.List'
        ) {
            $genericNames +=
                $Matches["name"]
        }
    }

    foreach ($name in $genericNames) {
        $pattern =
            '@\(\$' +
            [regex]::Escape($name) +
            '\)'

        if (
            [regex]::IsMatch(
                $content,
                $pattern
            )
        ) {
            [void]$issues.Add(
                $file.FullName +
                ": unsafe Generic.List wrapper"
            )
        }
    }

    if (
        $content -match
        '\.Replace\s*\(\s*\[char\]'
    ) {
        [void]$issues.Add(
            $file.FullName +
            ": ambiguous String.Replace overload"
        )
    }

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*Join-Path\s+[^#]*,\s*$') {
            [void]$issues.Add(
                $file.FullName +
                ": unsafe Join-Path command followed by comma; precompute each path before building arrays"
            )
        }
    }
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error $issue
    }

    throw "v0.16.4 static safety harness failed."
}

Write-Host "PowerShell 5.1 parser guard: PASS"
Write-Host "ASCII guard: PASS"
Write-Host "Alias collision guard: PASS"
Write-Host "Generic.List guard: PASS"
Write-Host ".NET overload guard: PASS"
Write-Host "Required package/repository paths: PASS"

. $sharedResolver

Write-Host ""
Write-Host "==> Compile guard: GlobalRegistryValidator"

& dotnet build `
    $validatorProject `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw (
        "v0.16.4 validator compile guard failed with exit code " +
        $LASTEXITCODE
    )
}

Write-Host "C# validator compile guard: PASS"

$runnerText =
    [IO.File]::ReadAllText(
        $runner
    )

if (
    $runnerText -notmatch
    '\$family\.family\s*\+\s*"\:\:"\s*\+\s*\$subfamily\s*\+\s*"\:\:"\s*\+\s*\$originalId'
) {
    throw "Subfamily-qualified global ID rule is missing."
}

if (
    $runnerText -match
    '-Candidates\s*@\(\s*\(Join-Path'
) {
    throw (
        "PowerShell 5.1 Join-Path array-binding hazard detected. " +
        "Candidate paths must be pre-computed as scalar variables."
    )
}

Write-Host "Subfamily-qualified global ID rule: PASS"
Write-Host "Join-Path candidate-array runtime guard: PASS"

Write-Host ""
Write-Host "==> Semantic preflight: explicit canonical family roots"

$expected = @(
    [pscustomobject]@{
        family = "DJ2000"
        count = 176
    },
    [pscustomobject]@{
        family = "STADTLER2003"
        count = 2100
    },
    [pscustomobject]@{
        family = "SUERIE_CLSPL"
        count = 1291
    },
    [pscustomobject]@{
        family = "TRIGEIRO1989"
        count = 751
    },
    [pscustomobject]@{
        family = "TD1996"
        count = 3450
    },
    [pscustomobject]@{
        family = "CATTRYSSE1990"
        count = 120
    }
)

$preflightTotal = 0

foreach ($item in $expected) {
    $resolved =
        Resolve-CanonicalCorpus `
            -BenchmarkRepo $BenchmarkRepo `
            -Family $item.family `
            -ExpectedCount $item.count

    $audit =
        Get-FamilyXmlAudit `
            -BenchmarkRepo $BenchmarkRepo `
            -Family $item.family `
            -CanonicalFiles @($resolved.files)

    $preflightTotal +=
        $resolved.count

    Write-Host (
        $item.family +
        ": " +
        $resolved.count +
        " / " +
        $item.count +
        " | " +
        $resolved.layout +
        " | excluded XML=" +
        $audit.noncanonical_count
    )
}

if ($preflightTotal -ne 7888) {
    throw (
        "Global canonical preflight total failed: " +
        $preflightTotal
    )
}

Write-Host "Explicit canonical-root semantic preflight: PASS"
Write-Host ""
Write-Host ""
Write-Host "==> Installing temporary package tools for noninteractive dry-run"

$tempValidator =
    Join-Path $BenchmarkRepo `
        "tools\GlobalRegistryValidator"

$createdValidator = $false

if (-not (
    Test-Path `
        -LiteralPath $tempValidator `
        -PathType Container
)) {
    New-Item `
        -ItemType Directory `
        -Path $tempValidator `
        -Force |
        Out-Null

    $createdValidator = $true
}

try {
    Copy-Item `
        -Path (
            Join-Path $PackageRoot `
                "tools\GlobalRegistryValidator\*"
        ) `
        -Destination $tempValidator `
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
            "v0.16.4 noninteractive dry-run failed with exit code " +
            $LASTEXITCODE
        )
    }
}
finally {
    if (
        $createdValidator -and
        (
            Test-Path `
                -LiteralPath $tempValidator
        )
    ) {
        Remove-Item `
            -LiteralPath $tempValidator `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Write-Host "NonInteractive global dry-run: PASS"
