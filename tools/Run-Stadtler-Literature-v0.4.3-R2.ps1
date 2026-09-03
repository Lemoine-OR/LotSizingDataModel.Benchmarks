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

function Find-CodeInRow {
    param([object]$Row)

    $codes = New-Object System.Collections.Generic.HashSet[string]

    foreach ($property in $Row.PSObject.Properties) {
        $value = [string]$property.Value
        $code = Normalize-Code -Value $value

        if (-not [string]::IsNullOrWhiteSpace($code)) {
            [void]$codes.Add($code)
        }
    }

    if ($codes.Count -eq 1) {
        return @($codes)[0]
    }

    # A header itself may identify a code-bearing column while another cell
    # contains unrelated seven-character text. Prefer explicit code/id/name headers.
    foreach ($property in $Row.PSObject.Properties) {
        $header = $property.Name.ToLowerInvariant()

        if ($header -match "(code|instance|problem|name|test)") {
            $code = Normalize-Code -Value ([string]$property.Value)

            if (-not [string]::IsNullOrWhiteSpace($code)) {
                return $code
            }
        }
    }

    return ""
}

function Find-ValueByHeader {
    param(
        [object]$Row,
        [string[]]$PositivePatterns,
        [string[]]$NegativePatterns
    )

    foreach ($property in $Row.PSObject.Properties) {
        $header = $property.Name.ToLowerInvariant()
        $positive = $false

        foreach ($pattern in $PositivePatterns) {
            if ($header -match $pattern) {
                $positive = $true
                break
            }
        }

        if (-not $positive) {
            continue
        }

        $negative = $false

        foreach ($pattern in $NegativePatterns) {
            if ($header -match $pattern) {
                $negative = $true
                break
            }
        }

        if ($negative) {
            continue
        }

        $value = [string]$property.Value

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ""
}

function Get-ObjectiveValue {
    param([object]$Row)

    return Find-ValueByHeader `
        -Row $Row `
        -PositivePatterns @(
            "^objective$",
            "objective",
            "best.*known",
            "^bkv$",
            "^ub$",
            "upper.*bound",
            "solution.*value",
            "^value$",
            "^obj$"
        ) `
        -NegativePatterns @(
            "lower",
            "^lb$"
        )
}

function Get-LowerBoundValue {
    param([object]$Row)

    return Find-ValueByHeader `
        -Row $Row `
        -PositivePatterns @(
            "^lb$",
            "lower.*bound",
            "lowerbound",
            "^bound$"
        ) `
        -NegativePatterns @(
            "upper",
            "^ub$"
        )
}

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$clsplRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.4.3-R2"
$stageRoot = Join-Path $reportRoot "reader-staging"
$canonicalRoot = Join-Path $stadtlerRoot "literature\canonical-v0.4.3-R2"
$metadataRoot = Join-Path $stadtlerRoot "metadata"

foreach ($p in @($reportRoot,$canonicalRoot,$metadataRoot)) {
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
    $instances = Join-Path $stadtlerRoot ($s.Folder + "\instances")
    $count = @(
        Get-ChildItem -LiteralPath $instances -Filter "*.xml" -File -ErrorAction SilentlyContinue
    ).Count

    Write-Host ($s.TestSet + ": XML=" + $count + "/" + $s.Count)

    if ($count -ne $s.Count) {
        throw ("Frozen Stadtler corpus mismatch for " + $s.TestSet)
    }

    $total += $count
}

if ($total -ne 2100) {
    throw "Frozen Stadtler corpus must contain exactly 2100 XML."
}

$clsplCatalogue = Join-Path $clsplRoot "metadata\CLSPL-LITERATURE-REFERENCES.csv"
$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)
$databRows = @($clsplRows | Where-Object { $_.test_set -eq "datab" })

if ($clsplRows.Count -ne 1281 -or $databRows.Count -ne 60) {
    throw (
        "CLSPL precondition failed: mapped=" +
        $clsplRows.Count +
        " datab=" +
        $databRows.Count
    )
}

Write-Host "CLSPL catalogue: 1281 / 1281; datab 60 / 60."

Write-Step "Discovering Stadtler workbooks"

$materializedRoot = Join-Path $stadtlerRoot "raw\materialized"
$allBooks = @(
    Get-ChildItem -LiteralPath $materializedRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "(?i)^solutions[a-z0-9_-]*\.xls[x]?$"
    }
)

