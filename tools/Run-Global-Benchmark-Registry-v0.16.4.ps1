param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sharedResolver =
    Join-Path $PSScriptRoot `
        "CanonicalCorpus-v0.16.4.ps1"

if (-not (
    Test-Path `
        -LiteralPath $sharedResolver `
        -PathType Leaf
)) {
    throw (
        "Shared canonical corpus resolver missing: " +
        $sharedResolver
    )
}

. $sharedResolver

function Write-Step {
    param([string]$Message)

    Write-Host ""
    Write-Host "==> $Message"
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (
        Test-Path `
            -LiteralPath $Path `
            -PathType Container
    )) {
        New-Item `
            -ItemType Directory `
            -Path $Path `
            -Force |
            Out-Null
    }
}

function Get-FirstExistingFile {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if (
            Test-Path `
                -LiteralPath $candidate `
                -PathType Leaf
        ) {
            return $candidate
        }
    }

    return $null
}

function Get-NormalizedId {
    param(
        [string]$Family,
        [string]$BaseName
    )

    $id = $BaseName

    $prefixes = @(
        "LSDM_" + $Family + "_",
        "LSDM_TRIGEIRO1989_",
        "LSDM_TD1996_",
        "LSDM_CATTRYSSE1990_",
        "LSDM_DJ2000_",
        "LSDM_STADTLER2003_",
        "LSDM_SUERIE_CLSPL_"
    )

    foreach ($prefix in $prefixes) {
        if (
            $id.StartsWith(
                $prefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $id =
                $id.Substring(
                    $prefix.Length
                )
        }
    }

    return $id
}

function Get-ColumnValue {
    param(
        [object]$Row,
        [string[]]$Names
    )

    if ($null -eq $Row) {
        return ""
    }

    foreach ($name in $Names) {
        $property =
            $Row.PSObject.Properties |
            Where-Object {
                $_.Name -eq $name
            } |
            Select-Object -First 1

        if ($null -ne $property) {
            $value =
                [string]$property.Value

            if (
                -not [string]::IsNullOrWhiteSpace(
                    $value
                )
            ) {
                return $value
            }
        }
    }

    return ""
}

function Index-CsvByAnyId {
    param(
        [string]$Path,
        [string[]]$Columns
    )

    $index = @{}

    if (
        [string]::IsNullOrWhiteSpace(
            $Path
        ) -or
        -not (
            Test-Path `
                -LiteralPath $Path `
                -PathType Leaf
        )
    ) {
        return $index
    }

    foreach ($row in Import-Csv -LiteralPath $Path) {
        foreach ($column in $Columns) {
            $value =
                Get-ColumnValue `
                    -Row $row `
                    -Names @($column)

            if (
                [string]::IsNullOrWhiteSpace(
                    $value
                )
            ) {
                continue
            }

            $trimmedValue =
                $value.Trim()

            $key =
                $trimmedValue.ToUpperInvariant()

            if (-not $index.ContainsKey($key)) {
                $index[$key] = $row
            }
        }
    }

    return $index
}

function Find-MetadataRow {
    param(
        [hashtable]$Index,
        [string[]]$CandidateIds
    )

    foreach ($candidate in $CandidateIds) {
        if (
            [string]::IsNullOrWhiteSpace(
                $candidate
            )
        ) {
            continue
        }

        $trimmedCandidate =
            $candidate.Trim()

        $key =
            $trimmedCandidate.ToUpperInvariant()

        if ($Index.ContainsKey($key)) {
            return $Index[$key]
        }
    }

    return $null
}

function Get-Subfamily {
    param(
        [string]$Family,
        [System.IO.FileInfo]$File,
        [object]$Metadata
    )

    $fromMetadata =
        Get-ColumnValue `
            -Row $Metadata `
            -Names @(
                "class_id",
                "series",
                "phase",
                "subfamily",
                "family_class"
            )

    if (
        -not [string]::IsNullOrWhiteSpace(
            $fromMetadata
        )
    ) {
        return $fromMetadata
    }

    if ($Family -eq "STADTLER2003") {
        $parent =
            $File.Directory.Parent

        if ($null -ne $parent) {
            return $parent.Name
        }
    }

    if ($Family -eq "DJ2000") {
        if ($File.FullName -match "\\Phase(?<p>[123])\\") {
            return "Phase" + $Matches["p"]
        }
    }

    return ""
}

function Get-XmlQuickFacts {
    param([string]$Path)

    $facts =
        [ordered]@{
            instance_id = ""
            planning_horizon = ""
            item_count = ""
            work_center_count = ""
            tags = ""
            lsdm_classification = ""
        }

    try {
        [xml]$xml =
            Get-Content `
                -LiteralPath $Path `
                -Raw

        $idNode =
            $xml.SelectSingleNode(
                "//*[local-name()='InstanceId']"
            )

        if ($null -ne $idNode) {
            $facts.instance_id =
                [string]$idNode.InnerText
        }

        $horizonNode =
            $xml.SelectSingleNode(
                "//*[local-name()='PlanningHorizon']"
            )

        if ($null -ne $horizonNode) {
            $facts.planning_horizon =
                [string]$horizonNode.InnerText
        }

        $itemNodes =
            $xml.SelectNodes(
                "//*[local-name()='Items']/*[local-name()='Item']"
            )

        if ($null -ne $itemNodes) {
            $facts.item_count =
                [string]$itemNodes.Count
        }

        $workCenterNodes =
            $xml.SelectNodes(
                "//*[local-name()='WorkCenters']/*[local-name()='WorkCenter']"
            )

        if ($null -ne $workCenterNodes) {
            $facts.work_center_count =
                [string]$workCenterNodes.Count
        }

        $tagNodes =
            $xml.SelectNodes(
                "//*[local-name()='Tags']/*"
            )

        if (
            $null -ne $tagNodes -and
            $tagNodes.Count -gt 0
        ) {
            $facts.tags =
                [string]::Join(
                    ";",
                    @(
                        $tagNodes |
                        ForEach-Object {
                            $_.InnerText
                        } |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace(
                                $_
                            )
                        }
                    )
                )
        }

        $classificationNode =
            $xml.SelectSingleNode(
                "//*[contains(local-name(),'Classification') or contains(local-name(),'ProblemClass')]"
            )

        if ($null -ne $classificationNode) {
            $facts.lsdm_classification =
                [string]$classificationNode.InnerText
        }
    }
    catch {
        throw (
            "XML quick-fact extraction failed for " +
            $Path +
            ": " +
            $_.Exception.Message
        )
    }

    return [pscustomobject]$facts
}

