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

function Read-TextRobust {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = ""

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
        $text = $utf8.GetString($bytes)
    }
    catch {
        $text = [System.Text.Encoding]::Default.GetString($bytes)
    }

    # Use regex/string arguments only. Never call String.Replace(char,string),
    # which is ambiguous under Windows PowerShell 5.1.
    $text = [regex]::Replace($text, "^\uFEFF", "")
    $nbsp = [string][char]0x00A0
    $text = [regex]::Replace($text, [regex]::Escape($nbsp), " ")

    return $text
}

function Test-CheckerEvidence {
    param(
        [string]$ClassRoot,
        [int]$ExpectedXml
    )

    $summary = Join-Path $ClassRoot "checker-reports\campaign-summary.txt"
    $manifest = Join-Path $ClassRoot "checker-reports\campaign-items.tsv"

    if (Test-Path -LiteralPath $summary -PathType Leaf) {
        $text = Read-TextRobust -Path $summary

        if ($text -match "(?im)^[ \t]*Overall[ \t]*:[ \t]*VALID[ \t]*\r?$") {
            return [pscustomobject]@{
                Valid = $true
                Evidence = "SUMMARY_OVERALL_VALID"
            }
        }

        $loaded = $null
        $execFailures = $null
        $loadFailures = $null

        if ($text -match "(?im)^[ \t]*Loaded instances[ \t]*:[ \t]*(\d+)[ \t]*\r?$") {
            $loaded = [int]$Matches[1]
        }

        if ($text -match "(?im)^[ \t]*Execution failures[ \t]*:[ \t]*(\d+)[ \t]*\r?$") {
            $execFailures = [int]$Matches[1]
        }

        if ($text -match "(?im)^[ \t]*File load failures[ \t]*:[ \t]*(\d+)[ \t]*\r?$") {
            $loadFailures = [int]$Matches[1]
        }

        if ($null -ne $loaded -and
            $null -ne $execFailures -and
            $null -ne $loadFailures -and
            $loaded -eq $ExpectedXml -and
            $execFailures -eq 0 -and
            $loadFailures -eq 0) {
            return [pscustomobject]@{
                Valid = $true
                Evidence = "SUMMARY_COUNTS_VALID"
            }
        }
    }

    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $lines = @(
            Get-Content -LiteralPath $manifest -ErrorAction SilentlyContinue
        )

        $bad = @(
            $lines |
            Where-Object {
                $_ -match "(?i)(LOAD_FAILED|EXECUTION_FAILED|EXCEPTION|ERROR)"
            }
        )

        if ($bad.Count -eq 0 -and $ExpectedXml -gt 0) {
            return [pscustomobject]@{
                Valid = $true
                Evidence = "MANIFEST_NO_FAILURE_MARKERS"
            }
        }
    }

    return [pscustomobject]@{
        Valid = $false
        Evidence = "NO_VALID_CHECKER_EVIDENCE"
    }
}

function Normalize-Stadtler-Code {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $v = $Value.ToUpperInvariant()
    $v = [regex]::Replace($v, "[^A-Z0-9]", "")

    $patterns = @(
        "([GK][05][0-4][12][1-5][234][012])",
        "([GK][05][0-4][12][1-5][234])([012])"
    )

    foreach ($pattern in $patterns) {
        $m = [regex]::Match($v, $pattern)

        if ($m.Success) {
            return $m.Groups[1].Value + $(if ($m.Groups.Count -gt 2) { $m.Groups[2].Value } else { "" })
        }
    }

    return ""
}

function Get-ClassFromWorkbook {
    param([string]$Workbook)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Workbook).ToLowerInvariant()

    switch -Regex ($name) {
        "^solutionsap$" { return "A+" }
        "^solutionsbp$" { return "B+" }
        "^solutionscm$" { return "LEGACY-CM" }
        "^solutionscp$" { return "C+" }
        "^solutionsc$" { return "C" }
        "^solutionsdp$" { return "D+" }
        "^solutionsd$" { return "D" }
        "^solutionsep$" { return "E+" }
        "^solutionse$" { return "E" }
        default { return "UNKNOWN" }
    }
}