if ($allBooks.Count -eq 0) {
    throw "No Stadtler solution workbooks found."
}

$books = New-Object System.Collections.Generic.List[object]

foreach ($book in $allBooks) {
    $books.Add([pscustomobject]@{
        test_set = Get-TestSet -WorkbookName $book.Name
        logical_name = $book.Name.ToLowerInvariant()
        path = $book.FullName
        sha256 = (Get-FileHash -LiteralPath $book.FullName -Algorithm SHA256).Hash
    })
}

Write-Host ("Physical workbook paths: " + $books.Count)

$readerProject = Join-Path $BenchmarkRepo "tools\StadtlerReferenceReader\StadtlerReferenceReader.csproj"

if (-not (Test-Path -LiteralPath $readerProject -PathType Leaf)) {
    throw "StadtlerReferenceReader is missing."
}

if ($DryRun) {
    Write-Host "Dry-run PASS."
    exit 0
}

Write-Step "Building StadtlerReferenceReader"

& dotnet build $readerProject -c Release --nologo

if ($LASTEXITCODE -ne 0) {
    throw "StadtlerReferenceReader build failed."
}

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}

Ensure-Directory -Path $stageRoot

Write-Step "Extracting reader output"

$runs = New-Object System.Collections.Generic.List[object]
$ordinal = 0

foreach ($book in ($books.ToArray() | Sort-Object logical_name,path)) {
    $ordinal++
    $stage = Join-Path $stageRoot (
        ("{0:D3}_" -f $ordinal) +
        [IO.Path]::GetFileNameWithoutExtension($book.logical_name)
    )

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

    if ($LASTEXITCODE -ne 0 -or $resolved -lt 0) {
        throw ("Reader failed or did not report resolved count for " + $book.path)
    }

    $runs.Add([pscustomobject]@{
        run_id = $ordinal
        test_set = $book.test_set
        workbook = $book.logical_name
        workbook_path = $book.path
        sha256 = $book.sha256
        stage = $stage
        resolved_expected = $resolved
    })

    Write-Host ($book.logical_name + ": resolved=" + $resolved)
}

Write-Step "Auto-detecting resolved CSV schema"

$schemaAudit = New-Object System.Collections.Generic.List[object]
$semanticRows = New-Object System.Collections.Generic.List[object]