$reportRoot =
    Join-Path $BenchmarkRepo "reports\v0.16.4"

$registryRoot =
    Join-Path $BenchmarkRepo "catalog\global"

$githubRoot =
    Join-Path $BenchmarkRepo "docs\benchmarks"

$fingerprintRoot =
    Join-Path $reportRoot "fingerprints"

foreach ($path in @(
    $reportRoot,
    $registryRoot,
    $githubRoot,
    $fingerprintRoot
)) {
    Ensure-Directory -Path $path
}

Write-Step "Preflight: six stabilized benchmark families"

$tdCanonicalCatalogV0131 =
    Join-Path $BenchmarkRepo `
        "benchmarks\TD1996\metadata\TD1996-CANONICAL-CATALOG-v0.13.1.csv"

$tdCanonicalCatalogV0130 =
    Join-Path $BenchmarkRepo `
        "benchmarks\TD1996\metadata\TD1996-CANONICAL-CATALOG-v0.13.0.csv"

$families = @(
    [pscustomobject]@{
        family = "DJ2000"
        root = (Join-Path $BenchmarkRepo "benchmarks\DJ2000")
        expected = 176
        metadata = (Join-Path $BenchmarkRepo "benchmarks\DJ2000\metadata\DJ-FINAL-REFERENCE-CATALOG.csv")
        trust = (Join-Path $BenchmarkRepo "benchmarks\DJ2000\metadata\DJ-FINAL-REFERENCE-CATALOG.csv")
    },
    [pscustomobject]@{
        family = "STADTLER2003"
        root = (Join-Path $BenchmarkRepo "benchmarks\STADTLER2003")
        expected = 2100
        metadata = ""
        trust = ""
    },
    [pscustomobject]@{
        family = "SUERIE_CLSPL"
        root = (Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL")
        expected = 1291
        metadata = (Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv")
        trust = (Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL\metadata\CLSPL-LITERATURE-REFERENCES.csv")
    },
    [pscustomobject]@{
        family = "TRIGEIRO1989"
        root = (Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989")
        expected = 751
        metadata = (Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989\metadata\TRIGEIRO1989-CANONICAL-CATALOG-v0.11.0.csv")
        trust = (Join-Path $BenchmarkRepo "benchmarks\TRIGEIRO1989\metadata\TRIGEIRO1989-TRUST-CATALOG-v0.12.0.csv")
    },
    [pscustomobject]@{
        family = "TD1996"
        root = (Join-Path $BenchmarkRepo "benchmarks\TD1996")
        expected = 3450
        metadata = (
            Get-FirstExistingFile `
                -Candidates @(
                    $tdCanonicalCatalogV0131
                    $tdCanonicalCatalogV0130
                )
        )
        trust = ""
    },
    [pscustomobject]@{
        family = "CATTRYSSE1990"
        root = (Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990")
        expected = 120
        metadata = (Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990\metadata\CATTRYSSE1990-TRUST-CATALOG-v0.15.0.csv")
        trust = (Join-Path $BenchmarkRepo "benchmarks\CATTRYSSE1990\metadata\CATTRYSSE1990-TRUST-CATALOG-v0.15.0.csv")
    }
)

$familyFiles = @{}

$canonicalAuditRows =
    New-Object System.Collections.Generic.List[object]

foreach ($family in $families) {
    $resolved =
        Resolve-CanonicalCorpus `
            -BenchmarkRepo $BenchmarkRepo `
            -Family $family.family `
            -ExpectedCount $family.expected

    $files =
        @($resolved.files)

    $familyFiles[$family.family] =
        $files

    $audit =
        Get-FamilyXmlAudit `
            -BenchmarkRepo $BenchmarkRepo `
            -Family $family.family `
            -CanonicalFiles $files

    Write-Host (
        $family.family +
        ": " +
        $files.Count +
        " / " +
        $family.expected +
        " | layout=" +
        $resolved.layout +
        " | other XML excluded=" +
        $audit.noncanonical_count
    )

    foreach ($group in $audit.groups) {
        $canonicalAuditRows.Add(
            [pscustomobject]@{
                family = $family.family
                canonical_layout = $resolved.layout
                canonical_count = $files.Count
                all_xml_under_family = $audit.all_count
                noncanonical_xml = $audit.noncanonical_count
                excluded_bucket = $group.bucket
                excluded_bucket_xml_count = $group.xml_count
            }
        )
    }

    if ($audit.groups.Count -eq 0) {
        $canonicalAuditRows.Add(
            [pscustomobject]@{
                family = $family.family
                canonical_layout = $resolved.layout
                canonical_count = $files.Count
                all_xml_under_family = $audit.all_count
                noncanonical_xml = $audit.noncanonical_count
                excluded_bucket = ""
                excluded_bucket_xml_count = 0
            }
        )
    }
}

$totalExpected =
    (
        $families |
        Measure-Object `
            -Property expected `
            -Sum
    ).Sum

if ($totalExpected -ne 7888) {
    throw "Unexpected global expected total."
}

Write-Host ("Global canonical corpus: " + $totalExpected)

$canonicalAuditPath =
    Join-Path $reportRoot `
        "GLOBAL-CANONICAL-CORPUS-AUDIT-v0.16.4.csv"

$canonicalAuditRows.ToArray() |
    Export-Csv `
        -LiteralPath $canonicalAuditPath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Canonical/noncanonical XML audit: " +
    $canonicalAuditPath
)

Write-Step "Building one-process fingerprints per family"

$batchProject =
    Join-Path $BenchmarkRepo `
        "tools\StadtlerBatchFingerprint\StadtlerBatchFingerprint.csproj"

if (-not (
    Test-Path `
        -LiteralPath $batchProject `
        -PathType Leaf
)) {
    throw "StadtlerBatchFingerprint tool is required."
}

& dotnet build `
    $batchProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "Global fingerprint tool build failed."
}

$fingerprintByPath = @{}

foreach ($family in $families) {
    $manifest =
        Join-Path $fingerprintRoot (
            $family.family +
            "-files.txt"
        )

    $output =
        Join-Path $fingerprintRoot (
            $family.family +
            "-fingerprints.csv"
        )

    [IO.File]::WriteAllLines(
        $manifest,
        @(
            $familyFiles[$family.family] |
            ForEach-Object {
                $_.FullName
            }
        ),
        (New-Object Text.UTF8Encoding($false))
    )

    & dotnet run `
        --project $batchProject `
        -c Release `
        --no-build `
        -p:ModelRepo=$ModelRepo `
        -- `
        $family.family `
        $manifest `
        $output

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Fingerprint campaign failed for " +
            $family.family
        )
    }

    $fpRows =
        @(
            Import-Csv `
                -LiteralPath $output
        )

    if (
        $fpRows.Count -ne
        $family.expected
    ) {
        throw (
            "Fingerprint cardinality failed for " +
            $family.family
        )
    }

    foreach ($row in $fpRows) {
        $fullPath =
            [IO.Path]::GetFullPath(
                [string]$row.path
            )

        $fingerprintByPath[
            $fullPath.ToUpperInvariant()
        ] =
            [string]$row.fingerprint
    }

    Write-Host (
        $family.family +
        " fingerprints: " +
        $fpRows.Count
    )
}

Write-Step "Building unified 7888-row registry"

$registry =
    New-Object System.Collections.Generic.List[object]

foreach ($family in $families) {
    $metadataIndex =
        Index-CsvByAnyId `
            -Path ([string]$family.metadata) `
            -Columns @(
                "instance_id",
                "id",
                "original_id",
                "xml_file",
                "file",
                "filename"
            )

    $trustIndex =
        Index-CsvByAnyId `
            -Path ([string]$family.trust) `
            -Columns @(
                "instance_id",
                "id",
                "original_id",
                "xml_file",
                "file",
                "filename"
            )

    foreach ($file in $familyFiles[$family.family]) {
        $facts =
            Get-XmlQuickFacts `
                -Path $file.FullName

        $normalizedId =
            Get-NormalizedId `
                -Family $family.family `
                -BaseName $file.BaseName

        $candidateIds = @(
            $facts.instance_id,
            $normalizedId,
            $file.BaseName,
            $file.Name
        )

        $metadata =
            Find-MetadataRow `
                -Index $metadataIndex `
                -CandidateIds $candidateIds

        $trust =
            Find-MetadataRow `
                -Index $trustIndex `
                -CandidateIds $candidateIds

        $originalId =
            Get-ColumnValue `
                -Row $metadata `
                -Names @(
                    "instance_id",
                    "id",
                    "original_id"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $originalId
            )
        ) {
            $originalId =
                $facts.instance_id
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $originalId
            )
        ) {
            $originalId =
                $normalizedId
        }

        $subfamily =
            Get-Subfamily `
                -Family $family.family `
                -File $file `
                -Metadata $metadata

        $pathKey =
            [IO.Path]::GetFullPath(
                $file.FullName
            ).ToUpperInvariant()

        if (-not $fingerprintByPath.ContainsKey($pathKey)) {
            throw (
                "Missing fingerprint for " +
                $file.FullName
            )
        }

        $trustStatus =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "trust_status",
                    "status",
                    "reference_status",
                    "final_status"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $trustStatus
            )
        ) {
            $trustStatus =
                Get-ColumnValue `
                    -Row $metadata `
                    -Names @(
                        "trust_status",
                        "status",
                        "reference_status",
                        "final_status"
                    )
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $trustStatus
            )
        ) {
            $trustStatus =
                "UNKNOWN_REFERENCE"
        }

        $objective =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "best_reported_objective",
                    "objective",
                    "reference_objective",
                    "best_known_objective",
                    "literature_value"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $objective
            )
        ) {
            $objective =
                Get-ColumnValue `
                    -Row $metadata `
                    -Names @(
                        "best_reported_objective",
                        "objective",
                        "reference_objective",
                        "best_known_objective",
                        "literature_value"
                    )
        }

        $lowerBound =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "lower_bound",
                    "lb",
                    "best_lower_bound"
                )

        $completeSolution =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "complete_solution_available",
                    "complete_solution",
                    "solution_available"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $completeSolution
            )
        ) {
            $completeSolution = "False"
        }

        $checkerVerified =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "checker_verified_solution",
                    "checker_verified",
                    "verified_solution"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $checkerVerified
            )
        ) {
            $checkerVerified = "False"
        }

        $optimalityStatus =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "optimality_status",
                    "proven_optimal",
                    "optimality"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $optimalityStatus
            )
        ) {
            if (
                $trustStatus -eq
                "VERIFIED_PROVEN_OPTIMAL"
            ) {
                $optimalityStatus =
                    "PROVEN_OPTIMAL"
            }
            else {
                $optimalityStatus =
                    "NOT_PROVEN"
            }
        }

        $sourceSha =
            Get-ColumnValue `
                -Row $metadata `
                -Names @(
                    "source_sha256",
                    "trig_sha256",
                    "dat_sha256",
                    "sha256"
                )

        $sourceRole =
            Get-ColumnValue `
                -Row $metadata `
                -Names @(
                    "canonical_source",
                    "source_role",
                    "authority",
                    "role"
                )

        if (
            [string]::IsNullOrWhiteSpace(
                $sourceRole
            )
        ) {
            $sourceRole =
                "CANONICAL_XML"
        }

        $literatureSource =
            Get-ColumnValue `
                -Row $trust `
                -Names @(
                    "literature_source",
                    "source",
                    "reference",
                    "publication"
                )

        $xmlSha =
            (
                Get-FileHash `
                    -LiteralPath $file.FullName `
                    -Algorithm SHA256
            ).Hash

        if (
            [string]::IsNullOrWhiteSpace(
                $subfamily
            )
        ) {
            $globalId =
                $family.family +
                "::" +
                $originalId
        }
        else {
            $globalId =
                $family.family +
                "::" +
                $subfamily +
                "::" +
                $originalId
        }

        $registry.Add(
            [pscustomobject][ordered]@{
                global_instance_id = $globalId
                family = $family.family
                subfamily = $subfamily
                original_instance_id = $originalId
                canonical_xml_path = $file.FullName
                canonical_xml_sha256 = $xmlSha
                source_role = $sourceRole
                source_sha256 = $sourceSha
                planning_horizon = $facts.planning_horizon
                item_count = $facts.item_count
                work_center_count = $facts.work_center_count
                lsdm_tags = $facts.tags
                lsdm_classification = $facts.lsdm_classification
                fingerprint = $fingerprintByPath[$pathKey]
                trust_status = $trustStatus
                objective_reference = $objective
                lower_bound = $lowerBound
                complete_solution_available = $completeSolution
                checker_verified_solution = $checkerVerified
                optimality_status = $optimalityStatus
                literature_source = $literatureSource
                duplicate_cluster_id = ""
                genealogy_status = "NO_EXACT_RELATION"
            }
        )
    }
}

