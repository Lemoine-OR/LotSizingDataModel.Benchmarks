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

function Copy-FileSafe {
    param(
        [string]$Source,
        [string]$Destination
    )

    Ensure-Directory -Path ([IO.Path]::GetDirectoryName($Destination))
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$stadtlerRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$clsplRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$tdRoot = Join-Path $BenchmarkRepo "benchmarks\TD1996"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.5.0"
$catalogRoot = Join-Path $BenchmarkRepo "catalog"

foreach ($p in @(
    $tdRoot,
    $reportRoot,
    $catalogRoot,
    (Join-Path $tdRoot "instances"),
    (Join-Path $tdRoot "instances-with-reference"),
    (Join-Path $tdRoot "metadata"),
    (Join-Path $tdRoot "raw\discovered")
)) {
    Ensure-Directory -Path $p
}

Write-Step "Preflight: preserving stabilized Stadtler and CLSPL state"

$stadtlerCounts = @{
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

foreach ($folder in $stadtlerCounts.Keys) {
    $instances = Join-Path $stadtlerRoot ($folder + "\instances")
    $count = @(
        Get-ChildItem -LiteralPath $instances -Filter "*.xml" -File -ErrorAction SilentlyContinue
    ).Count

    if ($count -ne $stadtlerCounts[$folder]) {
        throw (
            "Stadtler corpus regression in " +
            $folder +
            ": expected " +
            $stadtlerCounts[$folder] +
            ", found " +
            $count
        )
    }

    $total += $count
}

if ($total -ne 2100) {
    throw "Stadtler total must remain 2100."
}

$clsplCatalogue = Join-Path $clsplRoot "metadata\CLSPL-LITERATURE-REFERENCES.csv"
$clsplRows = @(Import-Csv -LiteralPath $clsplCatalogue)
$databRows = @($clsplRows | Where-Object { $_.test_set -eq "datab" })

if ($clsplRows.Count -ne 1281 -or $databRows.Count -ne 60) {
    throw "CLSPL stabilized catalogue regression."
}

Write-Host "Stadtler: 2100 / 2100"
Write-Host "CLSPL: 1281 / 1281; datab 60 / 60"

Write-Step "Closing the 75 unresolved Stadtler literature rows"

$unmappedPath = Join-Path $stadtlerRoot `
    "metadata\STADTLER-LITERATURE-UNMAPPED-v0.4.3-R2.csv"

if (-not (Test-Path -LiteralPath $unmappedPath -PathType Leaf)) {
    throw "Stadtler v0.4.3-R2 unmapped catalogue is missing."
}

$unmapped = @(Import-Csv -LiteralPath $unmappedPath)

if ($unmapped.Count -ne 75) {
    throw (
        "Expected 75 unresolved Stadtler rows, found " +
        $unmapped.Count
    )
}

$materializationPath = Join-Path $BenchmarkRepo `
    "reports\v0.4.0\stadtler-campaign-materialization.csv"

$materialization = @()

if (Test-Path -LiteralPath $materializationPath -PathType Leaf) {
    $materialization = @(Import-Csv -LiteralPath $materializationPath)
}

$generatedIndex = @{}

foreach ($classInfo in @(
    [pscustomobject]@{TestSet="A+";Folder="Aplus"},
    [pscustomobject]@{TestSet="B+";Folder="Bplus"},
    [pscustomobject]@{TestSet="C";Folder="C"},
    [pscustomobject]@{TestSet="C+";Folder="Cplus"},
    [pscustomobject]@{TestSet="D";Folder="D"},
    [pscustomobject]@{TestSet="D+";Folder="Dplus"},
    [pscustomobject]@{TestSet="E";Folder="E"},
    [pscustomobject]@{TestSet="E+";Folder="Eplus"}
)) {
    $instances = Join-Path $stadtlerRoot ($classInfo.Folder + "\instances")

    foreach ($file in Get-ChildItem -LiteralPath $instances -Filter "*.xml" -File) {
        $code = Normalize-Code -Value $file.BaseName

        if (-not [string]::IsNullOrWhiteSpace($code)) {
            $key = $classInfo.TestSet + "|" + $code
            $generatedIndex[$key] = $file.FullName
        }
    }
}

$closure = New-Object System.Collections.Generic.List[object]
$resolvedAdditional = New-Object System.Collections.Generic.List[object]

foreach ($row in $unmapped) {
    $testSet = [string]$row.test_set
    $code = Normalize-Code -Value ([string]$row.canonical_code)

    if ([string]::IsNullOrWhiteSpace($code)) {
        $code = Normalize-Code -Value ([string]$row.source_instance_id)
    }

    $key = $testSet + "|" + $code
    $status = "UNRESOLVED_NO_PROOF"
    $evidence = ""
    $xmlPath = ""

    if (-not [string]::IsNullOrWhiteSpace($code) -and $generatedIndex.ContainsKey($key)) {
        $xmlPath = [string]$generatedIndex[$key]
        $status = "RESOLVED_BY_CANONICAL_CLASS_CODE"
        $evidence = "Unique generated XML exists for official class plus seven-position code."

        $resolvedAdditional.Add([pscustomobject]@{
            test_set = $testSet
            canonical_code = $code
            lsdm_filename = [IO.Path]::GetFileName($xmlPath)
            lsdm_path = $xmlPath
            objective = $row.objective
            lower_bound = $row.lower_bound
            objective_status = $(if ([string]::IsNullOrWhiteSpace($row.objective)) { "" } else { "LITERATURE_BEST_KNOWN" })
            lower_bound_status = $(if ([string]::IsNullOrWhiteSpace($row.lower_bound)) { "" } else { "LITERATURE_LOWER_BOUND" })
            verified = "False"
            source_workbook = $row.source_workbook
            mapping_status = "RESOLVED_V0.5.0_CLASS_CODE"
        })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($code) -and $materialization.Count -gt 0) {
        $attempts = @(
            $materialization |
            Where-Object {
                $_.test_set -eq $testSet -and
                (Normalize-Code -Value $_.code) -eq $code
            }
        )

        if ($attempts.Count -gt 0) {
            $accepted = @(
                $attempts |
                Where-Object {
                    $_.status -eq "MATERIALIZED_COMPLETE_CONTRACT"
                }
            )

            if ($accepted.Count -eq 0) {
                $status = "LITERATURE_REFERENCE_COMBINATION_REJECTED_BY_GENERATOR"
                $evidence = "The official generator campaign attempted the code but did not produce the complete source contract."
            }
            else {
                $status = "MATERIALIZED_BUT_XML_CROSSWALK_MISSING"
                $evidence = "Materialization evidence exists but no canonical generated XML could be matched."
            }
        }
        else {
            $status = "CODE_NOT_IN_ENUMERATED_CAMPAIGN"
            $evidence = "The literature code is outside the enumerated documented campaign domain."
        }
    }

    $closure.Add([pscustomobject]@{
        test_set = $testSet
        canonical_code = $code
        objective = $row.objective
        lower_bound = $row.lower_bound
        source_workbook = $row.source_workbook
        previous_status = $row.status
        closure_status = $status
        evidence = $evidence
        lsdm_path = $xmlPath
    })
}

$closure.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-75-closure.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Previously unresolved: " + $unmapped.Count)
Write-Host ("Additional uniquely resolved: " + $resolvedAdditional.Count)

$closureGroups = @(
    $closure.ToArray() |
    Group-Object closure_status |
    Sort-Object Count -Descending
)

foreach ($group in $closureGroups) {
    Write-Host ("  " + $group.Name + ": " + $group.Count)
}

Write-Step "Searching workstation for original Tempelmeier-Derstroff source data"

$roots = @(
    "D:\Dev",
    "D:\temp",
    (Join-Path $env:USERPROFILE "Documents"),
    (Join-Path $env:USERPROFILE "Downloads")
)

$patterns = @(
    "*tempelmeier*",
    "*derstroff*",
    "*td1996*",
    "*td96*"
)

$discoveries = New-Object System.Collections.Generic.List[object]

foreach ($searchRoot in $roots) {
    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
        continue
    }

    foreach ($pattern in $patterns) {
        foreach ($item in Get-ChildItem `
            -LiteralPath $searchRoot `
            -Filter $pattern `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue) {

            if ($item.FullName -like ($tdRoot + "*")) {
                continue
            }

            $discoveries.Add([pscustomobject]@{
                path = $item.FullName
                file_name = $item.Name
                extension = $item.Extension
                length = $item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            })
        }
    }
}

$uniqueDiscovery = @(
    $discoveries.ToArray() |
    Sort-Object path -Unique
)

$uniqueDiscovery |
    Export-Csv `
        -LiteralPath (Join-Path $tdRoot "metadata\local-discovery.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Potential local TD1996 files: " + $uniqueDiscovery.Count)

Write-Step "Building bibliographically proven TD1996 overlap from Stadtler"

# The Stadtler documentation explicitly states that some C, D and E instances
# with corresponding attributes match Tempelmeier-Derstroff (1996) exactly.
# We conservatively expose candidates only; we never relabel all C/D/E as TD1996.
$overlapCandidates = New-Object System.Collections.Generic.List[object]

foreach ($testSet in @("C","D","E")) {
    $folder = $testSet
    $instances = Join-Path $stadtlerRoot ($folder + "\instances")

    foreach ($file in Get-ChildItem -LiteralPath $instances -Filter "*.xml" -File) {
        $code = Normalize-Code -Value $file.BaseName

        if ([string]::IsNullOrWhiteSpace($code)) {
            continue
        }

        # TD1996 instances use 16 periods and no seasonal extension in the
        # corresponding Stadtler families. Restrict to zero seasonality.
        if ($code.Substring(6,1) -ne "0") {
            continue
        }

        $overlapCandidates.Add([pscustomobject]@{
            stadtler_test_set = $testSet
            stadtler_code = $code
            stadtler_xml = $file.FullName
            td1996_relation = "PUBLISHED_CORRESPONDING_ATTRIBUTE_CANDIDATE"
            promotion_status = "CANDIDATE_ONLY_UNTIL_ORIGINAL_TD_ID_CROSSWALK"
        })
    }
}

$overlapCandidates.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $tdRoot "metadata\stadtler-overlap-candidates.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Conservative C/D/E overlap candidates: " + $overlapCandidates.Count)

Write-Step "Creating TD1996 acquisition and genealogy status"

$acquisitionStatus = "ORIGINAL_CORPUS_NOT_LOCALLY_FOUND"

if ($uniqueDiscovery.Count -gt 0) {
    $acquisitionStatus = "LOCAL_CANDIDATES_FOUND_REQUIRES_FORMAT_AUDIT"
}

$acquisition = @(
    [pscustomobject]@{
        source_id = "TD1996"
        citation = "Tempelmeier and Derstroff (1996), Management Science 42(5):738-757"
        historical_url = "http://www.uni-koeln.de/wisofak/spw/publikationen/index.htm"
        local_candidate_files = $uniqueDiscovery.Count
        status = $acquisitionStatus
        note = "No original instance is fabricated. Published Stadtler C/D/E overlap is kept as candidate genealogy until an original TD identity crosswalk is demonstrated."
    }
)

$acquisition |
    Export-Csv `
        -LiteralPath (Join-Path $catalogRoot "td1996-acquisition-status.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$genealogy = @(
    [pscustomobject]@{
        parent_family = "TD1996"
        child_family = "STADTLER2003"
        child_subset = "C/D/E corresponding attributes"
        relation_type = "PUBLISHED_EXACT_MATCH_FOR_SOME_INSTANCES"
        proof_level = "BIBLIOGRAPHIC"
        file_level_crosswalk = "PENDING_ORIGINAL_TD1996_IDENTITIES"
    },
    [pscustomobject]@{
        parent_family = "STADTLER2003"
        child_family = "SUERIE_CLSPL"
        child_subset = "B+ -> datab"
        relation_type = "PUBLISHED_60_INSTANCE_SUBSET"
        proof_level = "BIBLIOGRAPHIC"
        file_level_crosswalk = "LSDM_REPRESENTATION_DIFFERS"
    }
)

$genealogy |
    Export-Csv `
        -LiteralPath (Join-Path $catalogRoot "benchmark-genealogy-v0.5.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

if ($DryRun) {
    Write-Step "Dry-run complete"
    Write-Host "No benchmark file was generated or relabelled."
    exit 0
}

Write-Step "Generating TD1996 GitHub page"

$page = New-Object System.Collections.Generic.List[string]
$page.Add("# Tempelmeier-Derstroff 1996")
$page.Add("")
$page.Add("> Acquisition and crosswalk status for the historical MLCLSP benchmark.")
$page.Add("")
$page.Add("| Metric | Value |")
$page.Add("|---|---|")
$page.Add("| Local original-source candidates | **" + $uniqueDiscovery.Count + "** |")
$page.Add("| Conservative Stadtler C/D/E overlap candidates | **" + $overlapCandidates.Count + "** |")
$page.Add("| Original TD1996 identities mapped | **0 until proven from original data** |")
$page.Add("")
$page.Add("## Important provenance rule")
$page.Add("")
$page.Add("No Stadtler file is silently relabelled as TD1996. The literature states that some C/D/E instances with corresponding attributes match TD1996 exactly, but file-level TD identities still require original-source evidence.")
$page.Add("")
$page.Add("## Known corpus structure from the literature")
$page.Add("")
$page.Add("- Class A: 1,500 small instances, 10 items, 4 periods, 3 resources, no setup times.")
$page.Add("- Class B: 600 instances derived from A with setup times.")
$page.Add("- Group/Class C-scale: 600 instances, 40 items, 16 periods, 6 resources.")
$page.Add("- Large group: 150 instances, 100 items, 16 periods, 10 resources.")
$page.Add("")
$page.Add("The repository records these facts as literature metadata only; no missing raw instance is synthesized.")

[IO.File]::WriteAllLines(
    (Join-Path $tdRoot "README.md"),
    $page.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "v0.5.0 summary"
Write-Host "Stadtler preserved: 2100 / 2100"
Write-Host "CLSPL preserved: 1281 / 1281"
Write-Host ("Stadtler 75 additional resolved: " + $resolvedAdditional.Count)
Write-Host ("TD1996 local source candidates: " + $uniqueDiscovery.Count)
Write-Host ("TD1996 conservative Stadtler overlap candidates: " + $overlapCandidates.Count)
Write-Host ("TD1996 acquisition status: " + $acquisitionStatus)
Write-Host ("Reports: " + $reportRoot)