foreach ($run in $runs.ToArray()) {
    $csvFiles = @(
        Get-ChildItem -LiteralPath $run.stage -Filter "*.csv" -File -Recurse -ErrorAction SilentlyContinue
    )

    if ($csvFiles.Count -eq 0) {
        throw ("No CSV output for " + $run.workbook)
    }

    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($csv in $csvFiles) {
        $rows = @(Import-Csv -LiteralPath $csv.FullName)
        $headers = ""

        if ($rows.Count -gt 0) {
            $headers = (
                $rows[0].PSObject.Properties.Name -join ";"
            )
        }

        $parsed = New-Object System.Collections.Generic.List[object]
        $seenCode = @{}
        $objectivePresent = 0
        $lowerBoundPresent = 0

        foreach ($row in $rows) {
            $code = Find-CodeInRow -Row $row

            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }

            $objective = Get-ObjectiveValue -Row $row
            $lowerBound = Get-LowerBoundValue -Row $row

            if (-not [string]::IsNullOrWhiteSpace($objective)) {
                $objectivePresent++
            }

            if (-not [string]::IsNullOrWhiteSpace($lowerBound)) {
                $lowerBoundPresent++
            }

            # Deduplicate by code inside one view. A resolved workbook should
            # describe one reference record per canonical instance code.
            if (-not $seenCode.ContainsKey($code)) {
                $seenCode[$code] = $true
                $parsed.Add([pscustomobject]@{
                    test_set = $run.test_set
                    canonical_code = $code
                    objective = $objective
                    lower_bound = $lowerBound
                    source_workbook = $run.workbook
                    source_workbook_sha256 = $run.sha256
                    reader_csv = $csv.FullName
                    run_id = $run.run_id
                })
            }
        }

        $score = (
            ($objectivePresent * 2) +
            $lowerBoundPresent
        )

        $candidates.Add([pscustomobject]@{
            csv_path = $csv.FullName
            raw_row_count = $rows.Count
            unique_code_count = $parsed.Count
            objective_nonblank = $objectivePresent
            lower_bound_nonblank = $lowerBoundPresent
            richness_score = $score
            rows = $parsed.ToArray()
            headers = $headers
        })

        $schemaAudit.Add([pscustomobject]@{
            run_id = $run.run_id
            workbook = $run.workbook
            csv_path = $csv.FullName
            headers = $headers
            raw_row_count = $rows.Count
            unique_code_count = $parsed.Count
            objective_nonblank = $objectivePresent
            lower_bound_nonblank = $lowerBoundPresent
            resolved_expected = $run.resolved_expected
        })
    }

    # Select the single best CSV whose unique canonical-code count matches resolved=N.
    $matching = @(
        $candidates.ToArray() |
        Where-Object {
            $_.unique_code_count -eq $run.resolved_expected
        } |
        Sort-Object `
            @{Expression={ $_.richness_score }; Descending=$true},
            @{Expression={ $_.raw_row_count }; Descending=$false},
            @{Expression={ $_.csv_path }; Descending=$false}
    )

    if ($matching.Count -eq 0) {
        Write-Host ""
        Write-Host ("CSV schema audit for failed run " + $run.run_id + " / " + $run.workbook)

        foreach ($candidate in $candidates.ToArray()) {
            Write-Host (
                "  " +
                [IO.Path]::GetFileName($candidate.csv_path) +
                " rows=" +
                $candidate.raw_row_count +
                " codes=" +
                $candidate.unique_code_count +
                " obj=" +
                $candidate.objective_nonblank +
                " lb=" +
                $candidate.lower_bound_nonblank +
                " headers=[" +
                $candidate.headers +
                "]"
            )
        }

        throw (
            "No reader CSV contains exactly " +
            $run.resolved_expected +
            " unique Stadtler codes for " +
            $run.workbook
        )
    }

    $selected = $matching[0]

    foreach ($row in $selected.rows) {
        $semanticRows.Add($row)
    }

    Write-Host (
        $run.workbook +
        " run " +
        $run.run_id +
        ": selected=" +
        [IO.Path]::GetFileName($selected.csv_path) +
        " codes=" +
        $selected.unique_code_count +
        " richness=" +
        $selected.richness_score
    )
}

$schemaAudit.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "reader-schema-audit.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Semantic deduplication across physical workbook copies"

$seen = @{}
$canonical = New-Object System.Collections.Generic.List[object]

foreach ($row in $semanticRows.ToArray()) {
    # Code is the stable semantic identity for one workbook family.
    # Prefer richer duplicates when a physical copy includes objective/lower-bound
    # fields missing from another copy.
    $key = $row.test_set + "|" + $row.canonical_code

    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $canonical.Count
        $canonical.Add($row)
        continue
    }

    $index = [int]$seen[$key]
    $existing = $canonical[$index]

    $existingScore = 0
    $newScore = 0

    if (-not [string]::IsNullOrWhiteSpace($existing.objective)) {
        $existingScore += 2
    }

    if (-not [string]::IsNullOrWhiteSpace($existing.lower_bound)) {
        $existingScore += 1
    }

    if (-not [string]::IsNullOrWhiteSpace($row.objective)) {
        $newScore += 2
    }

    if (-not [string]::IsNullOrWhiteSpace($row.lower_bound)) {
        $newScore += 1
    }

    if ($newScore -gt $existingScore) {
        $canonical[$index] = $row
    }
    elseif ($newScore -eq $existingScore) {
        # If two equally rich physical copies disagree, quarantine instead of
        # silently choosing one.
        $objectiveConflict = (
            $existing.objective -ne $row.objective
        )

        $boundConflict = (
            $existing.lower_bound -ne $row.lower_bound
        )

        if ($objectiveConflict -or $boundConflict) {
            throw (
                "Conflicting equally rich literature copies for " +
                $key
            )
        }
    }
}

$canonical.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $canonicalRoot "STADTLER-CANONICAL-LITERATURE.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Canonical literature rows: " + $canonical.Count)

if ($canonical.Count -ne 982) {
    throw (
        "Canonical literature postcondition failed: expected 982, found " +
        $canonical.Count
    )
}

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
        $canonical.ToArray() |
        Where-Object {
            $_.test_set -eq $key
        }
    ).Count

    Write-Host ($key + ": " + $count + "/" + $expectedLiterature[$key])

    if ($count -ne $expectedLiterature[$key]) {
        throw ("Literature distribution mismatch for " + $key)
    }
}

Write-Step "Mapping official literature to generated XML"

$xmlIndex = @{}

foreach ($s in $sets) {
    $instances = Join-Path $stadtlerRoot ($s.Folder + "\instances")

    foreach ($file in (
        Get-ChildItem -LiteralPath $instances -Filter "*.xml" -File
    )) {
        $code = Normalize-Code -Value $file.BaseName

        if ([string]::IsNullOrWhiteSpace($code)) {
            continue
        }

        $key = $s.TestSet + "|" + $code

        if (-not $xmlIndex.ContainsKey($key)) {
            $xmlIndex[$key] = New-Object System.Collections.Generic.List[object]
        }

        $xmlIndex[$key].Add([pscustomobject]@{
            lsdm_filename = $file.Name
            lsdm_path = $file.FullName
        })
    }
}

$mapped = New-Object System.Collections.Generic.List[object]
$unmapped = New-Object System.Collections.Generic.List[object]
$legacy = New-Object System.Collections.Generic.List[object]

foreach ($row in $canonical.ToArray()) {
    if ($row.test_set -eq "LEGACY-CM") {
        $legacy.Add([pscustomobject]@{
            test_set = "LEGACY-CM"
            canonical_code = $row.canonical_code
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $row.source_workbook
            status = "LEGACY_NON_OFFICIAL_REFERENCE"
        })
        continue
    }

    $key = $row.test_set + "|" + $row.canonical_code
    $candidates = @()

    if ($xmlIndex.ContainsKey($key)) {
        $candidates = @($xmlIndex[$key].ToArray())
    }

    if ($candidates.Count -eq 1) {
        $match = $candidates[0]

        $mapped.Add([pscustomobject]@{
            test_set = $row.test_set
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
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-REFERENCES-v0.4.3-R2.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$unmapped.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-UNMAPPED-v0.4.3-R2.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$legacy.ToArray() |
    Sort-Object canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LEGACY-CM-REFERENCES-v0.4.3-R2.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating final GitHub summary"

$family = New-Object System.Collections.Generic.List[string]

$family.Add("# Stadtler 2003 MLCLSP benchmark")
$family.Add("")
$family.Add("| Test set | Generated XML | Published mapped | Published unresolved |")
$family.Add("|---|---:|---:|---:|")

foreach ($s in $sets) {
    $mc = @($mapped.ToArray() | Where-Object { $_.test_set -eq $s.TestSet }).Count
    $uc = @($unmapped.ToArray() | Where-Object { $_.test_set -eq $s.TestSet }).Count

    $family.Add(
        "| " + $s.TestSet +
        " | " + $s.Count +
        " | " + $mc +
        " | " + $uc +
        " |"
    )
}

$family.Add(
    "| **Total generated** | **2100** | **" +
    $mapped.Count +
    "** | **" +
    $unmapped.Count +
    "** |"
)

$family.Add("")
$family.Add("## Literature")
$family.Add("")
$family.Add("- Canonical published-reference rows: **982**")
$family.Add("- Official mapped rows: **" + $mapped.Count + "**")
$family.Add("- Official unresolved rows: **" + $unmapped.Count + "**")
$family.Add("- Legacy classcm rows: **" + $legacy.Count + "**")
$family.Add("")
$family.Add("Published objectives/lower bounds remain unverified literature evidence until a complete solution is independently checked.")
$family.Add("")
$family.Add("## Genealogy")
$family.Add("")
$family.Add("- Stadtler B+ -> SUERIE_CLSPL/datab: published 60-instance subset relation.")
$family.Add("- Exact SupplyChainFingerprint equality is tracked separately from bibliographic genealogy.")

[IO.File]::WriteAllLines(
    (Join-Path $stadtlerRoot "README.md"),
    $family.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.4.3 R2 final summary"
Write-Host "Stadtler XML preserved: 2100 / 2100"
Write-Host "CLSPL catalogue preserved: 1281 / 1281"
Write-Host ("Physical workbook paths: " + $books.Count)
Write-Host ("Reader runs: " + $runs.Count)
Write-Host ("Canonical literature rows: " + $canonical.Count)
Write-Host ("Official literature mapped: " + $mapped.Count)
Write-Host ("Official literature unresolved: " + $unmapped.Count)
Write-Host ("Legacy classcm rows: " + $legacy.Count)
Write-Host ("Reports: " + $reportRoot)