if ($registry.Count -ne 7888) {
    throw (
        "Global registry row count failed: " +
        $registry.Count
    )
}

Write-Host "Unified registry rows: 7888 / 7888"

Write-Step "Auditing historical identifier collisions"

$historicalCollisionRows =
    New-Object System.Collections.Generic.List[object]

$historicalCollisionGroups =
    @(
        $registry.ToArray() |
        Group-Object `
            family,
            original_instance_id |
        Where-Object {
            $_.Count -gt 1
        }
    )

foreach ($collisionGroup in $historicalCollisionGroups) {
    $members =
        @(
            $collisionGroup.Group |
            Sort-Object `
                subfamily,
                global_instance_id
        )

    foreach ($member in $members) {
        $historicalCollisionRows.Add(
            [pscustomobject]@{
                family = $member.family
                original_instance_id = $member.original_instance_id
                subfamily = $member.subfamily
                global_instance_id = $member.global_instance_id
                canonical_xml_path = $member.canonical_xml_path
                fingerprint = $member.fingerprint
                collision_scope = "HISTORICAL_ID_REUSED_ACROSS_SUBFAMILIES"
            }
        )
    }
}

$historicalCollisionPath =
    Join-Path $registryRoot `
        "GLOBAL-HISTORICAL-ID-COLLISIONS-v0.16.4.csv"

$historicalCollisionRows.ToArray() |
    Export-Csv `
        -LiteralPath $historicalCollisionPath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host (
    "Historical ID collision groups: " +
    $historicalCollisionGroups.Count
)

