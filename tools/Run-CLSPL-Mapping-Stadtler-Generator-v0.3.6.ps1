param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Normalize-Key {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $v = $Value.Trim().ToLowerInvariant()
    $v = [regex]::Replace($v, "^suerie-clspl-", "")
    $v = [regex]::Replace($v, "\.[a-z0-9]+$", "")
    $v = [regex]::Replace($v, "[^a-z0-9]", "")
    return $v
}

function Get-XmlChildText {
    param(
        [System.Xml.XmlElement]$Root,
        [string]$LocalName
    )

    foreach ($node in $Root.ChildNodes) {
        if ($node -is [System.Xml.XmlElement] -and
            $node.LocalName -ieq $LocalName) {
            return $node.InnerText.Trim()
        }
    }

    return ""
}

function Get-TestSetFromText {
    param([string]$Text)

    if ($Text -match "(?i)(^|[\\/_\-.])datab([\\/_\-.]|$)") {
        return "datab"
    }

    if ($Text -match "(?i)(^|[\\/_\-.])datam([\\/_\-.]|$)") {
        return "datam"
    }

    if ($Text -match "(?i)(^|[\\/_\-.])data([\\/_\-.]|$)") {
        return "data"
    }

    return "unknown"
}

function Add-Key {
    param(
        [hashtable]$Index,
        [string]$Key,
        [object]$Record,
        [string]$Evidence
    )

    $normalized = Normalize-Key -Value $Key
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }

    if (-not $Index.ContainsKey($normalized)) {
        $Index[$normalized] = New-Object System.Collections.Generic.List[object]
    }

    $Index[$normalized].Add([pscustomobject]@{
        Record = $Record
        Evidence = $Evidence
    })
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$instanceRoot = Join-Path $familyRoot "instances"
$literatureRoot = Join-Path $familyRoot "literature"
$metadataRoot = Join-Path $familyRoot "metadata"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.3.6"

Ensure-Dir $metadataRoot
Ensure-Dir $reportRoot

Write-Step "Indexing CLSPL XML by internal identity"

$xmlRecords = New-Object System.Collections.Generic.List[object]
$keyIndex = @{}

$xmlFiles = @(
    Get-ChildItem -LiteralPath $instanceRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
)

foreach ($file in $xmlFiles) {
    try {
        [xml]$doc = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    }
    catch {
        Write-Warning ("Could not parse " + $file.FullName)
        continue
    }

    if ($null -eq $doc.DocumentElement) {
        continue
    }

    $root = $doc.DocumentElement

    $name = $root.GetAttribute("name")
    $instanceId = $root.GetAttribute("instanceId")
    $sourceInfo = Get-XmlChildText -Root $root -LocalName "sourceInformation"

    $sourceLeaf = ""
    $sourceParentLeaf = ""

    if (-not [string]::IsNullOrWhiteSpace($sourceInfo)) {
        try {
            $sourceLeaf = Split-Path -Leaf $sourceInfo
            $parent = Split-Path -Parent $sourceInfo
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                $sourceParentLeaf =
                    (Split-Path -Leaf $parent) + "-" + $sourceLeaf
            }
        }
        catch {
        }
    }

    $setText = $file.FullName + " " + $name + " " +
        $instanceId + " " + $sourceInfo

    $set = Get-TestSetFromText -Text $setText

    $record = [pscustomobject]@{
        file = $file
        filename = $file.Name
        name = $name
        instance_id = $instanceId
        source_information = $sourceInfo
        source_leaf = $sourceLeaf
        source_parent_leaf = $sourceParentLeaf
        test_set = $set
    }

    $xmlRecords.Add($record)

    Add-Key -Index $keyIndex -Key $name -Record $record -Evidence "xml-name"
    Add-Key -Index $keyIndex -Key $instanceId -Record $record -Evidence "xml-instanceId"
    Add-Key -Index $keyIndex -Key $sourceLeaf -Record $record -Evidence "source-leaf"
    Add-Key -Index $keyIndex -Key $sourceParentLeaf -Record $record -Evidence "source-parent-leaf"
    Add-Key -Index $keyIndex -Key $file.BaseName -Record $record -Evidence "lsdm-filename"
}

