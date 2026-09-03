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

    $v = $Value.ToLowerInvariant().Trim()
    $v = [regex]::Replace($v, "\.[a-z0-9]+$", "")
    $v = [regex]::Replace($v, "[^a-z0-9]", "")
    return $v
}

function Extract-NumberSignature {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $numbers = @(
        [regex]::Matches($Value, "\d+") |
        ForEach-Object {
            [int]$_.Value
        }
    )

    if ($numbers.Count -eq 0) {
        return ""
    }

    return ($numbers -join "-")
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

$clsRoot = Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL"
$clsMeta = Join-Path $clsRoot "metadata"
$clsInstances = Join-Path $clsRoot "instances"
$stadtRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.3.7"

Ensure-Dir $reportRoot

$unmappedPath = Join-Path $clsMeta "CLSPL-LITERATURE-UNMAPPED.csv"
$mappedPath = Join-Path $clsMeta "CLSPL-LITERATURE-REFERENCES.csv"

if (-not (Test-Path -LiteralPath $unmappedPath -PathType Leaf)) {
    throw "Missing CLSPL unmapped-reference catalogue. Run v0.3.6 first."
}

$unmappedAll = @(Import-Csv -LiteralPath $unmappedPath)
$databRefs = @(
    $unmappedAll |
    Where-Object { $_.test_set -eq "datab" }
)

Write-Step "Isolating datab reference rows"
Write-Host ("Unmapped datab references: " + $databRefs.Count)

$databRefs |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "datab-unmapped-references.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Indexing converted CLSPL XML identities"

$xmlRows = New-Object System.Collections.Generic.List[object]

foreach ($file in Get-ChildItem -LiteralPath $clsInstances -Filter "*.xml" -File -ErrorAction SilentlyContinue) {
    try {
        [xml]$doc = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    }
    catch {
        continue
    }

    if ($null -eq $doc.DocumentElement) {
        continue
    }

    $root = $doc.DocumentElement
    $name = $root.GetAttribute("name")
    $instanceId = $root.GetAttribute("instanceId")
    $sourceInfo = Get-XmlChildText -Root $root -LocalName "sourceInformation"

    $text = $file.Name + " " + $name + " " +
        $instanceId + " " + $sourceInfo

    $looksDatab =
        ($text -match "(?i)(^|[\\/_\-.])datab([\\/_\-.]|$)") -or
        ($text -match "(?i)classb|classbp|\bb\+")

    $xmlRows.Add([pscustomobject]@{
        filename = $file.Name
        full_path = $file.FullName
        xml_name = $name
        instance_id = $instanceId
        source_information = $sourceInfo
        looks_datab_or_bplus = $looksDatab
        normalized_name = (Normalize-Key -Value $name)
        normalized_instance_id = (Normalize-Key -Value $instanceId)
        normalized_source_leaf =
            $(if ([string]::IsNullOrWhiteSpace($sourceInfo)) {
                ""
            }
            else {
                Normalize-Key -Value (Split-Path -Leaf $sourceInfo)
            })
        number_signature =
            (Extract-NumberSignature -Value $text)
    })
}

$bplusXml = @(
    $xmlRows |
    Where-Object { $_.looks_datab_or_bplus -eq $true }
)

Write-Host ("XML with datab/B+ provenance signals: " + $bplusXml.Count)

$bplusXml |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "datab-bplus-xml-candidates.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Indexing raw datab source directories"

$rawCls = Join-Path $clsRoot "raw\materialized"
$rawDatab = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $rawCls -PathType Container) {
    $indexFiles = @(
        Get-ChildItem -LiteralPath $rawCls -Filter "INDEX.PRN" -File -Recurse -ErrorAction SilentlyContinue
    )

    foreach ($idx in $indexFiles) {
        $dir = $idx.Directory.FullName

        if ($dir -notmatch "(?i)datab") {
            continue
        }

        $rel = $dir.Substring($rawCls.Length).TrimStart('\')
        $leaf = Split-Path -Leaf $dir

        $rawDatab.Add([pscustomobject]@{
            directory = $dir
            relative_path = $rel
            leaf = $leaf
            normalized_leaf = (Normalize-Key -Value $leaf)
            number_signature = (Extract-NumberSignature -Value $rel)
        })
    }
}

Write-Host ("Raw datab instance directories: " + $rawDatab.Count)

$rawDatab |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "raw-datab-instances.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Building conservative datab crosswalk"

$crosswalk = New-Object System.Collections.Generic.List[object]
$stillUnmapped = New-Object System.Collections.Generic.List[object]

foreach ($ref in $databRefs) {
    $key = Normalize-Key -Value $ref.source_instance_id
    $numSig = Extract-NumberSignature -Value $ref.source_instance_id

    $rawExact = @(
        $rawDatab |
        Where-Object { $_.normalized_leaf -eq $key }
    )

    $rawNumeric = @()
    if (-not [string]::IsNullOrWhiteSpace($numSig)) {
        $rawNumeric = @(
            $rawDatab |
            Where-Object { $_.number_signature -eq $numSig }
        )
    }

    $rawMatch = @()

    if ($rawExact.Count -eq 1) {
        $rawMatch = $rawExact
        $rawMethod = "UNIQUE_RAW_LEAF"
    }
    elseif ($rawNumeric.Count -eq 1) {
        $rawMatch = $rawNumeric
        $rawMethod = "UNIQUE_RAW_NUMBER_SIGNATURE"
    }
    else {
        $rawMethod = ""
    }

    if ($rawMatch.Count -ne 1) {
        $stillUnmapped.Add([pscustomobject]@{
            source_instance_id = $ref.source_instance_id
            stage = "RAW_DATAB_MATCH"
            exact_candidates = $rawExact.Count
            numeric_candidates = $rawNumeric.Count
            status = "UNRESOLVED"
        })
        continue
    }

    $raw = $rawMatch[0]

    $xmlExact = @(
        $xmlRows |
        Where-Object {
            $_.normalized_name -eq $raw.normalized_leaf -or
            $_.normalized_instance_id -eq $raw.normalized_leaf -or
            $_.normalized_source_leaf -eq $raw.normalized_leaf
        }
    )

    $xmlNumeric = @()
    if (-not [string]::IsNullOrWhiteSpace($raw.number_signature)) {
        $xmlNumeric = @(
            $xmlRows |
            Where-Object {
                $_.number_signature -eq $raw.number_signature
            }
        )
    }

    if ($xmlExact.Count -eq 1) {
        $xml = $xmlExact[0]
        $xmlMethod = "UNIQUE_XML_INTERNAL_ID"
    }
    elseif ($xmlNumeric.Count -eq 1) {
        $xml = $xmlNumeric[0]
        $xmlMethod = "UNIQUE_XML_NUMBER_SIGNATURE"
    }
    else {
        $stillUnmapped.Add([pscustomobject]@{
            source_instance_id = $ref.source_instance_id
            stage = "XML_MATCH"
            exact_candidates = $xmlExact.Count
            numeric_candidates = $xmlNumeric.Count
            status = "UNRESOLVED"
        })
        continue
    }

    $crosswalk.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $ref.source_instance_id
        raw_directory = $raw.directory
        lsdm_filename = $xml.filename
        mapping_method = ($rawMethod + "+" + $xmlMethod)
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
    })
}