Write-Host (
    "Historical ID collision rows  : " +
    $historicalCollisionRows.Count
)

$globalIdCollisions =
    @(
        $registry.ToArray() |
        Group-Object global_instance_id |
        Where-Object {
            $_.Count -gt 1
        }
    )

if ($globalIdCollisions.Count -ne 0) {
    throw (
        "Global ID construction remains non-unique: " +
        $globalIdCollisions.Count +
        " collision group(s)."
    )
}

Write-Host "Global instance ID uniqueness: PASS"

Write-Step "Computing exact fingerprint duplicate clusters"

$clusters =
    @(
        $registry.ToArray() |
        Group-Object fingerprint |
        Where-Object {
            $_.Count -gt 1
        }
    )

$clusterRows =
    New-Object System.Collections.Generic.List[object]

$lineageRows =
    New-Object System.Collections.Generic.List[object]

$clusterNumber = 0

foreach ($cluster in $clusters) {
    $clusterNumber++

    $clusterId =
        "FPCLUSTER-" +
        $clusterNumber.ToString(
            "D5"
        )

    $members =
        @(
            $cluster.Group |
            Sort-Object global_instance_id
        )

    foreach ($member in $members) {
        $member.duplicate_cluster_id =
            $clusterId

        $member.genealogy_status =
            "EXACT_FINGERPRINT_CLUSTER"

        $clusterRows.Add(
            [pscustomobject]@{
                cluster_id = $clusterId
                fingerprint = $cluster.Name
                global_instance_id = $member.global_instance_id
                family = $member.family
                original_instance_id = $member.original_instance_id
            }
        )
    }

    for (
        $i = 0;
        $i -lt $members.Count;
        $i++
    ) {
        for (
            $j = $i + 1;
            $j -lt $members.Count;
            $j++
        ) {
            $lineageRows.Add(
                [pscustomobject]@{
                    from_global_instance_id =
                        $members[$i].global_instance_id
                    to_global_instance_id =
                        $members[$j].global_instance_id
                    relation =
                        "EXACT_SUPPLY_CHAIN_FINGERPRINT"
                    evidence =
                        $cluster.Name
                }
            )
        }
    }
}

