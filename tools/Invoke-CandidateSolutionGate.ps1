param(
    [Parameter(Mandatory=$true)]
    [string]$CandidateDirectory,

    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel",

    [double]$ObjectiveAbsoluteTolerance = 1e-6,
    [double]$ObjectiveRelativeTolerance = 1e-9
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

if (-not (Test-Path -LiteralPath $CandidateDirectory -PathType Container)) {
    Fail "Candidate directory not found: $CandidateDirectory"
}

$checkerProject = Join-Path $ModelRepo "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"
if (-not (Test-Path -LiteralPath $checkerProject -PathType Leaf)) {
    Fail "Checker project not found: $checkerProject"
}

$reportDir = Join-Path $CandidateDirectory "checker-report"
if (Test-Path -LiteralPath $reportDir) {
    Remove-Item -LiteralPath $reportDir -Recurse -Force
}
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

Write-Host ""
Write-Host "==> Building checker"
& dotnet build $checkerProject -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    Fail "Checker build failed."
}

Write-Host ""
Write-Host "==> Verifying candidate solution"
& dotnet run `
    --project $checkerProject `
    -c Release `
    --no-build `
    -- `
    $CandidateDirectory `
    --level full `
    --output $reportDir `
    --no-update-known-result `
    --no-promote-known-result `
    --no-progress `
    --objective-absolute-tolerance $ObjectiveAbsoluteTolerance `
    --objective-relative-tolerance $ObjectiveRelativeTolerance

$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "CANDIDATE CHECK: VALID"
    Write-Host "The candidate is eligible for comparison with the current reference."
    exit 0
}

if ($exitCode -eq 1) {
    Write-Host ""
    Write-Host "CANDIDATE CHECK: REJECTED_BY_CHECKER"
    Write-Host "The candidate must not be promoted."
    exit 1
}

Fail ("Checker execution failed with exit code " + $exitCode)
