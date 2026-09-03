param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
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

function Normalize-Code {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $v = $Value.ToUpperInvariant()
    $v = [regex]::Replace($v,"[^A-Z0-9]","")

    $m = [regex]::Match(
        $v,
        "([GK][05][0-4][12][1-5][234][012])"
    )

    if ($m.Success) {
        return $m.Groups[1].Value
    }

    return ""
}

function Get-TestSet {
    param([string]$WorkbookName)

    $name = [IO.Path]::GetFileNameWithoutExtension(
        $WorkbookName
    ).ToLowerInvariant()

    switch -Regex ($name) {
        "^solutionsap$" { return "A+" }
        "^solutionsbp$" { return "B+" }
        "^solutionscm$" { return "LEGACY-CM" }
        "^solutionscp$" { return "C+" }
        "^solutionsc$"  { return "C" }
        "^solutionsdp$" { return "D+" }
        "^solutionsd$"  { return "D" }
        "^solutionsep$" { return "E+" }
        "^solutionse$"  { return "E" }
        default { return "UNKNOWN" }
    }
}

function Get-Folder {
    param([string]$TestSet)

    switch ($TestSet) {
        "A+" { return "Aplus" }
        "B+" { return "Bplus" }
        "C"  { return "C" }
        "C+" { return "Cplus" }
        "D"  { return "D" }
        "D+" { return "Dplus" }
        "E"  { return "E" }
        "E+" { return "Eplus" }
        default { return "" }
    }
}

function Get-Value {
    param(
        [object]$Row,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $p = $Row.PSObject.Properties[$name]

        if ($null -ne $p) {
            $v = [string]$p.Value

            if (-not [string]::IsNullOrWhiteSpace($v)) {
                return $v
            }
        }
    }

    return ""
}

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$clsplRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.4.3-R1"
$stageRoot = Join-Path $reportRoot "reader-staging"
$canonicalRoot = Join-Path $stadtlerRoot "literature\canonical-v0.4.3-R1"
$metadataRoot = Join-Path $stadtlerRoot "metadata"

foreach ($p in @(
    $reportRoot,
    $canonicalRoot,
    $metadataRoot
)) {
    Ensure-Directory -Path $p
}

Write-Step "Validating frozen benchmark corpus"

$sets = @(
    [pscustomobject]@{TestSet="A+";Folder="Aplus";Count=240},
    [pscustomobject]@{TestSet="B+";Folder="Bplus";Count=600},
    [pscustomobject]@{TestSet="C";Folder="C";Count=360},
    [pscustomobject]@{TestSet="C+";Folder="Cplus";Count=240},
    [pscustomobject]@{TestSet="D";Folder="D";Count=360},
    [pscustomobject]@{TestSet="D+";Folder="Dplus";Count=240},
    [pscustomobject]@{TestSet="E";Folder="E";Count=30},
    [pscustomobject]@{TestSet="E+";Folder="Eplus";Count=30}
)

$total = 0

foreach ($s in $sets) {
    $instances = Join-Path $stadtlerRoot (
        $s.Folder + "\instances"
    )

    $count = @(
        Get-ChildItem `
            -LiteralPath $instances `
            -Filter "*.xml" `
            -File `
            -ErrorAction SilentlyContinue
    ).Count

    Write-Host (
        $s.TestSet +
        ": XML=" +
        $count +
        "/" +
        $s.Count
    )

    if ($count -ne $s.Count) {
        throw (
            "Frozen Stadtler corpus mismatch for " +
            $s.TestSet
        )
    }

    $total += $count
}

if ($total -ne 2100) {
    throw "Frozen Stadtler corpus must contain exactly 2100 XML."
}