Write-Host (
    "Duplicate fingerprint clusters: " +
    $clusters.Count
)

Write-Host (
    "Exact lineage edges          : " +
    $lineageRows.Count
)

Write-Step "Permanent G30 / G30b non-identity regression guard"

$trigeiroG30 =
    @(
        $registry.ToArray() |
        Where-Object {
            $_.family -eq "TRIGEIRO1989" -and
            (
                $_.original_instance_id -eq "G30" -or
                $_.global_instance_id -match
                    "^TRIGEIRO1989::(?:[^:]+::)?G30$"
            )
        }
    )

if ($trigeiroG30.Count -ne 1) {
    throw (
        "Expected exactly one authoritative Trigeiro G30; found " +
        $trigeiroG30.Count
    )
}

$g30AccidentalAlias =
    @(
        $registry.ToArray() |
        Where-Object {
            $_.family -eq "TRIGEIRO1989" -and
            $_.original_instance_id -match "^G30B$"
        }
    )

if ($g30AccidentalAlias.Count -ne 0) {
    throw (
        "G30b must not be silently materialized or merged as authoritative G30."
    )
}

$g30GuardPath =
    Join-Path $registryRoot `
        "GLOBAL-G30-G30B-NONIDENTITY-GUARD.csv"

@(
    [pscustomobject]@{
        authoritative_instance =
            $trigeiroG30[0].global_instance_id
        authoritative_fingerprint =
            $trigeiroG30[0].fingerprint
        prohibited_name_merge =
            "G30b"
        status =
            "PASS_NON_IDENTITY_GUARD"
        rule =
            "Name similarity never establishes benchmark identity; exact fingerprint plus provenance is required."
    }
) |
    Export-Csv `
        -LiteralPath $g30GuardPath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host "G30/G30b non-identity guard: PASS"

