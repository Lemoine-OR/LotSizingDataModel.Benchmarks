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

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989"
$instancesRoot = Join-Path $familyRoot "instances"
$metadataRoot = Join-Path $familyRoot "metadata"
$validationRoot = Join-Path $familyRoot "validation"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.12.0"
$catalogRoot = Join-Path $BenchmarkRepo "catalog"
$seedPath = Join-Path $BenchmarkRepo "catalog\TRIGEIRO1989-LITERATURE-SEED-v0.12.0.csv"

foreach ($p in @($metadataRoot,$validationRoot,$reportRoot,$catalogRoot)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: authoritative Trigeiro corpus"

$xml = @(
    Get-ChildItem `
        -LiteralPath $instancesRoot `
        -Filter "*.xml" `
        -File `
        -ErrorAction SilentlyContinue
)

if ($xml.Count -ne 751) {
    throw (
        "Trigeiro authoritative corpus must contain 751 XML; found " +
        $xml.Count
    )
}

$sourceRoles = Join-Path $metadataRoot "TRIGEIRO1989-SOURCE-ROLES-v0.11.0.csv"

if (-not (Test-Path -LiteralPath $sourceRoles -PathType Leaf)) {
    throw "v0.11.0 source-role catalogue is missing."
}

$roles = @(Import-Csv -LiteralPath $sourceRoles)
$originals = @($roles | Where-Object { $_.role -eq "ORIGINAL_SOURCE" })
$derived = @($roles | Where-Object { $_.role -eq "DERIVED_SECONDARY_FORMAT" })

if ($originals.Count -ne 751 -or $derived.Count -ne 751) {
    throw "v0.11.0 provenance invariant failed."
}

Write-Host "Canonical XML       : 751 / 751"
Write-Host "Authoritative TRIG  : 751 / 751"
Write-Host "Derived DAT         : 751 / 751"

Write-Step "Preserving Stadtler and CLSPL invariants"

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$expected = @{
    "Aplus" = 240
    "Bplus" = 600
    "C" = 360
    "Cplus" = 240
    "D" = 360
    "Dplus" = 240
    "E" = 30
    "Eplus" = 30
}

$total = 0
foreach ($folder in $expected.Keys) {
    $count = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stadtlerRoot ($folder + "\instances")) `
            -Filter "*.xml" `
            -File
    ).Count

    if ($count -ne $expected[$folder]) {
        throw ("Stadtler invariant failed in " + $folder)
    }

    $total += $count
}

if ($total -ne 2100) {
    throw "Stadtler total invariant failed."
}

$clsplPath = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv"

if (@(Import-Csv -LiteralPath $clsplPath).Count -ne 1281) {
    throw "CLSPL invariant failed."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL    : 1281 / 1281"

if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) {
    throw "Trigeiro literature seed catalogue missing."
}

$seed = @(Import-Csv -LiteralPath $seedPath)

Write-Step "Scanning local Trigeiro result evidence"

$resultCandidates = @(
    Get-ChildItem `
        -LiteralPath $familyRoot `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "(?i)(result|solution|objective|bound|best|bkv|opt|readme)" -and
        $_.FullName -notlike "*\instances\*"
    }
)

$evidenceRows = New-Object System.Collections.Generic.List[object]