function Get-ClassFolder {
    param([string]$Class)

    switch ($Class) {
        "A+" { return "Aplus" }
        "B+" { return "Bplus" }
        "C" { return "C" }
        "C+" { return "Cplus" }
        "D" { return "D" }
        "D+" { return "Dplus" }
        "E" { return "E" }
        "E+" { return "Eplus" }
        default { return "" }
    }
}

function Restore-ClsplCatalogueIfNeeded {
    param([string]$ClsplRoot)

    $mappedPath = Join-Path $ClsplRoot "metadata\CLSPL-LITERATURE-REFERENCES.csv"
    $sidecarPath = Join-Path $ClsplRoot "TestSet3-datab\metadata\literature-references.csv"

    if (-not (Test-Path -LiteralPath $mappedPath -PathType Leaf)) {
        throw "CLSPL global reference catalogue is missing."
    }

    $mapped = @(Import-Csv -LiteralPath $mappedPath)
    $datab = @($mapped | Where-Object { $_.test_set -eq "datab" })

    if ($mapped.Count -eq 1281 -and $datab.Count -eq 60) {
        Write-Host "CLSPL reference catalogue: 1281 / 1281; datab: 60 / 60."
        return
    }

    if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
        throw (
            "CLSPL catalogue is incomplete and the proven datab sidecar is unavailable. " +
            "Refusing to modify the catalogue."
        )
    }

    $databSidecar = @(Import-Csv -LiteralPath $sidecarPath)

    if ($databSidecar.Count -ne 60) {
        throw (
            "CLSPL datab sidecar must contain 60 rows; found " +
            $databSidecar.Count
        )
    }

    $nonDatab = @(
        $mapped |
        Where-Object { $_.test_set -ne "datab" }
    )

    if ($nonDatab.Count -ne 1221) {
        throw (
            "Cannot safely restore CLSPL catalogue: expected 1221 non-datab rows; found " +
            $nonDatab.Count
        )
    }

    $combined = New-Object System.Collections.Generic.List[object]

    foreach ($row in $nonDatab) {
        $combined.Add($row)
    }

    foreach ($row in $databSidecar) {
        $combined.Add([pscustomobject]@{
            test_set = "datab"
            source_instance_id = $row.source_instance_id
            lsdm_filename = $row.lsdm_filename
            xml_name = ""
            xml_instance_id = ""
            xml_source_information = $row.raw_directory
            xml_detected_test_set = "datab"
            mapping_method = $row.mapping_method
            mapping_evidence = "RESTORED_FROM_PROVEN_DATAB_SIDECAR"
            objective = $row.objective
            lower_bound = $row.lower_bound
            objective_status = $row.objective_status
            lower_bound_status = $row.lower_bound_status
            verified = "False"
            source_workbook = "solb.xls"
            source_sheet = ""
        })
    }

    $combined.ToArray() |
        Sort-Object test_set,source_instance_id |
        Export-Csv -LiteralPath $mappedPath -NoTypeInformation -Encoding UTF8

    $final = @(Import-Csv -LiteralPath $mappedPath)
    $finalDatab = @($final | Where-Object { $_.test_set -eq "datab" })

    if ($final.Count -ne 1281 -or $finalDatab.Count -ne 60) {
        throw "CLSPL catalogue restoration postcondition failed."
    }

    Write-Host "CLSPL catalogue restored: 1281 / 1281; datab: 60 / 60."
}

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$clsplRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.4.2"
$metadataRoot = Join-Path $stadtlerRoot "metadata"
$literatureRoot = Join-Path $stadtlerRoot "literature"
$fingerprintRoot = Join-Path $reportRoot "fingerprints"

