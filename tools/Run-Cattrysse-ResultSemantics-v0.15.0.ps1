param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990"
$instancesRoot = Join-Path $familyRoot "instances"
$metadataRoot = Join-Path $familyRoot "metadata"
$workbookRoot = Join-Path $familyRoot "raw\result-workbooks"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.15.0"
$semanticsRoot = Join-Path $reportRoot "semantics"
$readerProject = Join-Path $BenchmarkRepo "tools\CattrysseSemanticReader\CattrysseSemanticReader.csproj"

foreach ($p in @($metadataRoot,$reportRoot,$semanticsRoot)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: validated v0.14.1 Cattrysse state"

if (@(Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File).Count -ne 120) {
    throw "Cattrysse canonical corpus must contain 120 XML."
}

$trustV14 = Join-Path $metadataRoot "CATTRYSSE1990-TRUST-CATALOG-v0.14.1.csv"

if (-not (Test-Path -LiteralPath $trustV14 -PathType Leaf)) {
    throw "v0.14.1 Cattrysse trust catalogue is missing."
}

if (@(Get-ChildItem -LiteralPath $workbookRoot -Filter "*.xls" -File).Count -ne 3) {
    throw "Cattrysse result workbook invariant failed."
}

Write-Host "Canonical XML    : 120 / 120"
Write-Host "Result workbooks : 3 / 3"

Write-Step "Preserving ecosystem invariants"

if (@(Get-ChildItem -LiteralPath (Join-Path $BenchmarkRepo "benchmarks\TD1996\instances") -Filter "*.xml" -File).Count -ne 3450) {
    throw "TD1996 invariant failed."
}

if (@(Get-ChildItem -LiteralPath (Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989\instances") -Filter "*.xml" -File).Count -ne 751) {
    throw "Trigeiro invariant failed."
}

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$stadtlerExpected = @{
    "Aplus"=240;"Bplus"=600;"C"=360;"Cplus"=240;
    "D"=360;"Dplus"=240;"E"=30;"Eplus"=30
}

$stadtlerTotal = 0

foreach ($folder in $stadtlerExpected.Keys) {
    $count = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stadtlerRoot ($folder + "\instances")) `
            -Filter "*.xml" `
            -File
    ).Count

    if ($count -ne $stadtlerExpected[$folder]) {
        throw ("Stadtler invariant failed in " + $folder)
    }

    $stadtlerTotal += $count
}

if ($stadtlerTotal -ne 2100) {
    throw "Stadtler total invariant failed."
}

$clsplPath = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

if (@(Import-Csv -LiteralPath $clsplPath).Count -ne 1281) {
    throw "CLSPL invariant failed."
}

Write-Host "TD1996   : 3450 / 3450"
Write-Host "Trigeiro : 751 / 751"
Write-Host "Stadtler : 2100 / 2100"
Write-Host "CLSPL    : 1281 / 1281"

Write-Step "Building semantic BIFF5 reader"

& dotnet build `
    $readerProject `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw "CattrysseSemanticReader build failed."
}

Write-Step "Decoding objective, deviation and timing sections"

& dotnet run `
    --project $readerProject `
    -c Release `
    --no-build `
    -- `
    $workbookRoot `
    $semanticsRoot

if ($LASTEXITCODE -ne 0) {
    throw "Cattrysse semantic workbook reconciliation failed."
}

$bestPath = Join-Path $semanticsRoot "CATTRYSSE-BEST-REPORTED-v0.15.0.csv"
$objectivePath = Join-Path $semanticsRoot "CATTRYSSE-OBJECTIVES-LONG-v0.15.0.csv"
$deviationPath = Join-Path $semanticsRoot "CATTRYSSE-DEVIATIONS-v0.15.0.csv"
$timingPath = Join-Path $semanticsRoot "CATTRYSSE-TIMINGS-v0.15.0.csv"

$best = @(Import-Csv -LiteralPath $bestPath)
$objectives = @(Import-Csv -LiteralPath $objectivePath)
$deviations = @(Import-Csv -LiteralPath $deviationPath)
$timings = @(Import-Csv -LiteralPath $timingPath)

if ($best.Count -ne 120 -or
    @($best | Select-Object -ExpandProperty instance_id -Unique).Count -ne 120) {
    throw "Best-reported catalogue must contain exactly TEST1..TEST120."
}

if ($objectives.Count -le 0 -or
    $deviations.Count -le 0 -or
    $timings.Count -le 0) {
    throw "Semantic section extraction is incomplete."
}

Write-Host ("Objective cells          : " + $objectives.Count)
Write-Host ("Verified deviation cells : " + $deviations.Count)
Write-Host ("Reported timing cells    : " + $timings.Count)
Write-Host "Best-reported objectives  : 120 / 120"