Write-Step "Writing global registry CSV and JSON"

$registryCsv =
    Join-Path $registryRoot `
        "GLOBAL-BENCHMARK-REGISTRY-v0.16.4.csv"

$registryJson =
    Join-Path $registryRoot `
        "GLOBAL-BENCHMARK-REGISTRY-v0.16.4.json"

$registry.ToArray() |
    Sort-Object `
        family,
        subfamily,
        original_instance_id |
    Export-Csv `
        -LiteralPath $registryCsv `
        -NoTypeInformation `
        -Encoding UTF8

$registry.ToArray() |
    Sort-Object `
        family,
        subfamily,
        original_instance_id |
    ConvertTo-Json `
        -Depth 6 |
    Set-Content `
        -LiteralPath $registryJson `
        -Encoding UTF8

$clusterPath =
    Join-Path $registryRoot `
        "GLOBAL-DUPLICATE-CLUSTERS-v0.16.4.csv"

$lineagePath =
    Join-Path $registryRoot `
        "GLOBAL-LINEAGE-EDGES-v0.16.4.csv"

$clusterRows.ToArray() |
    Export-Csv `
        -LiteralPath $clusterPath `
        -NoTypeInformation `
        -Encoding UTF8

$lineageRows.ToArray() |
    Export-Csv `
        -LiteralPath $lineagePath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Building global family and trust summaries"