foreach ($path in @($reportRoot,$metadataRoot,$fingerprintRoot)) {
    Ensure-Directory -Path $path
}

Write-Step "Validating/restoring CLSPL reference catalogue"
Restore-ClsplCatalogueIfNeeded -ClsplRoot $clsplRoot

Write-Step "Validating existing Stadtler generated corpus and checker evidence"

$expected = @(
    [pscustomobject]@{ Class="A+"; Folder="Aplus"; Count=240 },
    [pscustomobject]@{ Class="B+"; Folder="Bplus"; Count=600 },
    [pscustomobject]@{ Class="C"; Folder="C"; Count=360 },
    [pscustomobject]@{ Class="C+"; Folder="Cplus"; Count=240 },
    [pscustomobject]@{ Class="D"; Folder="D"; Count=360 },
    [pscustomobject]@{ Class="D+"; Folder="Dplus"; Count=240 },
    [pscustomobject]@{ Class="E"; Folder="E"; Count=30 },
    [pscustomobject]@{ Class="E+"; Folder="Eplus"; Count=30 }
)

$validation = New-Object System.Collections.Generic.List[object]
$totalXml = 0

foreach ($spec in $expected) {
    $classRoot = Join-Path $stadtlerRoot $spec.Folder
    $instancesRoot = Join-Path $classRoot "instances"

    $xmlCount = @(
        Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
    ).Count

    $evidence = Test-CheckerEvidence -ClassRoot $classRoot -ExpectedXml $spec.Count

    $status = "OK"

    if ($xmlCount -ne $spec.Count) {
        $status = "COUNT_MISMATCH"
    }
    elseif (-not $evidence.Valid) {
        $status = "CHECKER_EVIDENCE_INVALID"
    }

    Write-Host (
        $spec.Class +
        ": XML=" + $xmlCount + "/" + $spec.Count +
        " checker=" + $evidence.Valid +
        " evidence=" + $evidence.Evidence
    )

    if ($status -ne "OK") {
        throw (
            "Stadtler corpus preflight failed for " +
            $spec.Class + ": " + $status
        )
    }

    $totalXml += $xmlCount

    $validation.Add([pscustomobject]@{
        test_set = $spec.Class
        expected_xml = $spec.Count
        actual_xml = $xmlCount
        checker_valid = $evidence.Valid
        checker_evidence = $evidence.Evidence
        status = $status
    })
}

if ($totalXml -ne 2100) {
    throw ("Expected 2100 Stadtler XML; found " + $totalXml)
}

$validation.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-corpus-validation.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host "Stadtler generated corpus validated: 2100 / 2100."
Write-Host "No generator, converter, checker or canonical XML rewrite is used by v0.4.2."

Write-Step "Validating literature extraction inputs"

$resolvedCsvs = @(
    Get-ChildItem `
        -LiteralPath $literatureRoot `
        -Filter "*-resolved-references.csv" `
        -File `
        -ErrorAction SilentlyContinue
)

if ($resolvedCsvs.Count -eq 0) {
    throw (
        "No Stadtler resolved-reference CSV files were found. " +
        "The previous workbook extraction must exist before v0.4.2."
    )
}

Write-Host ("Resolved-reference CSV files found: " + $resolvedCsvs.Count)

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "Corpus, checker evidence, CLSPL catalogue and literature inputs are valid."
    exit 0
}

Write-Step "Building canonical XML manifests"

$stadtlerManifest = Join-Path $fingerprintRoot "stadtler-canonical-files.txt"
$clsplManifest = Join-Path $fingerprintRoot "clspl-canonical-files.txt"

$stadtlerFiles = New-Object System.Collections.Generic.List[string]

foreach ($spec in $expected) {
    $instancesRoot = Join-Path $stadtlerRoot ($spec.Folder + "\instances")

    foreach ($file in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File) {
        $stadtlerFiles.Add($file.FullName)
    }
}