Write-Step "Reconciling trust catalogue"

$previous = @(Import-Csv -LiteralPath $trustV14)
$previousById = @{}

foreach ($row in $previous) {
    $previousById[$row.instance_id.ToUpperInvariant()] = $row
}

$final = New-Object System.Collections.Generic.List[object]

foreach ($row in $best) {
    $id = $row.instance_id.ToUpperInvariant()

    if (-not $previousById.ContainsKey($id)) {
        throw ("Missing v0.14.1 identity " + $id)
    }

    $old = $previousById[$id]

    $final.Add([pscustomobject]@{
        instance_id = $id
        class_id = $old.class_id
        xml_file = $old.xml_file
        best_reported_objective = $row.best_reported_objective
        achieving_methods = $row.achieving_methods
        reference_methods = $row.reference_methods
        workbook = $row.workbook
        trust_status = "LITERATURE_BEST_REPORTED"
        checker_verified_solution = "False"
        optimality_status = "NOT_PROVEN"
        complete_solution_available = "False"
        source_semantics = "WORKBOOK_REFERENCE_EQUALS_MIN_OF_DEFINED_REFERENCE_METHOD_SET"
        note = "Historical workbook best-reported value. No complete solution plan is available for Checker verification."
    })
}

$finalPath = Join-Path $metadataRoot "CATTRYSSE1990-TRUST-CATALOG-v0.15.0.csv"

$final.ToArray() |
    Sort-Object instance_id |
    Export-Csv `
        -LiteralPath $finalPath `
        -NoTypeInformation `
        -Encoding UTF8

if (@($final.ToArray() | Where-Object { $_.trust_status -like "VERIFIED*" }).Count -ne 0) {
    throw "Trust-gate violation."
}

Write-Host "No result promoted to VERIFIED_*: PASS"

Write-Step "Generating method best-hit summary"

$winnerRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $best) {
    foreach ($method in ($row.achieving_methods -split ";" | Where-Object { $_ -ne "" })) {
        $winnerRows.Add([pscustomobject]@{
            instance_id = $row.instance_id
            workbook = $row.workbook
            method = $method
            best_reported_objective = $row.best_reported_objective
        })
    }
}

$winnerSummary = @(
    $winnerRows.ToArray() |
    Group-Object method |
    ForEach-Object {
        [pscustomobject]@{
            method = $_.Name
            best_reported_hits = $_.Count
        }
    } |
    Sort-Object `
        @{Expression="best_reported_hits";Descending=$true}, `
        @{Expression="method";Descending=$false}
)

$winnerSummary |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "CATTRYSSE1990-METHOD-BEST-HITS-v0.15.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating GitHub result page"

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Cattrysse benchmark results")
$page.Add("")
$page.Add("> Historical result semantics reconciled from the three BIFF5 workbooks, v0.15.0.")
$page.Add("")
$page.Add("Each TEST identity occurs exactly three times: objective values, `afwijking` relative deviations, then `tijd`/`tijden` computation times.")
$page.Add("")
$page.Add("All available deviation cells are verified as `(method objective / workbook reference) - 1`.")
$page.Add("")
$page.Add("For every TEST1..TEST120, the workbook reference equals the minimum over its defined reference-method set. These values are catalogued as `LITERATURE_BEST_REPORTED`.")
$page.Add("")
$page.Add("No value is promoted to `VERIFIED_FEASIBLE` or `VERIFIED_PROVEN_OPTIMAL`, because the historical workbooks do not contain complete production-plan certificates.")
$page.Add("")
$page.Add("## Methods attaining the workbook best-reported value")
$page.Add("")
$page.Add("| Method | Hits |")
$page.Add("|---|---:|")

foreach ($row in $winnerSummary) {
    $page.Add("| " + $row.method + " | " + $row.best_reported_hits + " |")
}

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "RESULTS.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.15.0 final postconditions"

Write-Host "Cattrysse Result Semantics & BKV Reconciliation"
Write-Host "================================================"
Write-Host "Authoritative instances      : 120 / 120"
Write-Host "BIFF5 workbooks              : 3 / 3"
Write-Host "Best-reported objectives     : 120 / 120"
Write-Host ("Objective method cells       : " + $objectives.Count)
Write-Host ("Verified deviation cells     : " + $deviations.Count)
Write-Host ("Reported timing cells        : " + $timings.Count)
Write-Host "Checker-verified solutions    : 0"
Write-Host "Proven optimal objectives     : 0"
Write-Host "Trust class                   : LITERATURE_BEST_REPORTED"
Write-Host ("Trust catalogue               : " + $finalPath)
Write-Host ("Reports                       : " + $reportRoot)

if ($DryRun) {
    Write-Host "Dry-run semantic postconditions: PASS"
}