$familySummary =
    @(
        $registry.ToArray() |
        Group-Object family |
        ForEach-Object {
            $group =
                @($_.Group)

            [pscustomobject]@{
                family = $_.Name
                instances = $group.Count
                with_objective_reference =
                    @(
                        $group |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace(
                                $_.objective_reference
                            )
                        }
                    ).Count
                complete_solutions =
                    @(
                        $group |
                        Where-Object {
                            $_.complete_solution_available -eq
                            "True"
                        }
                    ).Count
                checker_verified =
                    @(
                        $group |
                        Where-Object {
                            $_.checker_verified_solution -eq
                            "True"
                        }
                    ).Count
                verified_proven_optimal =
                    @(
                        $group |
                        Where-Object {
                            $_.trust_status -eq
                            "VERIFIED_PROVEN_OPTIMAL"
                        }
                    ).Count
                unknown_reference =
                    @(
                        $group |
                        Where-Object {
                            $_.trust_status -eq
                            "UNKNOWN_REFERENCE"
                        }
                    ).Count
            }
        } |
        Sort-Object family
    )

$trustSummary =
    @(
        $registry.ToArray() |
        Group-Object trust_status |
        ForEach-Object {
            [pscustomobject]@{
                trust_status = $_.Name
                instances = $_.Count
            }
        } |
        Sort-Object `
            instances `
            -Descending
    )

$familySummary |
    Export-Csv `
        -LiteralPath (
            Join-Path $registryRoot `
                "GLOBAL-FAMILY-SUMMARY-v0.16.4.csv"
        ) `
        -NoTypeInformation `
        -Encoding UTF8

$trustSummary |
    Export-Csv `
        -LiteralPath (
            Join-Path $registryRoot `
                "GLOBAL-TRUST-SUMMARY-v0.16.4.csv"
        ) `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Building global open-challenge catalogue"

$challenges =
    New-Object System.Collections.Generic.List[object]

foreach ($row in $registry.ToArray()) {
    if (
        $row.trust_status -eq
        "UNKNOWN_REFERENCE"
    ) {
        $challenges.Add(
            [pscustomobject]@{
                global_instance_id =
                    $row.global_instance_id
                family =
                    $row.family
                challenge =
                    "REFERENCE_VALUE_UNKNOWN"
                priority =
                    "RESULT_RECONCILIATION"
            }
        )
    }

    if (
        $row.trust_status -eq
        "LITERATURE_VALUE" -or
        $row.trust_status -eq
        "LITERATURE_BEST_REPORTED"
    ) {
        $challenges.Add(
            [pscustomobject]@{
                global_instance_id =
                    $row.global_instance_id
                family =
                    $row.family
                challenge =
                    "LITERATURE_VALUE_NEEDS_COMPLETE_SOLUTION_CERTIFICATE"
                priority =
                    "CHECKER_VERIFICATION"
            }
        )
    }
}

$challengePath =
    Join-Path $registryRoot `
        "GLOBAL-OPEN-CHALLENGES-v0.16.4.csv"

$challenges.ToArray() |
    Export-Csv `
        -LiteralPath $challengePath `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Generating global GitHub benchmark pages"

$indexPage =
    New-Object System.Collections.Generic.List[string]

$indexPage.Add(
    "# LotSizingDataModel benchmark registry"
)

$indexPage.Add("")

$indexPage.Add(
    "> Unified provenance, fingerprint and result-trust registry generated by v0.16.4."
)

$indexPage.Add("")

$indexPage.Add(
    "**Canonical instances: 7,888**"
)

$indexPage.Add("")

$indexPage.Add(
    "No benchmark instances are merged by historical name similarity. Exact SupplyChainFingerprint plus provenance is required for identity or genealogy claims."
)

$indexPage.Add("")

$indexPage.Add("## Families")
$indexPage.Add("")
$indexPage.Add(
    "| Family | Instances | Objective refs | Checker verified | Proven optimal | Unknown reference |"
)
$indexPage.Add(
    "|---|---:|---:|---:|---:|---:|"
)

foreach ($row in $familySummary) {
    $indexPage.Add(
        "| " +
        $row.family +
        " | " +
        $row.instances +
        " | " +
        $row.with_objective_reference +
        " | " +
        $row.checker_verified +
        " | " +
        $row.verified_proven_optimal +
        " | " +
        $row.unknown_reference +
        " |"
    )
}