$clsplCatalogue = Join-Path $clsplRoot `
    "metadata\CLSPL-LITERATURE-REFERENCES.csv"

$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)
$databRows = @(
    $clsplRows |
    Where-Object { $_.test_set -eq "datab" }
)

if ($clsplRows.Count -ne 1281 -or $databRows.Count -ne 60) {
    throw (
        "CLSPL precondition failed: mapped=" +
        $clsplRows.Count +
        " datab=" +
        $databRows.Count
    )
}

Write-Host "CLSPL catalogue: 1281 / 1281; datab 60 / 60."

Write-Step "Discovering logical Stadtler workbooks"

$materializedRoot = Join-Path $stadtlerRoot "raw\materialized"

$allBooks = @(
    Get-ChildItem `
        -LiteralPath $materializedRoot `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "(?i)^solutions[a-z0-9_-]*\.xls[x]?$"
    }
)

if ($allBooks.Count -eq 0) {
    throw "No Stadtler solution workbooks found."
}

$bookInventory = New-Object System.Collections.Generic.List[object]

foreach ($book in $allBooks) {
    $bookInventory.Add([pscustomobject]@{
        test_set = Get-TestSet -WorkbookName $book.Name
        logical_name = $book.Name.ToLowerInvariant()
        path = $book.FullName
        sha256 = (
            Get-FileHash `
                -LiteralPath $book.FullName `
                -Algorithm SHA256
        ).Hash
        length = $book.Length
    })
}

$bookInventory.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "workbook-inventory.csv") `
        -NoTypeInformation `
        -Encoding UTF8

# Process every physical workbook because some archive copies differ at binary level.
# Semantic deduplication happens AFTER reference extraction.
$readerProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerReferenceReader\StadtlerReferenceReader.csproj"

if (-not (Test-Path -LiteralPath $readerProject -PathType Leaf)) {
    throw "StadtlerReferenceReader is missing."
}

if ($DryRun) {
    Write-Host (
        "Physical workbook paths: " +
        $bookInventory.Count
    )

    Write-Host "Dry-run PASS."
    exit 0
}

Write-Step "Building StadtlerReferenceReader"

& dotnet build `
    $readerProject `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw "StadtlerReferenceReader build failed."
}

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item `
        -LiteralPath $stageRoot `
        -Recurse `
        -Force
}

Ensure-Directory -Path $stageRoot

Write-Step "Extracting references in isolated workbook stages"

$runs = New-Object System.Collections.Generic.List[object]
$runOrdinal = 0