$crosswalkPath = Join-Path $reportRoot "datab-bplus-crosswalk.csv"
$crosswalk |
    Export-Csv -LiteralPath $crosswalkPath -NoTypeInformation -Encoding UTF8

$stillUnmapped |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "datab-still-unmapped.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ("Datab crosswalk rows: " + $crosswalk.Count)
Write-Host ("Datab still unresolved: " + $stillUnmapped.Count)

Write-Step "Promoting only proven-unique datab mappings into CLSPL metadata"

$existingMapped = @()
if (Test-Path -LiteralPath $mappedPath -PathType Leaf) {
    $existingMapped = @(Import-Csv -LiteralPath $mappedPath)
}

$combined = New-Object System.Collections.Generic.List[object]

foreach ($row in $existingMapped) {
    $combined.Add($row)
}

foreach ($row in $crosswalk) {
    $combined.Add([pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        lsdm_filename = $row.lsdm_filename
        xml_name = ""
        xml_instance_id = ""
        xml_source_information = $row.raw_directory
        xml_detected_test_set = "datab"
        mapping_method = $row.mapping_method
        mapping_evidence = "raw-datab-crosswalk"
        objective = $row.objective
        lower_bound = $row.lower_bound
        objective_status = $row.objective_status
        lower_bound_status = $row.lower_bound_status
        verified = "False"
        source_workbook = "solb.xls"
        source_sheet = ""
    })
}

