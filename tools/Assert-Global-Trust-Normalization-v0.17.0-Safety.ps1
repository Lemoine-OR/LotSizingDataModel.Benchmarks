param([string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$globalRoot = Join-Path $BenchmarkRepo "catalog\global"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.17.0"
$registry = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-BENCHMARK-REGISTRY-v0.16.4.csv"))
$trust = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-NORMALIZED-TRUST-v0.17.0.csv"))
$challenges = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-OPEN-CHALLENGES-v0.17.0.csv"))
$collisions = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-HISTORICAL-ID-COLLISIONS-v0.16.4.csv"))
$duplicates = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-DUPLICATE-CLUSTERS-v0.16.4.csv"))
$lineage = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-LINEAGE-EDGES-v0.16.4.csv"))

if ($registry.Count -ne 7888 -or $trust.Count -ne 7888) { throw "7888-row invariant failed." }
if (@($registry.global_instance_id | Sort-Object -Unique).Count -ne 7888) { throw "Global ID uniqueness failed." }
$expected = @{ DJ2000 = 176; STADTLER2003 = 2100; SUERIE_CLSPL = 1291; TRIGEIRO1989 = 751; TD1996 = 3450; CATTRYSSE1990 = 120 }
foreach ($family in $expected.Keys) {
    $observed = @($registry | Where-Object family -eq $family).Count
    if ($observed -ne $expected[$family]) { throw "Family invariant failed for $family." }
}
$collisionGroups = @($collisions | Group-Object original_instance_id).Count
if ($collisionGroups -ne 50 -or $collisions.Count -ne 100) { throw "Historical collision invariant failed: $collisionGroups/$($collisions.Count)." }
if ($duplicates.Count -ne 0) { throw "Duplicate fingerprint cluster invariant failed." }
if ($lineage.Count -ne 0) { throw "Lineage edge invariant failed." }
$allowedStatuses = @("NO_REFERENCE_KNOWN", "LITERATURE_REFERENCE_UNVERIFIED", "LITERATURE_BEST_REPORTED", "REFERENCE_WITH_LOWER_BOUND", "COMPLETE_SOLUTION_UNCHECKED", "CHECKER_VERIFIED_FEASIBLE", "VERIFIED_PROVEN_OPTIMAL")
$badStatus = @($trust | Where-Object { $allowedStatuses -notcontains $_.normalized_trust_status })
if ($badStatus.Count -ne 0) { throw "Unknown normalized status detected." }
$allowedTypes = @("INFORMATIONAL", "REFERENCE_RECONCILIATION", "SOLUTION_ACQUISITION", "CHECKER_VALIDATION", "OPTIMALITY_PROOF", "SOURCE_PROVENANCE")
$allowedSeverity = @("LOW", "MEDIUM", "HIGH", "CRITICAL")
if (@($challenges | Where-Object { $allowedTypes -notcontains $_.challenge_type }).Count -ne 0) { throw "Unknown challenge type detected." }
if (@($challenges | Where-Object { $allowedSeverity -notcontains $_.severity }).Count -ne 0) { throw "Unknown severity detected." }
if (@($challenges | Where-Object normalized_trust_status -eq "VERIFIED_PROVEN_OPTIMAL").Count -ne 0) { throw "Artificial challenge assigned to verified optimum." }
$unresolved = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-UNRESOLVED-TRUST-MAPPINGS-v0.17.0.csv"))
if ($unresolved.Count -ne 0) { throw "Unresolved mappings remain." }
$g30 = @(Import-Csv -LiteralPath (Join-Path $globalRoot "GLOBAL-G30-G30B-NONIDENTITY-GUARD.csv"))
if ($g30.Count -eq 0 -or @($g30 | Where-Object status -eq "PASS_NON_IDENTITY_GUARD").Count -eq 0) { throw "G30/G30b guard evidence missing." }

$validatorProject = Join-Path $BenchmarkRepo "tools\GlobalRegistryValidator\GlobalRegistryValidator.csproj"
$registryJson = Join-Path $globalRoot "GLOBAL-BENCHMARK-REGISTRY-v0.16.4.json"
if (Test-Path -LiteralPath $validatorProject -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $registryJson -PathType Leaf)) { throw "Machine-readable registry JSON missing." }
    & dotnet run --project $validatorProject -c Release -- $registryJson 7888
    if ($LASTEXITCODE -ne 0) { throw "GlobalRegistryValidator failed." }
    Write-Host "MACHINE_VALIDATOR|PASS"
}
else {
    Write-Host "MACHINE_VALIDATOR|NOT_AVAILABLE_IN_PACKAGE_TEST"
}

Write-Host "GLOBAL_TRUST_V0.17.0_VALID"
Write-Host "ROWS|7888"
Write-Host ("COLLISIONS|" + $collisionGroups + "|" + $collisions.Count)
Write-Host "DUPLICATE_CLUSTERS|0"
Write-Host "LINEAGE_EDGES|0"
Write-Host "G30_G30B|PASS"