foreach ($book in (
    $bookInventory.ToArray() |
    Sort-Object logical_name,path
)) {
    $runOrdinal++

    $stageName = (
        "{0:D3}_{1}" -f
        $runOrdinal,
        [IO.Path]::GetFileNameWithoutExtension(
            $book.logical_name
        )
    )

    $stage = Join-Path $stageRoot $stageName
    Ensure-Directory -Path $stage

    $console = @(
        & dotnet run `
            --project $readerProject `
            -c Release `
            --no-build `
            -- `
            $book.path `
            $stage 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    [IO.File]::WriteAllLines(
        (Join-Path $stage "reader-console.log"),
        $console,
        (New-Object Text.UTF8Encoding($false))
    )

    $resolved = -1

    foreach ($line in $console) {
        if ($line -match "resolved=(\d+)") {
            $resolved = [int]$Matches[1]
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Reader failed for " +
            $book.path
        )
    }

    if ($resolved -lt 0) {
        throw (
            "Reader did not report resolved count for " +
            $book.path
        )
    }

    $runs.Add([pscustomobject]@{
        run_id = $runOrdinal
        test_set = $book.test_set
        workbook = $book.logical_name
        workbook_path = $book.path
        sha256 = $book.sha256
        stage = $stage
        resolved_expected = $resolved
    })

    Write-Host (
        $book.logical_name +
        ": resolved=" +
        $resolved
    )
}

$runs.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "reader-runs.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Selecting semantic resolved rows from each reader stage"

$allSemanticRows = New-Object System.Collections.Generic.List[object]
$csvAudit = New-Object System.Collections.Generic.List[object]

foreach ($run in $runs.ToArray()) {
    $csvFiles = @(
        Get-ChildItem `
            -LiteralPath $run.stage `
            -Filter "*.csv" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
    )

    if ($csvFiles.Count -eq 0) {
        throw (
            "No CSV output for reader run " +
            $run.run_id
        )
    }

    $candidateSets = New-Object System.Collections.Generic.List[object]

    foreach ($csv in $csvFiles) {
        $semantic = New-Object System.Collections.Generic.List[object]

        foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
            $sourceId = Get-Value `
                -Row $row `
                -Names @(
                    "source_instance_id",
                    "instance_id",
                    "instance",
                    "code",
                    "name"
                )

            if ([string]::IsNullOrWhiteSpace($sourceId)) {
                continue
            }

            $code = Normalize-Code -Value $sourceId

            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }

            $objective = Get-Value `
                -Row $row `
                -Names @(
                    "objective",
                    "best_known",
                    "best_known_objective",
                    "value",
                    "obj"
                )

            $lowerBound = Get-Value `
                -Row $row `
                -Names @(
                    "lower_bound",
                    "lowerbound",
                    "lb",
                    "bound"
                )

            $sheet = Get-Value `
                -Row $row `
                -Names @(
                    "sheet",
                    "source_sheet",
                    "worksheet"
                )

            $semantic.Add([pscustomobject]@{
                test_set = $run.test_set
                source_instance_id = $sourceId
                canonical_code = $code
                objective = $objective
                lower_bound = $lowerBound
                source_workbook = $run.workbook
                source_workbook_sha256 = $run.sha256
                source_sheet = $sheet
                reader_csv = $csv.FullName
                run_id = $run.run_id
            })
        }

        # Semantic deduplication WITHIN this CSV.
        $seenCsv = @{}
        $dedupCsv = New-Object System.Collections.Generic.List[object]

        foreach ($row in $semantic.ToArray()) {
            $key = (
                $row.test_set + "|" +
                $row.canonical_code + "|" +
                $row.objective + "|" +
                $row.lower_bound
            )

            if (-not $seenCsv.ContainsKey($key)) {
                $seenCsv[$key] = $true
                $dedupCsv.Add($row)
            }
        }

        $candidateSets.Add([pscustomobject]@{
            csv_path = $csv.FullName
            semantic_count = $dedupCsv.Count
            rows = $dedupCsv.ToArray()
        })

        $csvAudit.Add([pscustomobject]@{
            run_id = $run.run_id
            workbook = $run.workbook
            csv_path = $csv.FullName
            semantic_count = $dedupCsv.Count
            resolved_expected = $run.resolved_expected
        })
    }

    # First preference: a single CSV whose semantic count equals reader's resolved count.
    $exactFiles = @(
        $candidateSets.ToArray() |
        Where-Object {
            $_.semantic_count -eq $run.resolved_expected
        }
    )

    $selectedRows = @()

    if ($exactFiles.Count -ge 1) {
        # If several CSVs qualify, union them semantically. They should describe the same set.
        $unionSeen = @{}
        $union = New-Object System.Collections.Generic.List[object]

        foreach ($set in $exactFiles) {
            foreach ($row in $set.rows) {
                $key = (
                    $row.test_set + "|" +
                    $row.canonical_code + "|" +
                    $row.objective + "|" +
                    $row.lower_bound
                )

                if (-not $unionSeen.ContainsKey($key)) {
                    $unionSeen[$key] = $true
                    $union.Add($row)
                }
            }
        }

        if ($union.Count -eq $run.resolved_expected) {
            $selectedRows = $union.ToArray()
        }
    }

    # Fallback: semantic union of all CSVs must exactly equal reader's resolved count.
    if ($selectedRows.Count -eq 0) {
        $allSeen = @{}
        $allUnion = New-Object System.Collections.Generic.List[object]

        foreach ($set in $candidateSets.ToArray()) {
            foreach ($row in $set.rows) {
                $key = (
                    $row.test_set + "|" +
                    $row.canonical_code + "|" +
                    $row.objective + "|" +
                    $row.lower_bound
                )

                if (-not $allSeen.ContainsKey($key)) {
                    $allSeen[$key] = $true
                    $allUnion.Add($row)
                }
            }
        }

        if ($allUnion.Count -eq $run.resolved_expected) {
            $selectedRows = $allUnion.ToArray()
        }
    }

    if ($selectedRows.Count -ne $run.resolved_expected) {
        throw (
            "Could not reconcile reader CSVs for " +
            $run.workbook +
            " run " +
            $run.run_id +
            ": expected " +
            $run.resolved_expected +
            ", selected " +
            $selectedRows.Count
        )
    }

    foreach ($row in $selectedRows) {
        $allSemanticRows.Add($row)
    }

    Write-Host (
        $run.workbook +
        " run " +
        $run.run_id +
        ": canonical rows=" +
        $selectedRows.Count
    )
}

$csvAudit.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "reader-csv-audit.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Deduplicating across workbook copies by semantic identity"

$globalSeen = @{}
$canonicalRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $allSemanticRows.ToArray()) {
    $key = (
        $row.test_set + "|" +
        $row.canonical_code + "|" +
        $row.objective + "|" +
        $row.lower_bound
    )

    if (-not $globalSeen.ContainsKey($key)) {
        $globalSeen[$key] = $true
        $canonicalRows.Add($row)
    }
}