Write-Host ("Indexed XML instances: " + $xmlRecords.Count)
Write-Host ("Distinct normalized keys: " + $keyIndex.Keys.Count)

Write-Step "Loading resolved workbook references"

$resolvedFiles = @(
    Get-ChildItem -LiteralPath $literatureRoot `
        -Filter "*-resolved-references.csv" `
        -File `
        -ErrorAction SilentlyContinue
)

$referenceRows = New-Object System.Collections.Generic.List[object]

foreach ($csv in $resolvedFiles) {
    $set = "unknown"

    if ($csv.Name -match "(?i)^solb-") {
        $set = "datab"
    }
    elseif ($csv.Name -match "(?i)^solm-") {
        $set = "datam"
    }
    elseif ($csv.Name -match "(?i)^sol-") {
        $set = "data"
    }

    foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
        $referenceRows.Add([pscustomobject]@{
            test_set = $set
            source_instance_id = $row.source_instance_id
            objective = $row.objective
            lower_bound = $row.lower_bound
            source_workbook = $row.workbook
            source_sheet = $row.sheet
            resolution_evidence = $row.resolution_evidence
        })
    }
}

Write-Host ("Resolved workbook rows: " + $referenceRows.Count)

Write-Step "Mapping references with evidence-ranked identity rules"

$mapped = New-Object System.Collections.Generic.List[object]
$unmapped = New-Object System.Collections.Generic.List[object]

foreach ($ref in $referenceRows) {
    $key = Normalize-Key -Value $ref.source_instance_id
    $matches = @()

    if ($keyIndex.ContainsKey($key)) {
        $matches = @($keyIndex[$key])
    }

    if ($ref.test_set -ne "unknown") {
        $sameSet = @(
            $matches |
            Where-Object {
                $_.Record.test_set -eq $ref.test_set -or
                $_.Record.test_set -eq "unknown"
            }
        )

        if ($sameSet.Count -gt 0) {
            $matches = $sameSet
        }
    }

    $distinctByFile = @{}

    foreach ($m in $matches) {
        $path = $m.Record.file.FullName

        if (-not $distinctByFile.ContainsKey($path)) {
            $distinctByFile[$path] = New-Object System.Collections.Generic.List[string]
        }

        $distinctByFile[$path].Add($m.Evidence)
    }

    if ($distinctByFile.Keys.Count -eq 1) {
        $path = @($distinctByFile.Keys)[0]
        $record = @(
            $xmlRecords |
            Where-Object { $_.file.FullName -eq $path } |
            Select-Object -First 1
        )[0]

        $evidence =
            (@($distinctByFile[$path] | Sort-Object -Unique) -join ";")

        $mapped.Add([pscustomobject]@{
            test_set = $ref.test_set
            source_instance_id = $ref.source_instance_id
            lsdm_filename = $record.filename
            xml_name = $record.name
            xml_instance_id = $record.instance_id
            xml_source_information = $record.source_information
            xml_detected_test_set = $record.test_set
            mapping_method = "UNIQUE_NORMALIZED_INTERNAL_ID"
            mapping_evidence = $evidence
            objective = $ref.objective
            lower_bound = $ref.lower_bound
            objective_status =
                $(if ([string]::IsNullOrWhiteSpace($ref.objective)) {
                    ""
                }
                else {
                    "LITERATURE_BEST_KNOWN"
                })
            lower_bound_status =
                $(if ([string]::IsNullOrWhiteSpace($ref.lower_bound)) {
                    ""
                }
                else {
                    "LITERATURE_LOWER_BOUND"
                })
            verified = "False"
            source_workbook = $ref.source_workbook
            source_sheet = $ref.source_sheet
        })
    }
    else {
        $suffixCandidates = @(
            $xmlRecords |
            Where-Object {
                $candidateKeys = @(
                    (Normalize-Key -Value $_.name),
                    (Normalize-Key -Value $_.instance_id),
                    (Normalize-Key -Value $_.source_leaf)
                )

                $ok = $false
                foreach ($candidate in $candidateKeys) {
                    if ([string]::IsNullOrWhiteSpace($candidate)) {
                        continue
                    }

                    if ($candidate.EndsWith($key) -or
                        $key.EndsWith($candidate)) {
                        $ok = $true
                        break
                    }
                }

                $ok -and
                ($ref.test_set -eq "unknown" -or
                 $_.test_set -eq $ref.test_set -or
                 $_.test_set -eq "unknown")
            }
        )

        if ($suffixCandidates.Count -eq 1) {
            $record = $suffixCandidates[0]

            $mapped.Add([pscustomobject]@{
                test_set = $ref.test_set
                source_instance_id = $ref.source_instance_id
                lsdm_filename = $record.filename
                xml_name = $record.name
                xml_instance_id = $record.instance_id
                xml_source_information = $record.source_information
                xml_detected_test_set = $record.test_set
                mapping_method = "UNIQUE_INTERNAL_ID_SUFFIX"
                mapping_evidence = "unique-suffix"
                objective = $ref.objective
                lower_bound = $ref.lower_bound
                objective_status =
                    $(if ([string]::IsNullOrWhiteSpace($ref.objective)) {
                        ""
                    }
                    else {
                        "LITERATURE_BEST_KNOWN"
                    })
                lower_bound_status =
                    $(if ([string]::IsNullOrWhiteSpace($ref.lower_bound)) {
                        ""
                    }
                    else {
                        "LITERATURE_LOWER_BOUND"
                    })
                verified = "False"
                source_workbook = $ref.source_workbook
                source_sheet = $ref.source_sheet
            })
        }
        else {
            $unmapped.Add([pscustomobject]@{
                test_set = $ref.test_set
                source_instance_id = $ref.source_instance_id
                normalized_key = $key
                exact_candidate_count = $distinctByFile.Keys.Count
                suffix_candidate_count = $suffixCandidates.Count
                objective = $ref.objective
                lower_bound = $ref.lower_bound
                status = "UNMAPPED_OR_AMBIGUOUS"
            })
        }
    }
}

$mappedPath = Join-Path $metadataRoot "CLSPL-LITERATURE-REFERENCES.csv"
$unmappedPath = Join-Path $metadataRoot "CLSPL-LITERATURE-UNMAPPED.csv"

$mapped |
    Sort-Object test_set,source_instance_id |
    Export-Csv -LiteralPath $mappedPath -NoTypeInformation -Encoding UTF8

$unmapped |
    Sort-Object test_set,source_instance_id |
    Export-Csv -LiteralPath $unmappedPath -NoTypeInformation -Encoding UTF8

Write-Host ("Mapped references: " + $mapped.Count)
Write-Host ("Unmapped/ambiguous references: " + $unmapped.Count)

Write-Step "Organizing CLSPL by historical test set"

$setFolder = @{
    "data" = "TestSet1-data"
    "datam" = "TestSet2-datam"
    "datab" = "TestSet3-datab"
    "unknown" = "Unclassified"
}

foreach ($folder in $setFolder.Values) {
    foreach ($sub in @(
        "instances",
        "instances-with-reference",
        "metadata"
    )) {
        Ensure-Dir (Join-Path $familyRoot ($folder + "\" + $sub))
    }
}

$mappedByFile = @{}
foreach ($row in $mapped) {
    $mappedByFile[$row.lsdm_filename] = $row
}

foreach ($xml in $xmlRecords) {
    $set = $xml.test_set

    if ($mappedByFile.ContainsKey($xml.filename)) {
        $set = $mappedByFile[$xml.filename].test_set
    }

    if (-not $setFolder.ContainsKey($set)) {
        $set = "unknown"
    }

    $folder = $setFolder[$set]

    Copy-Item `
        -LiteralPath $xml.file.FullName `
        -Destination (Join-Path $familyRoot ($folder + "\instances\" + $xml.filename)) `
        -Force

    Copy-Item `
        -LiteralPath $xml.file.FullName `
        -Destination (Join-Path $familyRoot ($folder + "\instances-with-reference\" + $xml.filename)) `
        -Force
}

foreach ($set in @("data","datam","datab")) {
    $rows = @($mapped | Where-Object { $_.test_set -eq $set })
    $folder = $setFolder[$set]

    $rows |
        Export-Csv `
            -LiteralPath (Join-Path $familyRoot ($folder + "\metadata\literature-references.csv")) `
            -NoTypeInformation `
            -Encoding UTF8
}

Write-Step "Generating CLSPL GitHub pages"

$allXmlCount = $xmlRecords.Count
$mappedCount = $mapped.Count
$unmappedCount = $unmapped.Count

$main = New-Object System.Collections.Generic.List[string]
$main.Add("# Suerie-Stadtler CLSPL benchmark")
$main.Add("")
$main.Add("> Converted LotSizingDataModel corpus with literature BKV/lower-bound evidence.")
$main.Add("")
$main.Add("| Metric | Count |")
$main.Add("|---|---:|")
$main.Add("| LSDM instances | **$allXmlCount** |")
$main.Add("| Resolved literature references | **$mappedCount / $($referenceRows.Count)** |")
$main.Add("| Unmapped/ambiguous references | **$unmappedCount** |")
$main.Add("")
$main.Add("Published objective and lower-bound values are literature evidence only; they are not marked verified without a complete checked solution.")

[System.IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $main,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "Extracting Stadtler generator contracts"

$stadtRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003\raw\materialized"
$generatorRows = New-Object System.Collections.Generic.List[object]

$startScripts = @(
    Get-ChildItem `
        -LiteralPath $stadtRoot `
        -Filter "start_ini.bat" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue
)

foreach ($start in $startScripts) {
    $content = @(
        Get-Content -LiteralPath $start.FullName -ErrorAction SilentlyContinue
    )

    $parameterNumbers = New-Object System.Collections.Generic.HashSet[int]

    foreach ($line in $content) {
        foreach ($match in [regex]::Matches($line, "%([1-9])")) {
            [void]$parameterNumbers.Add([int]$match.Groups[1].Value)
        }
    }

    $referencedFiles = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in $content) {
        foreach ($match in [regex]::Matches(
            $line,
            "(?i)[A-Za-z0-9_+\-.]+\.(?:PRN|DAT|TXT|BAT|EXE)"
        )) {
            [void]$referencedFiles.Add($match.Value)
        }
    }

    $comments = @(
        $content |
        Where-Object { $_ -match "(?i)^\s*(REM\b|::)" }
    )

    $maxParameter = 0
    if ($parameterNumbers.Count -gt 0) {
        $maxParameter = ($parameterNumbers | Measure-Object -Maximum).Maximum
    }

    $generatorRows.Add([pscustomobject]@{
        directory = $start.Directory.FullName
        start_ini = $start.FullName
        parameter_count = $maxParameter
        parameters_used = ((@($parameterNumbers | Sort-Object) -join ";"))
        referenced_files = ((@($referencedFiles | Sort-Object) -join ";"))
        comments = (($comments -join " || "))
        campaign_status = "PARAMETRIC_GENERATOR_NO_LITERAL_CAMPAIGN_IN_ARCHIVE"
    })
}

$generatorRows |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-generator-contract.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "v0.3.6 summary"
Write-Host ("CLSPL XML: " + $xmlRecords.Count)
Write-Host ("Workbook references: " + $referenceRows.Count)
Write-Host ("Mapped references: " + $mapped.Count)
Write-Host ("Unmapped/ambiguous: " + $unmapped.Count)
Write-Host ("Stadtler generators: " + $generatorRows.Count)
Write-Host ("Reports: " + $reportRoot)