$indexPage.Add("")
$indexPage.Add("## Trust classes")
$indexPage.Add("")
$indexPage.Add("| Trust status | Instances |")
$indexPage.Add("|---|---:|")

foreach ($row in $trustSummary) {
    $indexPage.Add(
        "| " +
        $row.trust_status +
        " | " +
        $row.instances +
        " |"
    )
}

$indexPage.Add("")
$indexPage.Add("## Identity safeguards")
$indexPage.Add("")
$indexPage.Add(
    "- `G30` and transformed `G30b` are permanently protected from name-based merging."
)
$indexPage.Add(
    "- Duplicate clusters are generated only from exact canonical fingerprints."
)
$indexPage.Add(
    "- Literature objectives remain distinct from checker-verified complete solutions."
)

[IO.File]::WriteAllLines(
    (Join-Path $githubRoot "README.md"),
    $indexPage.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

$challengePage =
    New-Object System.Collections.Generic.List[string]

$challengePage.Add(
    "# Global benchmark open challenges"
)

$challengePage.Add("")
$challengePage.Add(
    "Machine-readable challenge catalogue: `catalog/global/GLOBAL-OPEN-CHALLENGES-v0.16.4.csv`."
)
$challengePage.Add("")
$challengePage.Add(
    "Priority remains conservative: locate provenance-backed reference values and complete solution certificates; do not infer optimality from an objective value alone."
)

[IO.File]::WriteAllLines(
    (Join-Path $githubRoot "OPEN-CHALLENGES.md"),
    $challengePage.ToArray(),
    (New-Object Text.UTF8Encoding($false))
)

Write-Step "Validating machine-readable global registry"

$validatorProject =
    Join-Path $BenchmarkRepo `
        "tools\GlobalRegistryValidator\GlobalRegistryValidator.csproj"

if (-not (
    Test-Path `
        -LiteralPath $validatorProject `
        -PathType Leaf
)) {
    throw "GlobalRegistryValidator project missing."
}

& dotnet build `
    $validatorProject `
    -c Release `
    --nologo

if ($LASTEXITCODE -ne 0) {
    throw "GlobalRegistryValidator build failed."
}

& dotnet run `
    --project $validatorProject `
    -c Release `
    --no-build `
    -- `
    $registryJson `
    "7888"

if ($LASTEXITCODE -ne 0) {
    throw "Global registry validator failed."
}

Write-Step "Cleaning obsolete Cattrysse CodePages package reference when safe"

$cattrysseProject =
    Join-Path $BenchmarkRepo `
        "tools\CattrysseSemanticReader\CattrysseSemanticReader.csproj"

if (
    Test-Path `
        -LiteralPath $cattrysseProject `
        -PathType Leaf
) {
    $projectText =
        [IO.File]::ReadAllText(
            $cattrysseProject
        )

    $cleaned =
        $projectText -replace (
            '(?m)^\s*<PackageReference Include="System\.Text\.Encoding\.CodePages"[^>]*/>\s*\r?\n?',
            ''
        )

    if ($cleaned -ne $projectText) {
        [IO.File]::WriteAllText(
            $cattrysseProject,
            $cleaned,
            (New-Object Text.UTF8Encoding($false))
        )

        Write-Host (
            "Removed redundant System.Text.Encoding.CodePages PackageReference."
        )
    }
}

Write-Step "v0.16.4 final postconditions"

Write-Host "Global Benchmark Registry & Trust Catalogue"
Write-Host "==========================================="
Write-Host "DJ2000 canonical            : 176"
Write-Host "STADTLER2003 canonical      : 2100"
Write-Host "SUERIE_CLSPL canonical      : 1291"
Write-Host "TRIGEIRO1989 canonical      : 751"
Write-Host "TD1996 canonical            : 3450"
Write-Host "CATTRYSSE1990 canonical     : 120"
Write-Host "Global canonical registry   : 7888"
Write-Host ("Duplicate fingerprint clusters: " + $clusters.Count)
Write-Host ("Exact lineage edges         : " + $lineageRows.Count)
Write-Host "G30/G30b identity guard      : PASS"
Write-Host ("Open challenge records      : " + $challenges.Count)
Write-Host ("Registry CSV                : " + $registryCsv)
Write-Host ("Registry JSON               : " + $registryJson)
Write-Host ("Reports                     : " + $reportRoot)

if ($DryRun) {
    Write-Host "Dry-run postconditions: PASS"
}