foreach ($file in $resultCandidates) {
    $preview = ""

    if ($file.Length -le 1000000) {
        try {
            $preview = @(
                Get-Content `
                    -LiteralPath $file.FullName `
                    -TotalCount 50 `
                    -ErrorAction Stop
            ) -join " || "
        }
        catch {
        }
    }

    $evidenceRows.Add([pscustomobject]@{
        path = $file.FullName
        file_name = $file.Name
        sha256 = (
            Get-FileHash `
                -LiteralPath $file.FullName `
                -Algorithm SHA256
        ).Hash
        length = $file.Length
        evidence_status = "UNRECONCILED_LOCAL_EVIDENCE"
        preview = [regex]::Replace(
            $preview,
            "[^\x20-\x7E\t]",
            "?")
    })
}

$evidenceRows.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "TRIGEIRO-LOCAL-RESULT-EVIDENCE.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Local result-evidence files: " + $evidenceRows.Count)

Write-Step "Building 751-instance trust catalogue"

$catalogV11 = Join-Path $metadataRoot "TRIGEIRO1989-CANONICAL-CATALOG-v0.11.0.csv"

if (-not (Test-Path -LiteralPath $catalogV11 -PathType Leaf)) {
    throw "v0.11.0 canonical catalogue is missing."
}

$base = @(Import-Csv -LiteralPath $catalogV11)
$seedById = @{}

foreach ($row in $seed) {
    $seedById[$row.instance_id.ToUpperInvariant()] = $row
}

$trust = New-Object System.Collections.Generic.List[object]

foreach ($row in $base) {
    $id = $row.instance_id.ToUpperInvariant()
    $objective = ""
    $lowerBound = ""
    $alias = ""
    $literatureClaim = "NONE"
    $status = "UNKNOWN_REFERENCE"
    $source = ""
    $identityNote = ""

    if ($seedById.ContainsKey($id)) {
        $lit = $seedById[$id]
        $objective = $lit.objective
        $lowerBound = $lit.lower_bound
        $alias = $lit.alias
        $literatureClaim = $lit.evidence_status
        $status = $lit.trust_status
        $source = $lit.source
        $identityNote = $lit.identity_note
    }

    $trust.Add([pscustomobject]@{
        instance_id = $id
        series = $row.series
        xml_file = $row.xml_file
        authoritative_source = "ORIGINAL_TRIG_AUTHORITATIVE"
        alias = $alias
        objective = $objective
        lower_bound = $lowerBound
        literature_claim = $literatureClaim
        trust_status = $status
        complete_solution_available = "False"
        checker_verified_solution = "False"
        optimality_verified_by_checker = "False"
        literature_source = $source
        identity_note = $identityNote
    })
}

$trustPath = Join-Path $metadataRoot "TRIGEIRO1989-TRUST-CATALOG-v0.12.0.csv"

$trust.ToArray() |
    Sort-Object series,instance_id |
    Export-Csv `
        -LiteralPath $trustPath `
        -NoTypeInformation `
        -Encoding UTF8

$litValues = @($trust.ToArray() | Where-Object { $_.trust_status -eq "LITERATURE_VALUE" })
$unknown = @($trust.ToArray() | Where-Object { $_.trust_status -eq "UNKNOWN_REFERENCE" })

Write-Host ("Literature values seeded : " + $litValues.Count)
Write-Host ("Unknown references       : " + $unknown.Count)

Write-Step "Applying trust-gate policy"

# No complete solution is bundled in the authoritative source corpus.
# Therefore no record may be promoted to VERIFIED_FEASIBLE or
# VERIFIED_PROVEN_OPTIMAL by this release.
$forbidden = @(
    $trust.ToArray() |
    Where-Object {
        $_.trust_status -eq "VERIFIED_FEASIBLE" -or
        $_.trust_status -eq "VERIFIED_PROVEN_OPTIMAL"
    }
)

if ($forbidden.Count -ne 0) {
    throw "Trust-gate violation: verified status without a complete checked solution."
}

Write-Host "No unverified objective promoted to VERIFIED_*: PASS"

Write-Step "Documenting G30/G30b identity hazard"

$g30 = @($trust.ToArray() | Where-Object { $_.instance_id -eq "G30" })

if ($g30.Count -ne 1) {
    throw "Expected exactly one G30 authoritative instance."
}

if ($g30[0].trust_status -ne "UNKNOWN_REFERENCE") {
    throw "G30 must remain UNKNOWN_REFERENCE because G30b is a transformed unit-time variant."
}

Write-Host "G30 original / G30b transformed-variant guard: PASS"

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Trust catalogue generation and policy guards are valid."
    exit 0
}

Write-Step "Checking whether complete candidate solutions exist"

$candidateRoots = @(
    (Join-Path $familyRoot "candidate-solutions"),
    (Join-Path $familyRoot "solutions"),
    (Join-Path $familyRoot "results\solutions")
)

$solutionFiles = New-Object System.Collections.Generic.List[object]

foreach ($root in $candidateRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        continue
    }

    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) {
        $solutionFiles.Add([pscustomobject]@{
            path = $file.FullName
            file_name = $file.Name
            sha256 = (
                Get-FileHash `
                    -LiteralPath $file.FullName `
                    -Algorithm SHA256
            ).Hash
            status = "CANDIDATE_REQUIRES_IDENTITY_AND_CHECKER"
        })
    }
}

$solutionFiles.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "TRIGEIRO-COMPLETE-SOLUTION-CANDIDATES.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Complete candidate solution files discovered: " + $solutionFiles.Count)