$combined |
    Sort-Object test_set,source_instance_id |
    Export-Csv -LiteralPath $mappedPath -NoTypeInformation -Encoding UTF8

$newUnmapped = @(
    $unmappedAll |
    Where-Object { $_.test_set -ne "datab" }
)

foreach ($row in $stillUnmapped) {
    $newUnmapped += [pscustomobject]@{
        test_set = "datab"
        source_instance_id = $row.source_instance_id
        normalized_key = ""
        exact_candidate_count = $row.exact_candidates
        suffix_candidate_count = $row.numeric_candidates
        objective = ""
        lower_bound = ""
        status = "UNMAPPED_OR_AMBIGUOUS"
    }
}

$newUnmapped |
    Export-Csv -LiteralPath $unmappedPath -NoTypeInformation -Encoding UTF8

Write-Step "Auditing Stadtler class archives and generator contracts"

$stadtMaterialized = Join-Path $stadtRoot "raw\materialized"
$generatorReport = Join-Path $BenchmarkRepo "reports\v0.3.6\stadtler-generator-contract.csv"

$generators = @()
if (Test-Path -LiteralPath $generatorReport -PathType Leaf) {
    $generators = @(Import-Csv -LiteralPath $generatorReport)
}

$classRows = New-Object System.Collections.Generic.List[object]

foreach ($gen in $generators) {
    $dir = $gen.directory
    $leaf = Split-Path -Leaf $dir

    $classCode = "unknown"
    if ($leaf -match "(?i)classap") { $classCode = "A+" }
    elseif ($leaf -match "(?i)classbp") { $classCode = "B+" }
    elseif ($leaf -match "(?i)classcm") { $classCode = "C-" }
    elseif ($leaf -match "(?i)classcp") { $classCode = "C+" }
    elseif ($leaf -match "(?i)classc") { $classCode = "C" }
    elseif ($leaf -match "(?i)classdp") { $classCode = "D+" }
    elseif ($leaf -match "(?i)classd") { $classCode = "D" }
    elseif ($leaf -match "(?i)classep") { $classCode = "E+" }
    elseif ($leaf -match "(?i)classe") { $classCode = "E" }

    $files = @(
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue
    )

    $classRows.Add([pscustomobject]@{
        class_code = $classCode
        directory = $dir
        parameter_count = $gen.parameter_count
        parameters_used = $gen.parameters_used
        referenced_files = $gen.referenced_files
        local_file_count = $files.Count
        campaign_status = $gen.campaign_status
    })
}

$classRows |
    Sort-Object class_code |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-class-generator-catalog.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "v0.3.7 summary"

$totalMapped = @(
    Import-Csv -LiteralPath $mappedPath
).Count

$totalUnmapped = @(
    Import-Csv -LiteralPath $unmappedPath
).Count

Write-Host ("Previous CLSPL mapped: 1221")
Write-Host ("Datab crosswalk added: " + $crosswalk.Count)
Write-Host ("CLSPL total mapped: " + $totalMapped + " / 1281")
Write-Host ("CLSPL unresolved: " + $totalUnmapped)
Write-Host ("Stadtler class generators catalogued: " + $classRows.Count)
Write-Host ("Reports: " + $reportRoot)
