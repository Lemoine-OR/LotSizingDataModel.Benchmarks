param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" }
function Ensure-Dir { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

$project = Join-Path $BenchmarkRepo "tools\TempelmeierConverter\TempelmeierConverter.csproj"
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Converter project missing: $project" }

Write-Step "Building Tempelmeier converter"
& dotnet build $project -c Release --nologo -p:ModelRepo=$ModelRepo
if ($LASTEXITCODE -ne 0) { throw "Converter build failed." }

$stadtSrc = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\materialized"
$clsSrc = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\raw\materialized"

$stadtOut = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\instances"
$clsOut = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\instances"
Ensure-Dir $stadtOut; Ensure-Dir $clsOut

$logs = Join-Path $BenchmarkRepo "reports\tempelmeier-conversion"
Ensure-Dir $logs

Write-Step "Converting materialized Stadtler MLCLSP directories"
$stadtLog = @(& dotnet run --project $project -c Release --no-build -p:ModelRepo=$ModelRepo -- stadtler $stadtSrc $stadtOut 2>&1 | ForEach-Object { $_.ToString() })
[System.IO.File]::WriteAllLines((Join-Path $logs "stadtler-conversion.log"),$stadtLog,(New-Object System.Text.UTF8Encoding($false)))
$stadtLog | ForEach-Object { Write-Host $_ }

Write-Step "Converting materialized Suerie CLSPL directories"
$clsLog = @(& dotnet run --project $project -c Release --no-build -p:ModelRepo=$ModelRepo -- clspl $clsSrc $clsOut 2>&1 | ForEach-Object { $_.ToString() })
[System.IO.File]::WriteAllLines((Join-Path $logs "clspl-conversion.log"),$clsLog,(New-Object System.Text.UTF8Encoding($false)))
$clsLog | ForEach-Object { Write-Host $_ }

Write-Step "Running structural checker on converted XML"

$checker = Join-Path $ModelRepo "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"
if (Test-Path -LiteralPath $checker -PathType Leaf) {
    foreach ($spec in @(
        [pscustomobject]@{Name="STADTLER2003";Input=$stadtOut},
        [pscustomobject]@{Name="SUERIE_CLSPL";Input=$clsOut}
    )) {
        $files = @(Get-ChildItem -LiteralPath $spec.Input -Filter "*.xml" -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { continue }

        $report = Join-Path $logs ("checker-" + $spec.Name)
        Ensure-Dir $report

        # Pure instances have no known solution candidate, so this mainly exercises loading/structural campaign behavior.
        & dotnet run --project $checker -c Release -- $spec.Input --level structural --output $report --no-progress
        Write-Host ($spec.Name + " checker exit=" + $LASTEXITCODE)
    }
}

$stadtCount = @(Get-ChildItem -LiteralPath $stadtOut -Filter "*.xml" -File -ErrorAction SilentlyContinue).Count
$clsCount = @(Get-ChildItem -LiteralPath $clsOut -Filter "*.xml" -File -ErrorAction SilentlyContinue).Count

Write-Step "Conversion summary"
Write-Host ("STADTLER2003 XML: " + $stadtCount)
Write-Host ("SUERIE_CLSPL XML: " + $clsCount)
Write-Host ("Logs: " + $logs)