$canonicalRows.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $canonicalRoot "STADTLER-CANONICAL-LITERATURE.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Canonical semantic literature rows: " +
    $canonicalRows.Count
)

if ($canonicalRows.Count -ne 982) {
    throw (
        "Canonical literature postcondition failed: expected 982, found " +
        $canonicalRows.Count
    )
}

Write-Step "Validating expected literature distribution"

$expectedLiterature = @{
    "A+" = 120
    "B+" = 312
    "C" = 180
    "C+" = 10
    "D" = 80
    "E" = 90
    "E+" = 10
    "LEGACY-CM" = 180
}

foreach ($key in $expectedLiterature.Keys) {
    $count = @(
        $canonicalRows.ToArray() |
        Where-Object {
            $_.test_set -eq $key
        }
    ).Count

    Write-Host (
        $key +
        ": literature=" +
        $count +
        "/" +
        $expectedLiterature[$key]
    )

    if ($count -ne $expectedLiterature[$key]) {
        throw (
            "Literature distribution mismatch for " +
            $key
        )
    }
}

Write-Step "Building generated XML index"

$xmlIndex = @{}

foreach ($s in $sets) {
    $instances = Join-Path $stadtlerRoot (
        $s.Folder + "\instances"
    )

    foreach ($file in (
        Get-ChildItem `
            -LiteralPath $instances `
            -Filter "*.xml" `
            -File
    )) {
        $code = Normalize-Code `
            -Value $file.BaseName

        if ([string]::IsNullOrWhiteSpace($code)) {
            continue
        }

        $indexKey = (
            $s.TestSet +
            "|" +
            $code
        )

        if (-not $xmlIndex.ContainsKey($indexKey)) {
            $xmlIndex[$indexKey] =
                New-Object System.Collections.Generic.List[object]
        }

        $xmlIndex[$indexKey].Add([pscustomobject]@{
            test_set = $s.TestSet
            canonical_code = $code
            lsdm_filename = $file.Name
            lsdm_path = $file.FullName
        })
    }
}

Write-Step "Mapping literature by official class and canonical code"

$mapped = New-Object System.Collections.Generic.List[object]
$unmapped = New-Object System.Collections.Generic.List[object]
$legacy = New-Object System.Collections.Generic.List[object]

foreach ($row in $canonicalRows.ToArray()) {
    if ($row.test_set -eq "LEGACY-CM") {
        $legacy.Add([pscustomobject]@{
            test_set = "LEGACY-CM"
            source_instance_id = $row.source_instance_id
            canonical_code = $row.canonical_code
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $row.source_workbook
            status = "LEGACY_NON_OFFICIAL_REFERENCE"
        })

        continue
    }

    $indexKey = (
        $row.test_set +
        "|" +
        $row.canonical_code
    )

    $candidates = @()

    if ($xmlIndex.ContainsKey($indexKey)) {
        $candidates = @(
            $xmlIndex[$indexKey].ToArray()
        )
    }

    if ($candidates.Count -eq 1) {
        $match = $candidates[0]

        $mapped.Add([pscustomobject]@{
            test_set = $row.test_set
            source_instance_id = $row.source_instance_id
            canonical_code = $row.canonical_code
            lsdm_filename = $match.lsdm_filename
            lsdm_path = $match.lsdm_path
            objective = $row.objective
            lower_bound = $row.lower_bound
            objective_status = $(
                if ([string]::IsNullOrWhiteSpace($row.objective)) {
                    ""
                }
                else {
                    "LITERATURE_BEST_KNOWN"
                }
            )
            lower_bound_status = $(
                if ([string]::IsNullOrWhiteSpace($row.lower_bound)) {
                    ""
                }
                else {
                    "LITERATURE_LOWER_BOUND"
                }
            )
            verified = "False"
            source_workbook = $row.source_workbook
            source_workbook_sha256 = $row.source_workbook_sha256
            source_sheet = $row.source_sheet
            mapping_status = "UNIQUE_CLASS_PLUS_CANONICAL_CODE"
        })
    }
    else {
        $status = "NO_GENERATED_XML_FOR_CODE"

        if ($candidates.Count -gt 1) {
            $status = "AMBIGUOUS_CODE_WITHIN_CLASS"
        }

        $unmapped.Add([pscustomobject]@{
            test_set = $row.test_set
            source_instance_id = $row.source_instance_id
            canonical_code = $row.canonical_code
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $row.source_workbook
            candidate_count = $candidates.Count
            status = $status
        })
    }
}

$mapped.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-REFERENCES-v0.4.3-R1.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$unmapped.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-UNMAPPED-v0.4.3-R1.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$legacy.ToArray() |
    Sort-Object canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LEGACY-CM-REFERENCES-v0.4.3-R1.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating final GitHub pages"

foreach ($s in $sets) {
    $classRoot = Join-Path $stadtlerRoot $s.Folder
    $classMapped = @(
        $mapped.ToArray() |
        Where-Object {
            $_.test_set -eq $s.TestSet
        }
    )

    $classUnmapped = @(
        $unmapped.ToArray() |
        Where-Object {
            $_.test_set -eq $s.TestSet
        }
    )

    $page = New-Object System.Collections.Generic.List[string]

    $page.Add("# Stadtler " + $s.TestSet)
    $page.Add("")
    $page.Add("| Metric | Count |")
    $page.Add("|---|---:|")
    $page.Add("| Generated admissible XML | **" + $s.Count + "** |")
    $page.Add("| Published reference rows mapped | **" + $classMapped.Count + "** |")
    $page.Add("| Published reference rows unresolved | **" + $classUnmapped.Count + "** |")
    $page.Add("| Verified complete solutions | **0 unless separately checker-verified** |")
    $page.Add("")
    $page.Add("The generated universe and the published-reference subset are distinct.")
    $page.Add("")
    $page.Add("Published objectives and lower bounds remain literature evidence until a complete solution is independently checked.")

    [IO.File]::WriteAllLines(
        (Join-Path $classRoot "README.md"),
        $page.ToArray(),
        (New-Object Text.UTF8Encoding($false))
    )
}

$family = New-Object System.Collections.Generic.List[string]

$family.Add("# Stadtler 2003 MLCLSP benchmark")
$family.Add("")
$family.Add("> Canonical generated universe and reconciled published literature.")
$family.Add("")
$family.Add("| Test set | Generated XML | Published mapped | Published unresolved |")
$family.Add("|---|---:|---:|---:|")

foreach ($s in $sets) {
    $mc = @(
        $mapped.ToArray() |
        Where-Object {
            $_.test_set -eq $s.TestSet
        }
    ).Count

    $uc = @(
        $unmapped.ToArray() |
        Where-Object {
            $_.test_set -eq $s.TestSet
        }
    ).Count

    $family.Add(
        "| " +
        $s.TestSet +
        " | " +
        $s.Count +
        " | " +
        $mc +
        " | " +
        $uc +
        " |"
    )
}

$family.Add(
    "| **Total** | **2100** | **" +
    $mapped.Count +
    "** | **" +
    $unmapped.Count +
    "** |"
)

$family.Add("")
$family.Add("## Literature")
$family.Add("")
$family.Add("- Canonical literature rows: **982**")
$family.Add("- Official mapped rows: **" + $mapped.Count + "**")
$family.Add("- Official unresolved rows: **" + $unmapped.Count + "**")
$family.Add("- Legacy classcm rows: **" + $legacy.Count + "**")
$family.Add("")
$family.Add("## Genealogy")
$family.Add("")
$family.Add("- Stadtler B+ -> SUERIE_CLSPL/datab is retained as a published 60-instance subset relation.")
$family.Add("- Exact SupplyChainFingerprint equality is a separate technical relation and is not required for bibliographic genealogy.")

[IO.File]::WriteAllLines(
    (Join-Path $stadtlerRoot "README.md"),
    $family.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.4.3 R1 final summary"

Write-Host "Stadtler XML preserved: 2100 / 2100"
Write-Host "CLSPL catalogue preserved: 1281 / 1281"
Write-Host ("Physical workbook paths: " + $bookInventory.Count)
Write-Host ("Reader runs: " + $runs.Count)
Write-Host ("Canonical literature rows: " + $canonicalRows.Count)
Write-Host ("Official literature mapped: " + $mapped.Count)
Write-Host ("Official literature unresolved: " + $unmapped.Count)
Write-Host ("Legacy classcm rows: " + $legacy.Count)
Write-Host ("Reports: " + $reportRoot)