$clsplCanonicalRoot = Join-Path $clsplRoot "instances"
$clsplFiles = @(
    Get-ChildItem -LiteralPath $clsplCanonicalRoot -Filter "*.xml" -File
)

[System.IO.File]::WriteAllLines(
    $stadtlerManifest,
    $stadtlerFiles.ToArray(),
    (New-Object System.Text.UTF8Encoding($false))
)

[System.IO.File]::WriteAllLines(
    $clsplManifest,
    @($clsplFiles | ForEach-Object { $_.FullName }),
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ("Stadtler manifest: " + $stadtlerFiles.Count + " files")
Write-Host ("CLSPL canonical manifest: " + $clsplFiles.Count + " files")

Write-Step "Building batch fingerprint tool"

$batchProject = Join-Path $BenchmarkRepo `
    "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

& dotnet build `
    $batchProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Batch fingerprint tool build failed."
}

Write-Step "Fingerprinting Stadtler in one process"

$stadtlerFingerprintCsv = Join-Path $fingerprintRoot "stadtler-fingerprints.csv"

& dotnet run `
    --project $batchProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    "STADTLER2003" `
    $stadtlerManifest `
    $stadtlerFingerprintCsv

if ($LASTEXITCODE -ne 0) {
    throw "Stadtler batch fingerprint failed."
}

Write-Step "Fingerprinting canonical CLSPL in one process"

$clsplFingerprintCsv = Join-Path $fingerprintRoot "clspl-fingerprints.csv"

& dotnet run `
    --project $batchProject `
    -c Release `
    --no-build `
    -p:ModelRepo=$ModelRepo `
    -- `
    "SUERIE_CLSPL" `
    $clsplManifest `
    $clsplFingerprintCsv

if ($LASTEXITCODE -ne 0) {
    throw "CLSPL batch fingerprint failed."
}

$stadtlerFp = @(Import-Csv -LiteralPath $stadtlerFingerprintCsv)
$clsplFp = @(Import-Csv -LiteralPath $clsplFingerprintCsv)

if ($stadtlerFp.Count -ne 2100) {
    throw (
        "Fingerprint postcondition failed for Stadtler: expected 2100, found " +
        $stadtlerFp.Count
    )
}

if ($clsplFp.Count -ne 1291) {
    throw (
        "Fingerprint postcondition failed for CLSPL: expected 1291, found " +
        $clsplFp.Count
    )
}

Write-Step "Computing exact Stadtler-CLSPL genealogy"

$clsplByFingerprint = @{}

foreach ($row in $clsplFp) {
    if (-not $clsplByFingerprint.ContainsKey($row.fingerprint)) {
        $clsplByFingerprint[$row.fingerprint] =
            New-Object System.Collections.Generic.List[object]
    }

    $clsplByFingerprint[$row.fingerprint].Add($row)
}

$crosswalk = New-Object System.Collections.Generic.List[object]

foreach ($stadtlerRow in $stadtlerFp) {
    if (-not $clsplByFingerprint.ContainsKey($stadtlerRow.fingerprint)) {
        continue
    }

    foreach ($clsplRow in $clsplByFingerprint[$stadtlerRow.fingerprint].ToArray()) {
        $crosswalk.Add([pscustomobject]@{
            fingerprint = $stadtlerRow.fingerprint
            stadtler_filename = $stadtlerRow.filename
            stadtler_path = $stadtlerRow.path
            clspl_filename = $clsplRow.filename
            clspl_path = $clsplRow.path
            relation = "EXACT_SUPPLY_CHAIN_DUPLICATE"
        })
    }
}

$crosswalk.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $fingerprintRoot "stadtler-clspl-exact-crosswalk.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Exact Stadtler-CLSPL fingerprint pairs: " + $crosswalk.Count)

Write-Step "Indexing generated Stadtler codes by official class"

$xmlIndex = @{}
$xmlInventory = New-Object System.Collections.Generic.List[object]

foreach ($spec in $expected) {
    $instancesRoot = Join-Path $stadtlerRoot ($spec.Folder + "\instances")

    foreach ($file in Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File) {
        $code = Normalize-Stadtler-Code -Value $file.BaseName

        if ([string]::IsNullOrWhiteSpace($code)) {
            try {
                [xml]$doc = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
                $root = $doc.DocumentElement

                if ($null -ne $root) {
                    $code = Normalize-Stadtler-Code -Value $root.GetAttribute("instanceId")

                    if ([string]::IsNullOrWhiteSpace($code)) {
                        $code = Normalize-Stadtler-Code -Value $root.GetAttribute("name")
                    }
                }
            }
            catch {
            }
        }

        $record = [pscustomobject]@{
            test_set = $spec.Class
            code = $code
            filename = $file.Name
            path = $file.FullName
        }

        $xmlInventory.Add($record)

        if (-not [string]::IsNullOrWhiteSpace($code)) {
            $key = $spec.Class + "|" + $code

            if (-not $xmlIndex.ContainsKey($key)) {
                $xmlIndex[$key] =
                    New-Object System.Collections.Generic.List[object]
            }

            $xmlIndex[$key].Add($record)
        }
    }
}

$xmlInventory.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-generated-code-inventory.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Deduplicating extracted Stadtler literature rows"

$seen = @{}
$references = New-Object System.Collections.Generic.List[object]

foreach ($csv in $resolvedCsvs) {
    foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
        $workbook = $row.workbook

        if ([string]::IsNullOrWhiteSpace($workbook)) {
            $workbook = $csv.BaseName
        }

        $class = Get-ClassFromWorkbook -Workbook $workbook
        $code = Normalize-Stadtler-Code -Value $row.source_instance_id

        $dedupe = (
            $class + "|" +
            $row.source_instance_id + "|" +
            $row.objective + "|" +
            $row.lower_bound
        )

        if ($seen.ContainsKey($dedupe)) {
            continue
        }

        $seen[$dedupe] = $true

        $references.Add([pscustomobject]@{
            test_set = $class
            source_instance_id = $row.source_instance_id
            canonical_code = $code
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $workbook
            source_sheet = $row.source_sheet
            source_csv = $csv.Name
        })
    }
}

Write-Host ("Unique extracted literature rows: " + $references.Count)

Write-Step "Mapping literature to generated universe"

$mapped = New-Object System.Collections.Generic.List[object]
$unmapped = New-Object System.Collections.Generic.List[object]
$legacy = New-Object System.Collections.Generic.List[object]

foreach ($ref in $references.ToArray()) {
    if ($ref.test_set -eq "LEGACY-CM") {
        $legacy.Add([pscustomobject]@{
            test_set = "LEGACY-CM"
            source_instance_id = $ref.source_instance_id
            canonical_code = $ref.canonical_code
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            source_workbook = $ref.source_workbook
            status = "LEGACY_NON_OFFICIAL_REFERENCE"
        })

        continue
    }

    if ($ref.test_set -eq "UNKNOWN") {
        $unmapped.Add([pscustomobject]@{
            test_set = "UNKNOWN"
            source_instance_id = $ref.source_instance_id
            canonical_code = $ref.canonical_code
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            source_workbook = $ref.source_workbook
            candidate_count = 0
            status = "UNKNOWN_WORKBOOK_CLASS"
        })

        continue
    }

    if ([string]::IsNullOrWhiteSpace($ref.canonical_code)) {
        $unmapped.Add([pscustomobject]@{
            test_set = $ref.test_set
            source_instance_id = $ref.source_instance_id
            canonical_code = ""
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            source_workbook = $ref.source_workbook
            candidate_count = 0
            status = "NO_CANONICAL_SEVEN_POSITION_CODE"
        })

        continue
    }

    $key = $ref.test_set + "|" + $ref.canonical_code
    $candidates = @()

    if ($xmlIndex.ContainsKey($key)) {
        $candidates = @($xmlIndex[$key].ToArray())
    }

    if ($candidates.Count -eq 1) {
        $match = $candidates[0]

        $mapped.Add([pscustomobject]@{
            test_set = $ref.test_set
            source_instance_id = $ref.source_instance_id
            canonical_code = $ref.canonical_code
            lsdm_filename = $match.filename
            lsdm_path = $match.path
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            objective_status = $(if ([string]::IsNullOrWhiteSpace($ref.objective)) { "" } else { "LITERATURE_BEST_KNOWN" })
            lower_bound_status = $(if ([string]::IsNullOrWhiteSpace($ref.lower_bound)) { "" } else { "LITERATURE_LOWER_BOUND" })
            verified = "False"
            source_workbook = $ref.source_workbook
            source_sheet = $ref.source_sheet
            mapping_status = "UNIQUE_OFFICIAL_CLASS_PLUS_SEVEN_POSITION_CODE"
        })
    }
    else {
        $status = "NO_GENERATED_XML_FOR_CODE"

        if ($candidates.Count -gt 1) {
            $status = "AMBIGUOUS_CODE_WITHIN_CLASS"
        }

        $unmapped.Add([pscustomobject]@{
            test_set = $ref.test_set
            source_instance_id = $ref.source_instance_id
            canonical_code = $ref.canonical_code
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            source_workbook = $ref.source_workbook
            candidate_count = $candidates.Count
            status = $status
        })
    }
}

$mapped.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-REFERENCES-v0.4.2.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$unmapped.ToArray() |
    Sort-Object test_set,canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LITERATURE-UNMAPPED-v0.4.2.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$legacy.ToArray() |
    Sort-Object canonical_code |
    Export-Csv `
        -LiteralPath (Join-Path $metadataRoot "STADTLER-LEGACY-CM-REFERENCES-v0.4.2.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating per-class literature and GitHub pages"

foreach ($spec in $expected) {
    $classRoot = Join-Path $stadtlerRoot $spec.Folder
    $classMetadata = Join-Path $classRoot "metadata"

    Ensure-Directory -Path $classMetadata

    $classMapped = @(
        $mapped.ToArray() |
        Where-Object { $_.test_set -eq $spec.Class }
    )

    $classUnmapped = @(
        $unmapped.ToArray() |
        Where-Object { $_.test_set -eq $spec.Class }
    )

    $classMapped |
        Export-Csv `
            -LiteralPath (Join-Path $classMetadata "literature-references-v0.4.2.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    $classUnmapped |
        Export-Csv `
            -LiteralPath (Join-Path $classMetadata "literature-unmapped-v0.4.2.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    $page = New-Object System.Collections.Generic.List[string]

    $page.Add("# Stadtler " + $spec.Class)
    $page.Add("")
    $page.Add("| Metric | Count |")
    $page.Add("|---|---:|")
    $page.Add("| Generated admissible XML | **" + $spec.Count + "** |")
    $page.Add("| Literature rows mapped | **" + $classMapped.Count + "** |")
    $page.Add("| Literature rows unresolved | **" + $classUnmapped.Count + "** |")
    $page.Add("")
    $page.Add("The generated admissible universe and the published-reference subset are intentionally distinguished.")
    $page.Add("")
    $page.Add("Literature objective values and lower bounds are not marked VERIFIED without a complete checked solution.")

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
$familyPage.Add("> Stabilized v0.4.2 corpus. No canonical XML is generated or rewritten by this release.")
$familyPage.Add("")
$familyPage.Add("## Generated admissible universe")
$familyPage.Add("")
$familyPage.Add("| Test set | Generated XML | Checker evidence | Literature mapped | Literature unresolved |")
$familyPage.Add("|---|---:|---|---:|---:|")

foreach ($spec in $expected) {
    $v = @(
        $validation.ToArray() |
        Where-Object { $_.test_set -eq $spec.Class } |
        Select-Object -First 1
    )[0]

    $mappedCount = @(
        $mapped.ToArray() |
        Where-Object { $_.test_set -eq $spec.Class }
    ).Count

    $unmappedCount = @(
        $unmapped.ToArray() |
        Where-Object { $_.test_set -eq $spec.Class }
    ).Count

    $familyPage.Add(
        "| " + $spec.Class +
        " | " + $spec.Count +
        " | " + $v.checker_evidence +
        " | " + $mappedCount +
        " | " + $unmappedCount +
        " |"
    )
}

$familyPage.Add("| **Total** | **2100** | **8/8 valid** | **" + $mapped.Count + "** | **" + $unmapped.Count + "** |")
$familyPage.Add("")
$familyPage.Add("## Literature and provenance")
$familyPage.Add("")
$familyPage.Add("- Unique extracted workbook rows: **" + $references.Count + "**")
$familyPage.Add("- Official rows mapped to one generated XML: **" + $mapped.Count + "**")
$familyPage.Add("- Official rows unresolved/ambiguous: **" + $unmapped.Count + "**")
$familyPage.Add("- Legacy `classcm` rows kept separately: **" + $legacy.Count + "**")
$familyPage.Add("")
$familyPage.Add("The 2,100 generated XML form the admissible generated universe. They are not claimed to all have published BKV values.")
$familyPage.Add("")
$familyPage.Add("## Cross-family genealogy")
$familyPage.Add("")
$familyPage.Add("- Canonical Stadtler fingerprints: **2100**")
$familyPage.Add("- Canonical CLSPL fingerprints: **1291**")
$familyPage.Add("- Exact supply-chain fingerprint pairs: **" + $crosswalk.Count + "**")
$familyPage.Add("- The published B+ -> CLSPL/datab relation is retained even if a specific exact fingerprint pair is absent because of representation differences.")

[System.IO.File]::WriteAllLines(
    (Join-Path $stadtlerRoot "README.md"),
    $familyPage.ToArray(),
    (New-Object System.Text.UTF8Encoding($false))
)

$summary = @(
    "# v0.4.2 stabilization summary",
    "",
    "- CLSPL catalogue: 1281 / 1281",
    "- Stadtler generated XML: 2100 / 2100",
    "- Stadtler checker evidence: 8 / 8 valid",
    "- Stadtler fingerprints: " + $stadtlerFp.Count,
    "- CLSPL canonical fingerprints: " + $clsplFp.Count,
    "- Exact cross-family fingerprint pairs: " + $crosswalk.Count,
    "- Unique literature rows: " + $references.Count,
    "- Official literature mapped: " + $mapped.Count,
    "- Official literature unresolved: " + $unmapped.Count,
    "- Legacy classcm rows: " + $legacy.Count,
    "",
    "No generator, converter, checker rerun or canonical XML rewrite was performed."
)

[System.IO.File]::WriteAllLines(
    (Join-Path $reportRoot "README.md"),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "v0.4.2 final summary"
Write-Host "CLSPL catalogue: 1281 / 1281"
Write-Host "Stadtler generated XML: 2100 / 2100"
Write-Host "Checker evidence: 8 / 8 valid"
Write-Host ("Stadtler fingerprints: " + $stadtlerFp.Count)
Write-Host ("CLSPL canonical fingerprints: " + $clsplFp.Count)
Write-Host ("Exact Stadtler-CLSPL pairs: " + $crosswalk.Count)
Write-Host ("Unique literature rows: " + $references.Count)
Write-Host ("Official literature mapped: " + $mapped.Count)
Write-Host ("Official literature unresolved: " + $unmapped.Count)
Write-Host ("Legacy classcm rows: " + $legacy.Count)
Write-Host ("Reports: " + $reportRoot)
