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

function Normalize-Stadtler-Code {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $normalized = $Value.ToUpperInvariant()
    $normalized = [regex]::Replace($normalized, "[^A-Z0-9]", "")

    $match = [regex]::Match(
        $normalized,
        "([GK][05][0-4][12][1-5][234][012])"
    )

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ""
}

function Get-TestSetFromWorkbookName {
    param([string]$WorkbookName)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension(
        $WorkbookName
    ).ToLowerInvariant()

    switch -Regex ($baseName) {
        "^solutionsap$" { return "A+" }
        "^solutionsbp$" { return "B+" }
        "^solutionscm$" { return "LEGACY-CM" }
        "^solutionscp$" { return "C+" }
        "^solutionsc$"  { return "C" }
        "^solutionsdp$" { return "D+" }
        "^solutionsd$"  { return "D" }
        "^solutionsep$" { return "E+" }
        "^solutionse$"  { return "E" }
        default          { return "UNKNOWN" }
    }
}

function Get-TestSetFolder {
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

function Get-PropertyValue {
    param(
        [object]$Row,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Row.PSObject.Properties[$name]

        if ($null -ne $property) {
            $value = [string]$property.Value

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ""
}

function Test-StadtlerCorpus {
    param([string]$StadtlerRoot)

    $expected = @(
        [pscustomobject]@{ TestSet="A+"; Folder="Aplus"; Count=240 },
        [pscustomobject]@{ TestSet="B+"; Folder="Bplus"; Count=600 },
        [pscustomobject]@{ TestSet="C"; Folder="C"; Count=360 },
        [pscustomobject]@{ TestSet="C+"; Folder="Cplus"; Count=240 },
        [pscustomobject]@{ TestSet="D"; Folder="D"; Count=360 },
        [pscustomobject]@{ TestSet="D+"; Folder="Dplus"; Count=240 },
        [pscustomobject]@{ TestSet="E"; Folder="E"; Count=30 },
        [pscustomobject]@{ TestSet="E+"; Folder="Eplus"; Count=30 }
    )

    $total = 0

    foreach ($spec in $expected) {
        $instancesRoot = Join-Path $StadtlerRoot (
            $spec.Folder + "\instances"
        )

        $count = @(
            Get-ChildItem `
                -LiteralPath $instancesRoot `
                -Filter "*.xml" `
                -File `
                -ErrorAction SilentlyContinue
        ).Count

        Write-Host (
            $spec.TestSet +
            ": XML=" +
            $count +
            "/" +
            $spec.Count
        )

        if ($count -ne $spec.Count) {
            throw (
                "Stadtler corpus mismatch for " +
                $spec.TestSet +
                ": expected " +
                $spec.Count +
                ", found " +
                $count
            )
        }

        $total += $count
    }

    if ($total -ne 2100) {
        throw (
            "Stadtler total mismatch: expected 2100, found " +
            $total
        )
    }

    return $expected
}

function Test-ClsplCatalogue {
    param([string]$ClsplRoot)

    $catalogue = Join-Path $ClsplRoot `
        "metadata\CLSPL-LITERATURE-REFERENCES.csv"

    if (-not (Test-Path -LiteralPath $catalogue -PathType Leaf)) {
        throw "CLSPL literature catalogue is missing."
    }

    $rows = @(Import-Csv -LiteralPath $catalogue)
    $datab = @(
        $rows |
        Where-Object { $_.test_set -eq "datab" }
    )

    if ($rows.Count -ne 1281 -or $datab.Count -ne 60) {
        throw (
            "CLSPL postcondition failed: mapped=" +
            $rows.Count +
            ", datab=" +
            $datab.Count
        )
    }

    Write-Host "CLSPL catalogue validated: 1281 / 1281; datab 60 / 60."
}

$stadtlerRoot = Join-Path $BenchmarkRepo `
    "benchmarks\STADTLER2003"

$clsplRoot = Join-Path $BenchmarkRepo `
    "benchmarks\SUERIE_CLSPL"

$materializedRoot = Join-Path $stadtlerRoot `
    "raw\materialized"

$reportRoot = Join-Path $BenchmarkRepo `
    "reports\v0.4.3"

$metadataRoot = Join-Path $stadtlerRoot "metadata"
$literatureRoot = Join-Path $stadtlerRoot "literature"
$canonicalLiteratureRoot = Join-Path $literatureRoot "canonical-v0.4.3"
$readerStageRoot = Join-Path $reportRoot "reader-staging"

foreach ($path in @(
    $reportRoot,
    $metadataRoot,
    $literatureRoot,
    $canonicalLiteratureRoot
)) {
    Ensure-Directory -Path $path
}

Write-Step "Preflight: validating existing benchmark state"
$expectedSets = Test-StadtlerCorpus -StadtlerRoot $stadtlerRoot
Test-ClsplCatalogue -ClsplRoot $clsplRoot

Write-Step "Discovering Stadtler solution workbooks"

$allWorkbooks = @(
    Get-ChildItem `
        -LiteralPath $materializedRoot `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "(?i)^solutions[a-z0-9+_-]*\.xls[x]?$"
    }
)

if ($allWorkbooks.Count -eq 0) {
    throw "No Stadtler solutions*.xls workbooks were found."
}

$workbookRows = New-Object System.Collections.Generic.List[object]

foreach ($workbook in $allWorkbooks) {
    $hash = (
        Get-FileHash `
            -LiteralPath $workbook.FullName `
            -Algorithm SHA256
    ).Hash

    $testSet = Get-TestSetFromWorkbookName `
        -WorkbookName $workbook.Name

    $workbookRows.Add([pscustomobject]@{
        test_set = $testSet
        file_name = $workbook.Name
        full_path = $workbook.FullName
        sha256 = $hash
        length = $workbook.Length
    })
}

$workbookRows.ToArray() |
    Sort-Object test_set,file_name,full_path |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-workbook-inventory.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$groups = @(
    $workbookRows.ToArray() |
    Group-Object sha256
)

$uniqueWorkbooks = New-Object System.Collections.Generic.List[object]
$duplicateMap = New-Object System.Collections.Generic.List[object]

foreach ($group in $groups) {
    $ordered = @(
        $group.Group |
        Sort-Object `
            @{Expression={ $_.full_path.Length }},
            @{Expression={ $_.full_path }}
    )

    $selected = $ordered[0]

    $uniqueWorkbooks.Add([pscustomobject]@{
        test_set = $selected.test_set
        file_name = $selected.file_name
        full_path = $selected.full_path
        sha256 = $selected.sha256
        duplicate_path_count = $ordered.Count
    })

    foreach ($candidate in $ordered) {
        $duplicateMap.Add([pscustomobject]@{
            sha256 = $group.Name
            selected_path = $selected.full_path
            candidate_path = $candidate.full_path
            is_selected = (
                $candidate.full_path -eq $selected.full_path
            )
        })
    }
}

$uniqueWorkbooks.ToArray() |
    Sort-Object test_set,file_name |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-unique-workbooks.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$duplicateMap.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-workbook-duplicate-map.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Workbook paths found: " +
    $allWorkbooks.Count
)

Write-Host (
    "Unique workbook contents (SHA256): " +
    $uniqueWorkbooks.Count
)

$officialWorkbookSets = @(
    $uniqueWorkbooks.ToArray() |
    Where-Object {
        $_.test_set -ne "UNKNOWN"
    }
)

if ($officialWorkbookSets.Count -lt 8) {
    throw (
        "Expected at least the eight known Stadtler workbook families; found " +
        $officialWorkbookSets.Count
    )
}

$readerProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerReferenceReader\StadtlerReferenceReader.csproj"

if (-not (Test-Path -LiteralPath $readerProject -PathType Leaf)) {
    throw (
        "StadtlerReferenceReader is missing: " +
        $readerProject
    )
}

Write-Host "StadtlerReferenceReader located."

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Corpus, CLSPL catalogue, workbooks and reference reader are ready."
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

if (Test-Path -LiteralPath $readerStageRoot) {
    Remove-Item `
        -LiteralPath $readerStageRoot `
        -Recurse `
        -Force
}

Ensure-Directory -Path $readerStageRoot

Write-Step "Extracting canonical references from unique workbooks"

$readerRuns = New-Object System.Collections.Generic.List[object]

foreach ($workbook in (
    $uniqueWorkbooks.ToArray() |
    Sort-Object test_set,file_name
)) {
    $safeName = (
        [System.IO.Path]::GetFileNameWithoutExtension(
            $workbook.file_name
        )
    )

    $stage = Join-Path $readerStageRoot $safeName

    Ensure-Directory -Path $stage

    $before = @(
        Get-ChildItem `
            -LiteralPath $stage `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
    ).Count

    $outputLines = @(
        & dotnet run `
            --project $readerProject `
            -c Release `
            --no-build `
            -- `
            $workbook.full_path `
            $stage 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    [System.IO.File]::WriteAllLines(
        (Join-Path $stage "reader-console.log"),
        $outputLines,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $afterFiles = @(
        Get-ChildItem `
            -LiteralPath $stage `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
    )

    $csvCount = @(
        $afterFiles |
        Where-Object { $_.Extension -ieq ".csv" }
    ).Count

    $resolvedFromConsole = -1

    foreach ($line in $outputLines) {
        if ($line -match "resolved=(\d+)") {
            $resolvedFromConsole = [int]$Matches[1]
        }
    }

    $readerRuns.Add([pscustomobject]@{
        test_set = $workbook.test_set
        workbook = $workbook.file_name
        workbook_path = $workbook.full_path
        sha256 = $workbook.sha256
        stage = $stage
        output_csv_count = $csvCount
        resolved_console = $resolvedFromConsole
        exit_code = $LASTEXITCODE
    })

    Write-Host (
        $workbook.file_name +
        ": resolved=" +
        $resolvedFromConsole +
        ", csv=" +
        $csvCount
    )

    if ($LASTEXITCODE -ne 0) {
        throw (
            "StadtlerReferenceReader failed for " +
            $workbook.file_name
        )
    }
}

$readerRuns.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-reader-runs.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Collecting all reader CSV outputs"

$readerCsvFiles = @(
    Get-ChildItem `
        -LiteralPath $readerStageRoot `
        -Filter "*.csv" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue
)

if ($readerCsvFiles.Count -eq 0) {
    throw (
        "StadtlerReferenceReader produced no CSV files. " +
        "See reader-console.log files under " +
        $readerStageRoot
    )
}

$rawRows = New-Object System.Collections.Generic.List[object]

foreach ($csv in $readerCsvFiles) {
    $stageFolder = $csv.Directory.Name
    $workbookRun = @(
        $readerRuns.ToArray() |
        Where-Object {
            (
                [System.IO.Path]::GetFileNameWithoutExtension(
                    $_.workbook
                )
            ) -eq $stageFolder
        } |
        Select-Object -First 1
    )

    if ($workbookRun.Count -ne 1) {
        continue
    }

    $run = $workbookRun[0]

    foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
        $sourceId = Get-PropertyValue `
            -Row $row `
            -Names @(
                "source_instance_id",
                "instance_id",
                "instance",
                "code",
                "name"
            )

        $objective = Get-PropertyValue `
            -Row $row `
            -Names @(
                "objective",
                "best_known",
                "best_known_objective",
                "value",
                "obj"
            )

        $lowerBound = Get-PropertyValue `
            -Row $row `
            -Names @(
                "lower_bound",
                "lowerbound",
                "lb",
                "bound"
            )

        $sheet = Get-PropertyValue `
            -Row $row `
            -Names @(
                "sheet",
                "source_sheet",
                "worksheet"
            )

        if ([string]::IsNullOrWhiteSpace($sourceId)) {
            continue
        }

        $rawRows.Add([pscustomobject]@{
            test_set = $run.test_set
            source_instance_id = $sourceId
            canonical_code = (
                Normalize-Stadtler-Code -Value $sourceId
            )
            objective = $objective
            lower_bound = $lowerBound
            source_workbook = $run.workbook
            source_workbook_sha256 = $run.sha256
            source_sheet = $sheet
            reader_csv = $csv.FullName
        })
    }
}

$rawRows.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $canonicalLiteratureRoot "stadtler-reader-raw-rows.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Reader rows collected before deduplication: " +
    $rawRows.Count
)

Write-Step "Deduplicating canonical literature rows"

$seen = @{}
$canonicalRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $rawRows.ToArray()) {
    $key = (
        $row.test_set + "|" +
        $row.source_instance_id + "|" +
        $row.objective + "|" +
        $row.lower_bound
    )

    if ($seen.ContainsKey($key)) {
        continue
    }

    $seen[$key] = $true
    $canonicalRows.Add($row)
}

$canonicalRows.ToArray() |
    Sort-Object test_set,canonical_code,source_instance_id |
    Export-Csv `
        -LiteralPath (Join-Path $canonicalLiteratureRoot "STADTLER-CANONICAL-LITERATURE.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Canonical unique literature rows: " +
    $canonicalRows.Count
)

if ($canonicalRows.Count -ne 982) {
    throw (
        "Literature extraction postcondition failed: expected 982 canonical rows, found " +
        $canonicalRows.Count
    )
}

Write-Step "Building official XML code index"

$xmlIndex = @{}
$xmlInventory = New-Object System.Collections.Generic.List[object]

foreach ($spec in $expectedSets) {
    $folder = Get-TestSetFolder -TestSet $spec.TestSet
    $instancesRoot = Join-Path $stadtlerRoot (
        $folder + "\instances"
    )

    foreach ($file in (
        Get-ChildItem `
            -LiteralPath $instancesRoot `
            -Filter "*.xml" `
            -File
    )) {
        $code = Normalize-Stadtler-Code `
            -Value $file.BaseName

        if ([string]::IsNullOrWhiteSpace($code)) {
            try {
                [xml]$doc = Get-Content `
                    -LiteralPath $file.FullName `
                    -Raw `
                    -Encoding UTF8

                if ($null -ne $doc.DocumentElement) {
                    $code = Normalize-Stadtler-Code `
                        -Value $doc.DocumentElement.GetAttribute(
                            "instanceId"
                        )

                    if ([string]::IsNullOrWhiteSpace($code)) {
                        $code = Normalize-Stadtler-Code `
                            -Value $doc.DocumentElement.GetAttribute(
                                "name"
                            )
                    }
                }
            }
            catch {
            }
        }

        $record = [pscustomobject]@{
            test_set = $spec.TestSet
            canonical_code = $code
            lsdm_filename = $file.Name
            lsdm_path = $file.FullName
        }

        $xmlInventory.Add($record)

        if (-not [string]::IsNullOrWhiteSpace($code)) {
            $indexKey = (
                $spec.TestSet +
                "|" +
                $code
            )

            if (-not $xmlIndex.ContainsKey($indexKey)) {
                $xmlIndex[$indexKey] =
                    New-Object System.Collections.Generic.List[object]
            }

            $xmlIndex[$indexKey].Add($record)
        }
    }
}