Write-Step "Generating GitHub trust pages"

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Trigeiro et al. 1989 benchmark")
$page.Add("")
$page.Add("> Result trust gate v0.12.0 on top of the authoritative 751-instance TRIG corpus.")
$page.Add("")
$page.Add("| Trust class | Count |")
$page.Add("|---|---:|")
$page.Add("| LITERATURE_VALUE | **" + $litValues.Count + "** |")
$page.Add("| VERIFIED_FEASIBLE | **0** |")
$page.Add("| VERIFIED_PROVEN_OPTIMAL | **0** |")
$page.Add("| UNKNOWN_REFERENCE | **" + $unknown.Count + "** |")
$page.Add("")
$page.Add("## Important identity warning")
$page.Add("")
$page.Add("`G30` is the authoritative original Trigeiro instance and contains fractional unit production times. Literature also uses a transformed `G30b` with unit production times. The well-known value 37721 belongs to the transformed benchmark usage and is not attached to authoritative G30 by this catalogue.")
$page.Add("")
$page.Add("## Literature-seeded optimal claims")
$page.Add("")
$page.Add("Five standard original G-series identities have literature claims of optimality (G62, G53, G69, G57 and G72). They remain `LITERATURE_VALUE` rather than `VERIFIED_PROVEN_OPTIMAL` because this repository currently has no complete solution certificate for LotSizingDataModel.Checker to validate.")
$page.Add("")
$page.Add("The trust catalogue is `metadata/TRIGEIRO1989-TRUST-CATALOG-v0.12.0.csv`.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "RESULTS.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

$openPage = New-Object System.Collections.Generic.List[string]
$openPage.Add("# Trigeiro 1989 result challenges")
$openPage.Add("")
$openPage.Add("Priority: locate instance-level upper bounds, lower bounds and complete solution certificates for the 751 authoritative TRIG identities.")
$openPage.Add("")
$openPage.Add("Special caution: never merge G30 and G30b results by name similarity.")

[IO.File]::WriteAllLines(
    (Join-Path $familyRoot "OPEN-RESULT-CHALLENGES.md"),
    $openPage.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.12.0 final summary"

Write-Host "Trigeiro 1989 Results & Trust Gate"
Write-Host "=================================="
Write-Host "Authoritative instances        : 751"
Write-Host ("Literature values recorded     : " + $litValues.Count)
Write-Host "Checker-verified feasible       : 0"
Write-Host "Checker-verified proven optimal : 0"
Write-Host ("Unknown reference values       : " + $unknown.Count)
Write-Host ("Local result evidence files    : " + $evidenceRows.Count)
Write-Host ("Complete solution candidates   : " + $solutionFiles.Count)
Write-Host "G30/G30b identity guard         : PASS"
Write-Host ("Trust catalogue                 : " + $trustPath)
Write-Host ("Reports                         : " + $reportRoot)