$xmlInventory.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-xml-code-inventory.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Mapping canonical literature to official generated XML"

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
            source_workbook_sha256 = $row.source_workbook_sha256
            status = "LEGACY_NON_OFFICIAL_REFERENCE"
        })

        continue
    }

    if ($row.test_set -eq "UNKNOWN") {
        $unmapped.Add([pscustomobject]@{
            test_set = "UNKNOWN"
            source_instance_id = $row.source_instance_id
            canonical_code = $row.canonical_code
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $row.source_workbook
            candidate_count = 0
            status = "UNKNOWN_WORKBOOK_FAMILY"
        })

        continue
    }

    if ([string]::IsNullOrWhiteSpace(
        $row.canonical_code
    )) {
        $unmapped.Add([pscustomobject]@{
            test_set = $row.test_set
            source_instance_id = $row.source_instance_id
            canonical_code = ""
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $row.source_workbook
            candidate_count = 0
            status = "NO_SEVEN_POSITION_CODE"
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
                if ([string]::IsNullOrWhiteSpace(
                    $row.objective
                )) {
                    ""
                }
                else {
                    "LITERATURE_BEST_KNOWN"
                }
            )
            lower_bound_status = $(
                if ([string]::IsNullOrWhiteSpace(
                    $row.lower_bound
                )) {
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
            mapping_status = "UNIQUE_CLASS_PLUS_SEVEN_POSITION_CODE"
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
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-REFERENCES-v0.4.3.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$unmapped.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-UNMAPPED-v0.4.3.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$legacy.ToArray() |
    Sort-Object canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LEGACY-CM-REFERENCES-v0.4.3.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Official literature mapped: " +
    $mapped.Count
)

Write-Host (
    "Official literature unresolved: " +
    $unmapped.Count
)

Write-Host (
    "Legacy classcm rows: " +
    $legacy.Count
)

Write-Step "Building published genealogy catalogue"

$fingerprintCrosswalk = Join-Path $BenchmarkRepo `
    "reports\v0.4.2\fingerprints\stadtler-clspl-exact-crosswalk.csv"

$exactPairCount = 0

if (Test-Path -LiteralPath $fingerprintCrosswalk -PathType Leaf) {
    $exactPairCount = @(
        Import-Csv -LiteralPath $fingerprintCrosswalk
    ).Count
}

$genealogy = @(
    [pscustomobject]@{
        parent_family = "STADTLER2003"
        parent_subset = "B+"
        child_family = "SUERIE_CLSPL"
        child_subset = "datab"
        relation_type = "PUBLISHED_SUBSET"
        relation_scope = "60 instances"
        exact_supply_chain_fingerprint_pairs = $exactPairCount
        evidence_status = "BIBLIOGRAPHICALLY_ESTABLISHED"
        note = "The published CLSPL benchmark description states that datab contains 60 MLCLSP instances taken from Stadtler class B+. Fingerprint equality is not required because the LSDM conversion paths reconstruct/represent parameters differently."
    },
    [pscustomobject]@{
        parent_family = "TD1996"
        parent_subset = "selected instances"
        child_family = "STADTLER2003"
        child_subset = "C/D/E"
        relation_type = "PUBLISHED_EXACT_MATCH_FOR_CORRESPONDING_ATTRIBUTES"
        relation_scope = "subset not yet file-mapped"
        exact_supply_chain_fingerprint_pairs = 0
        evidence_status = "WAITING_FOR_TD1996_CORPUS"
        note = "The Stadtler benchmark documentation reports that some C, D and E instances correspond exactly to Tempelmeier-Derstroff instances with matching attributes."
    }
)

$genealogy |
    Export-Csv `
        -LiteralPath (Join-Path $BenchmarkRepo "catalog\stadtler-ecosystem-genealogy-v0.4.3.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating final per-class GitHub pages"

foreach ($spec in $expectedSets) {
    $folder = Get-TestSetFolder `
        -TestSet $spec.TestSet

    $classRoot = Join-Path $stadtlerRoot $folder
    $classMetadata = Join-Path $classRoot "metadata"

    Ensure-Directory -Path $classMetadata

    $classMapped = @(
        $mapped.ToArray() |
        Where-Object {
            $_.test_set -eq $spec.TestSet
        }
    )

    $classUnmapped = @(
        $unmapped.ToArray() |
        Where-Object {
            $_.test_set -eq $spec.TestSet
        }
    )

    $classMapped |
        Export-Csv `
            -LiteralPath (Join-Path $classMetadata "literature-references-v0.4.3.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    $classUnmapped |
        Export-Csv `
            -LiteralPath (Join-Path $classMetadata "literature-unmapped-v0.4.3.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    $page = New-Object System.Collections.Generic.List[string]

    $page.Add("# Stadtler " + $spec.TestSet)
    $page.Add("")
    $page.Add("| Metric | Count |")
    $page.Add("|---|---:|")
    $page.Add("| Generated admissible XML | **" + $spec.Count + "** |")
    $page.Add("| Published reference rows mapped | **" + $classMapped.Count + "** |")
    $page.Add("| Published reference rows unresolved | **" + $classUnmapped.Count + "** |")
    $page.Add("| Verified complete solutions | **0 unless separately checker-verified** |")
    $page.Add("")
    $page.Add("Generated admissible instances and the published-reference subset are distinct concepts.")
    $page.Add("")
    $page.Add("Published objective values and lower bounds remain literature evidence until a complete solution is independently checked.")

    [System.IO.File]::WriteAllLines(
        (Join-Path $classRoot "README.md"),
        $page.ToArray(),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

Write-Step "Generating final Stadtler family page"

$familyPage = New-Object System.Collections.Generic.List[string]

$familyPage.Add("# Stadtler 2003 MLCLSP benchmark")
$familyPage.Add("")
$familyPage.Add("> Canonical generated universe plus literature reconciliation, v0.4.3.")
$familyPage.Add("")
$familyPage.Add("## Generated admissible universe")
$familyPage.Add("")
$familyPage.Add("| Test set | Generated XML | Published mapped | Published unresolved |")
$familyPage.Add("|---|---:|---:|---:|")

foreach ($spec in $expectedSets) {
    $mappedCount = @(
        $mapped.ToArray() |
        Where-Object {
            $_.test_set -eq $spec.TestSet
        }
    ).Count

    $unmappedCount = @(
        $unmapped.ToArray() |
        Where-Object {
            $_.test_set -eq $spec.TestSet
        }
    ).Count

    $familyPage.Add(
        "| " +
        $spec.TestSet +
        " | " +
        $spec.Count +
        " | " +
        $mappedCount +
        " | " +
        $unmappedCount +
        " |"
    )
}

$familyPage.Add(
    "| **Total generated** | **2100** | **" +
    $mapped.Count +
    "** | **" +
    $unmapped.Count +
    "** |"
)

$familyPage.Add("")
$familyPage.Add("## Literature")
$familyPage.Add("")
$familyPage.Add("- Canonical unique workbook references: **982**")
$familyPage.Add("- Official rows mapped uniquely: **" + $mapped.Count + "**")
$familyPage.Add("- Official rows unresolved or ambiguous: **" + $unmapped.Count + "**")
$familyPage.Add("- Legacy classcm rows kept separately: **" + $legacy.Count + "**")
$familyPage.Add("")
$familyPage.Add("The 2,100 generated XML files are not all claimed to possess a published best-known objective.")
$familyPage.Add("")
$familyPage.Add("## Genealogy")
$familyPage.Add("")
$familyPage.Add("- **Stadtler B+ -> CLSPL datab:** published 60-instance subset.")
$familyPage.Add("- Exact LSDM SupplyChainFingerprint pairs currently observed: **" + $exactPairCount + "**.")
$familyPage.Add("- A zero exact-fingerprint count does not invalidate the published genealogy because the two conversion paths represent/reconstruct source parameters differently.")
$familyPage.Add("- Tempelmeier-Derstroff crosswalk remains pending acquisition of the TD1996 corpus.")

[System.IO.File]::WriteAllLines(
    (Join-Path $stadtlerRoot "README.md"),
    $familyPage.ToArray(),
    (New-Object System.Text.UTF8Encoding($false))
)

$summary = @(
    "# v0.4.3 final literature summary",
    "",
    "- Stadtler generated XML preserved: 2100 / 2100",
    "- CLSPL catalogue preserved: 1281 / 1281",
    "- Workbook paths discovered: " + $allWorkbooks.Count,
    "- Unique workbook contents by SHA256: " + $uniqueWorkbooks.Count,
    "- Canonical literature rows: " + $canonicalRows.Count,
    "- Official literature mapped: " + $mapped.Count,
    "- Official literature unresolved: " + $unmapped.Count,
    "- Legacy classcm rows: " + $legacy.Count,
    "- Exact Stadtler-CLSPL fingerprint pairs from v0.4.2: " + $exactPairCount,
    "",
    "No source generator, converter or checker was executed."
)

[System.IO.File]::WriteAllLines(
    (Join-Path $reportRoot "README.md"),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "v0.4.3 final summary"
Write-Host "Stadtler generated XML preserved: 2100 / 2100"
Write-Host "CLSPL catalogue preserved: 1281 / 1281"
Write-Host ("Workbook paths found: " + $allWorkbooks.Count)
Write-Host ("Unique workbook contents: " + $uniqueWorkbooks.Count)
Write-Host ("Canonical literature rows: " + $canonicalRows.Count)
Write-Host ("Official literature mapped: " + $mapped.Count)
Write-Host ("Official literature unresolved: " + $unmapped.Count)
Write-Host ("Legacy classcm rows: " + $legacy.Count)
Write-Host ("Published B+ -> datab relation: 60 instances")
Write-Host ("Exact fingerprint pairs from v0.4.2: " + $exactPairCount)
Write-Host ("Reports: " + $reportRoot)
