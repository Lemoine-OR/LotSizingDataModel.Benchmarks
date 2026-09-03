param(
    [string]$BenchmarkRepo = "D:\Dev\LotSizingDataModel.Benchmarks",
    [string]$ModelRepo = "D:\Dev\LotSizingDataModel",
    [string]$ClassesCsv = "A+,B+,C,C+,D,D+,E,E+",
    [switch]$SkipReferenceIngestion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Classes = @(
    $ClassesCsv.Split(',') |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$expectedClassSet = @("A+","B+","C","C+","D","D+","E","E+")
$unknownClasses = @(
    $Classes |
    Where-Object { $expectedClassSet -notcontains $_ }
)

if ($unknownClasses.Count -gt 0) {
    throw ("Unknown Stadtler classes: " + ($unknownClasses -join ","))
}


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

function Split-Domain {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return @($Value.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Safe-Code {
    param([string]$Value)
    return [regex]::Replace($Value, "[^A-Za-z0-9_+.-]", "-")
}

function Normalize-Stadtler-Id {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $v = $Value.ToUpperInvariant()
    $v = [regex]::Replace($v, "[^A-Z0-9]", "")

    # Accept the canonical seven-position nomenclature:
    # structure, assignment, setup profile, CV, utilization, TBO, seasonality.
    if ($v -match "([GK])([05])([0-4])([12])([1-5])([234])([012])") {
        return ($Matches[1] + $Matches[2] + $Matches[3] + $Matches[4] +
                $Matches[5] + $Matches[6] + $Matches[7])
    }

    return ""
}

function Get-DemandProfile {
    param([string]$Code)

    if ($Code.Length -lt 7) {
        return "unknown"
    }

    $seasonality = $Code.Substring(6,1)
    if ($seasonality -eq "1" -or $seasonality -eq "2") {
        return "seasonal"
    }

    # The zero-seasonality series still have stochastic variation by CV 1/2.
    return "erratic"
}

function Get-ArchiveTokenFromPath {
    param([string]$Path)

    $leaf = (Split-Path -Leaf $Path).ToLowerInvariant()

    foreach ($token in @(
        "classap","classbp","classcm","classcp",
        "classc","classdp","classd","classep","classe"
    )) {
        if ($leaf -like ($token + "*")) {
            return $token
        }
    }

    $all = $Path.ToLowerInvariant()
    foreach ($token in @(
        "classap","classbp","classcm","classcp",
        "classc","classdp","classd","classep","classe"
    )) {
        if ($all -match ("(^|[\\/_\-.])" + [regex]::Escape($token) + "([\\/_\-.]|$)")) {
            return $token
        }
    }

    return ""
}

function Select-GeneratorDirectory {
    param(
        [string]$MaterializedRoot,
        [string]$ArchiveToken
    )

    $scripts = @(
        Get-ChildItem `
            -LiteralPath $MaterializedRoot `
            -Filter "start_ini.bat" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object {
            (Get-ArchiveTokenFromPath -Path $_.Directory.FullName) -eq $ArchiveToken
        }
    )

    if ($scripts.Count -eq 0) {
        return $null
    }

    # Recursive extraction produced duplicate copies. Prefer the shallowest path,
    # then the shortest path. All copies originate from the same official archive.
    $selected = @(
        $scripts |
        Sort-Object `
            @{Expression={ ($_.FullName.ToCharArray() | Where-Object { $_ -eq '\' }).Count }},
            @{Expression={ $_.FullName.Length }} |
        Select-Object -First 1
    )

    if ($selected.Count -eq 0) {
        return $null
    }

    return $selected[0].Directory.FullName
}

function Prepare-GeneratorCopy {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory
    )

    if (Test-Path -LiteralPath $DestinationDirectory) {
        Remove-Item -LiteralPath $DestinationDirectory -Recurse -Force
    }

    Ensure-Dir $DestinationDirectory
    Copy-Item `
        -Path (Join-Path $SourceDirectory "*") `
        -Destination $DestinationDirectory `
        -Recurse `
        -Force

    $startPath = Join-Path $DestinationDirectory "start_ini.bat"
    if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
        throw "start_ini.bat missing from generator copy: $DestinationDirectory"
    }

    $lines = @(Get-Content -LiteralPath $startPath -ErrorAction Stop)
    $patched = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line -match "(?i)^\s*set\s+ORIGINALDIR\s*=") {
            $patched.Add("if not defined ORIGINALDIR set ORIGINALDIR=" + $DestinationDirectory)
        }
        elseif ($line -match "(?i)^\s*set\s+DATENDIR\s*=") {
            $patched.Add("if not defined DATENDIR set DATENDIR=" + $DestinationDirectory)
        }
        else {
            $patched.Add($line)
        }
    }

    [System.IO.File]::WriteAllLines(
        $startPath,
        $patched,
        [System.Text.Encoding]::ASCII
    )

    return $startPath
}

function Invoke-Generator {
    param(
        [string]$GeneratorDirectory,
        [string]$StartBat,
        [string]$OutputDirectory,
        [string[]]$Arguments
    )

    if (Test-Path -LiteralPath $OutputDirectory) {
        Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    }
    Ensure-Dir $OutputDirectory

    $argText = ($Arguments -join " ")

    Push-Location $GeneratorDirectory
    try {
        $env:ORIGINALDIR = $GeneratorDirectory
        $env:DATENDIR = $OutputDirectory

        $command = 'call "' + $StartBat + '" ' + $argText
        & cmd.exe /d /c $command | Out-Null
    }
    finally {
        Remove-Item Env:ORIGINALDIR -ErrorAction SilentlyContinue
        Remove-Item Env:DATENDIR -ErrorAction SilentlyContinue
        Pop-Location
    }

    $required = @(
        "AUSLAST.PRN",
        "DIREKT-B.PRN",
        "INDEX.PRN",
        "L0.PRN",
        "LT.PRN",
        "MITT_BED.PRN",
        "P-BEDARF.PRN",
        "PRODKOEF.PRN",
        "RUESTZ.PRN",
        "TBO.PRN",
        "UEBER-KS.PRN",
        "ZFKOEF.PRN"
    )

    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $OutputDirectory $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\STADTLER2003"
$materializedRoot = Join-Path $familyRoot "raw\materialized"
$generatedRoot = Join-Path $familyRoot "raw\generated-v0.4.0"
$reportRoot = Join-Path $BenchmarkRepo "reports\v0.4.0"
$campaignFile = Join-Path $BenchmarkRepo "catalog\stadtler-official-campaign-domains.csv"
$converterProject = Join-Path $BenchmarkRepo "tools\TempelmeierConverter\TempelmeierConverter.csproj"

Ensure-Dir $generatedRoot
Ensure-Dir $reportRoot

if (-not (Test-Path -LiteralPath $campaignFile -PathType Leaf)) {
    throw "Official campaign-domain catalogue missing: $campaignFile"
}

if (-not (Test-Path -LiteralPath $converterProject -PathType Leaf)) {
    throw "TempelmeierConverter missing."
}

$specs = @(
    Import-Csv -LiteralPath $campaignFile |
    Where-Object {
        $_.official_test_set -eq "True" -and
        $Classes -contains $_.test_set
    }
)

if ($specs.Count -ne $Classes.Count) {
    throw (
        "Campaign selection mismatch: requested=" +
        $Classes.Count +
        " resolved=" +
        $specs.Count +
        " classes=" +
        ($Classes -join ",")
    )
}

Write-Step "Stadtler official campaign plan"

foreach ($spec in $specs) {
    Write-Host (
        $spec.test_set + ": T=" + $spec.periods +
        " J=" + $spec.items +
        " M=" + $spec.resources +
        " setup=" + $spec.setup_times
    )
}

Write-Step "Building repaired Stadtler converter"

& dotnet build `
    $converterProject `
    -c Release `
    --nologo `
    -p:ModelRepo=$ModelRepo

if ($LASTEXITCODE -ne 0) {
    throw "TempelmeierConverter build failed."
}

$campaignRows = New-Object System.Collections.Generic.List[object]
$classSummary = New-Object System.Collections.Generic.List[object]

foreach ($spec in $specs) {
    Write-Step ("Materializing official test set " + $spec.test_set)

    $sourceDirectory = Select-GeneratorDirectory `
        -MaterializedRoot $materializedRoot `
        -ArchiveToken $spec.archive_token

    if ($null -eq $sourceDirectory) {
        Write-Warning ("No generator directory found for " + $spec.test_set)

        $classSummary.Add([pscustomobject]@{
            test_set = $spec.test_set
            archive_token = $spec.archive_token
            attempted = 0
            materialized = 0
            conversion_candidates = 0
            converted_xml = 0
            status = "GENERATOR_NOT_FOUND"
        })
        continue
    }

    $classFolderName = $spec.test_set.Replace("+","plus")
    $generatorCopy = Join-Path $reportRoot ("generator-" + $classFolderName)
    $startBat = Prepare-GeneratorCopy `
        -SourceDirectory $sourceDirectory `
        -DestinationDirectory $generatorCopy

    $classGenerated = Join-Path $generatedRoot $classFolderName
    Ensure-Dir $classGenerated

    $p1 = Split-Domain $spec.p1_structure
    $p2 = Split-Domain $spec.p2_assignment
    $p3 = Split-Domain $spec.p3_setup_profile
    $p4 = Split-Domain $spec.p4_cv
    $p5 = Split-Domain $spec.p5_utilization
    $p6 = Split-Domain $spec.p6_tbo
    $p7 = Split-Domain $spec.p7_seasonality

    $attempted = 0
    $materialized = 0

    foreach ($a1 in $p1) {
        foreach ($a2 in $p2) {
            foreach ($a3 in $p3) {
                foreach ($a4 in $p4) {
                    foreach ($a5 in $p5) {
                        foreach ($a6 in $p6) {
                            foreach ($a7 in $p7) {
                                $attempted++
                                $code = $a1+$a2+$a3+$a4+$a5+$a6+$a7
                                $outputDirectory = Join-Path $classGenerated $code

                                $ok = Invoke-Generator `
                                    -GeneratorDirectory $generatorCopy `
                                    -StartBat $startBat `
                                    -OutputDirectory $outputDirectory `
                                    -Arguments @($a1,$a2,$a3,$a4,$a5,$a6,$a7)

                                if ($ok) {
                                    $materialized++
                                    $status = "MATERIALIZED_COMPLETE_CONTRACT"
                                }
                                else {
                                    if (Test-Path -LiteralPath $outputDirectory) {
                                        Remove-Item -LiteralPath $outputDirectory -Recurse -Force -ErrorAction SilentlyContinue
                                    }
                                    $status = "REJECTED_BY_GENERATOR_CONTRACT"
                                }

                                $campaignRows.Add([pscustomobject]@{
                                    test_set = $spec.test_set
                                    code = $code
                                    p1_structure = $a1
                                    p2_assignment = $a2
                                    p3_setup_profile = $a3
                                    p4_cv = $a4
                                    p5_utilization = $a5
                                    p6_tbo = $a6
                                    p7_seasonality = $a7
                                    status = $status
                                    source_generator = $sourceDirectory
                                    generated_directory = $(if ($ok) { $outputDirectory } else { "" })
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    Write-Host (
        "Attempted=" + $attempted +
        " materialized=" + $materialized
    )

    Write-Step ("Converting " + $spec.test_set + " to LotSizingDataModel XML")

    $classRoot = Join-Path $familyRoot $classFolderName
    $instancesRoot = Join-Path $classRoot "instances"
    $withRefRoot = Join-Path $classRoot "instances-with-reference"
    $solutionsRoot = Join-Path $classRoot "solutions"
    $metadataRoot = Join-Path $classRoot "metadata"
    $checkerRoot = Join-Path $classRoot "checker-reports"

    foreach ($path in @(
        $instancesRoot,$withRefRoot,$solutionsRoot,$metadataRoot,$checkerRoot
    )) {
        Ensure-Dir $path
    }

    # Clean only v0.4.0 generated XML for deterministic reruns.
    Get-ChildItem -LiteralPath $instancesRoot -Filter "LSDM_STADTLER2003_*.xml" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $convertLog = @(
        & dotnet run `
            --project $converterProject `
            -c Release `
            --no-build `
            -p:ModelRepo=$ModelRepo `
            -- stadtler $classGenerated $instancesRoot 2>&1 |
        ForEach-Object { $_.ToString() }
    )

    [System.IO.File]::WriteAllLines(
        (Join-Path $metadataRoot "conversion.log"),
        $convertLog,
        (New-Object System.Text.UTF8Encoding($false))
    )

    # Normalize notation profile and source code in filename.
    $convertedFiles = @(
        Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
    )

    foreach ($file in $convertedFiles) {
        $code = ""
        if ($file.BaseName -match "([GK][05][0-4][12][1-5][234][012])$") {
            $code = $Matches[1]
        }
        elseif ($file.BaseName -match "([GK][05][0-4][12][1-5][234][012])") {
            $code = $Matches[1]
        }

        if ([string]::IsNullOrWhiteSpace($code)) {
            continue
        }

        $profile = Get-DemandProfile -Code $code
        $newName =
            "LSDM_STADTLER2003_MLCLSP_" +
            $spec.periods + "_" +
            $profile + "_" +
            $code + ".xml"

        $newPath = Join-Path $instancesRoot $newName

        if ($file.FullName -ne $newPath) {
            Move-Item -LiteralPath $file.FullName -Destination $newPath -Force
        }
    }

    $convertedFiles = @(
        Get-ChildItem -LiteralPath $instancesRoot -Filter "*.xml" -File -ErrorAction SilentlyContinue
    )

    foreach ($file in $convertedFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $withRefRoot $file.Name) -Force
    }

    Write-Step ("Checking " + $spec.test_set + " structure")

    if ($convertedFiles.Count -gt 0) {
        $checkerProject =
            Join-Path $ModelRepo "LotSizingDataModel.Checker.Cli\LotSizingDataModel.Checker.Cli.csproj"

        & dotnet run `
            --project $checkerProject `
            -c Release `
            -- `
            $instancesRoot `
            --level structural `
            --output $checkerRoot `
            --no-progress

        $checkerExit = $LASTEXITCODE
    }
    else {
        $checkerExit = -1
    }

    $classSummary.Add([pscustomobject]@{
        test_set = $spec.test_set
        archive_token = $spec.archive_token
        attempted = $attempted
        materialized = $materialized
        conversion_candidates = $materialized
        converted_xml = $convertedFiles.Count
        checker_exit = $checkerExit
        status = $(if ($convertedFiles.Count -eq $materialized -and $checkerExit -eq 0) { "CONVERTED_AND_STRUCTURALLY_VALID" } else { "REVIEW_REQUIRED" })
    })
}

$campaignRows.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-campaign-materialization.csv") `
        -NoTypeInformation `
        -Encoding UTF8

$classSummary.ToArray() |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-class-summary.csv") `
        -NoTypeInformation `
        -Encoding UTF8

Write-Step "Cataloguing the non-official classcm archive"

$legacyDirectory = Select-GeneratorDirectory `
    -MaterializedRoot $materializedRoot `
    -ArchiveToken "classcm"

$legacyRows = @()

if ($null -ne $legacyDirectory) {
    $legacyRows += [pscustomobject]@{
        archive_token = "classcm"
        directory = $legacyDirectory
        official_test_set = "False"
        status = "LEGACY_ARCHIVE_NOT_IN_OFFICIAL_TABLE_1"
        note = "Preserved for provenance; not labelled as an official ninth Stadtler test set."
    }
}

$legacyRows |
    Export-Csv `
        -LiteralPath (Join-Path $reportRoot "stadtler-legacy-archives.csv") `
        -NoTypeInformation `
        -Encoding UTF8

# ============================================================
# REFERENCE INGESTION
# ============================================================
if (-not $SkipReferenceIngestion) {
    Write-Step "Discovering Stadtler objective/lower-bound workbooks"

    $readerProject =
        Join-Path $BenchmarkRepo "tools\StadtlerReferenceReader\StadtlerReferenceReader.csproj"

    $referenceRoot = Join-Path $familyRoot "literature"
    Ensure-Dir $referenceRoot

    $workbooksAll = @(
        Get-ChildItem `
            -LiteralPath $materializedRoot `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)^solutions[a-z]+\.xls$" }
    )

    $bookIndex = @{}
    foreach ($book in $workbooksAll) {
        $sha = (Get-FileHash -LiteralPath $book.FullName -Algorithm SHA256).Hash
        $key = $book.Name.ToLowerInvariant() + "|" + $sha
        if (-not $bookIndex.ContainsKey($key)) {
            $bookIndex[$key] = $book
        }
    }

    $workbooks = @($bookIndex.Values | Sort-Object Name)
    Write-Host ("Unique reference workbooks found: " + $workbooks.Count)

    & dotnet build $readerProject -c Release --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "StadtlerReferenceReader build failed."
    }

    foreach ($book in $workbooks) {
        & dotnet run `
            --project $readerProject `
            -c Release `
            --no-build `
            -- $book.FullName $referenceRoot

        if ($LASTEXITCODE -ne 0) {
            throw ("Could not inspect Stadtler workbook " + $book.FullName)
        }
    }

    $workbookCatalogue = New-Object System.Collections.Generic.List[object]
    foreach ($book in $workbooks) {
        $workbookCatalogue.Add([pscustomobject]@{
            file_name = $book.Name
            full_path = $book.FullName
            sha256 = (Get-FileHash -LiteralPath $book.FullName -Algorithm SHA256).Hash
            source_status = "UPSTREAM_REFERENCE_WORKBOOK"
        })
    }

    $workbookCatalogue.ToArray() |
        Export-Csv `
            -LiteralPath (Join-Path $referenceRoot "stadtler-workbook-catalogue.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Step "Mapping Stadtler workbook codes to generated XML"

    $resolvedCsvs = @(
        Get-ChildItem `
            -LiteralPath $referenceRoot `
            -Filter "*-stadtler-resolved.csv" `
            -File `
            -ErrorAction SilentlyContinue
    )

    $referenceRows = New-Object System.Collections.Generic.List[object]
    $unmappedReferenceRows = New-Object System.Collections.Generic.List[object]

    foreach ($csv in $resolvedCsvs) {
        foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
            $code = Normalize-Stadtler-Id -Value $row.source_instance_id
            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }

            $matches = @(
                Get-ChildItem `
                    -LiteralPath $familyRoot `
                    -Filter ("*" + $code + ".xml") `
                    -File `
                    -Recurse `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -match "\\instances\\" -and
                    $_.FullName -notmatch "\\instances-with-reference\\"
                }
            )

            if ($matches.Count -eq 1) {
                $referenceRows.Add([pscustomobject]@{
                    source_instance_id = $row.source_instance_id
                    canonical_code = $code
                    lsdm_filename = $matches[0].Name
                    lsdm_path = $matches[0].FullName
                    objective = $row.objective
                    lower_bound = $row.lower_bound
                    objective_status = $(if ([string]::IsNullOrWhiteSpace($row.objective)) { "" } else { "LITERATURE_BEST_KNOWN" })
                    lower_bound_status = $(if ([string]::IsNullOrWhiteSpace($row.lower_bound)) { "" } else { "LITERATURE_LOWER_BOUND" })
                    verified = "False"
                    source_workbook = $row.workbook
                    source_sheet = $row.sheet
                    mapping_status = "UNIQUE_STADTLER_7_POSITION_CODE"
                })
            }
            else {
                $unmappedReferenceRows.Add([pscustomobject]@{
                    source_instance_id = $row.source_instance_id
                    canonical_code = $code
                    candidate_xml_count = $matches.Count
                    objective = $row.objective
                    lower_bound = $row.lower_bound
                    source_workbook = $row.workbook
                    source_sheet = $row.sheet
                    status = "UNMAPPED_OR_AMBIGUOUS"
                })
            }
        }
    }

    $metadataFamily = Join-Path $familyRoot "metadata"
    Ensure-Dir $metadataFamily

    $referenceRows.ToArray() |
        Export-Csv `
            -LiteralPath (Join-Path $metadataFamily "STADTLER-LITERATURE-REFERENCES.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    $unmappedReferenceRows.ToArray() |
        Export-Csv `
            -LiteralPath (Join-Path $metadataFamily "STADTLER-LITERATURE-UNMAPPED.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Host ("Mapped Stadtler literature rows: " + $referenceRows.Count)
    Write-Host ("Unmapped/ambiguous Stadtler literature rows: " + $unmappedReferenceRows.Count)
}

# ============================================================
# FINGERPRINT DUPLICATION / GENEALOGY
# ============================================================
Write-Step "Computing ecosystem SupplyChainFingerprint genealogy"

$fingerprintProject =
    Join-Path $BenchmarkRepo "tools\InstanceFingerprint\InstanceFingerprint.csproj"

$dupRoot = Join-Path $reportRoot "fingerprints"
Ensure-Dir $dupRoot

if (Test-Path -LiteralPath $fingerprintProject -PathType Leaf) {
    & dotnet build `
        $fingerprintProject `
        -c Release `
        --nologo `
        -p:ModelRepo=$ModelRepo

    if ($LASTEXITCODE -eq 0) {
        $fpRows = New-Object System.Collections.Generic.List[object]

        foreach ($familySpec in @(
            [pscustomobject]@{
                Family = "STADTLER2003"
                Root = $familyRoot
            },
            [pscustomobject]@{
                Family = "SUERIE_CLSPL"
                Root = (Join-Path $BenchmarkRepo "benchmarks\SUERIE_CLSPL")
            }
        )) {
            $files = @(
                Get-ChildItem `
                    -LiteralPath $familySpec.Root `
                    -Filter "*.xml" `
                    -File `
                    -Recurse `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -match "\\instances\\"
                }
            )

            foreach ($file in $files) {
                $lines = @(
                    & dotnet run `
                        --project $fingerprintProject `
                        -c Release `
                        --no-build `
                        -p:ModelRepo=$ModelRepo `
                        -- $file.FullName 2>&1 |
                    ForEach-Object { $_.ToString() }
                )

                foreach ($line in $lines) {
                    if ($line -match "^OK\|(?<path>[^|]+)\|(?<iid>[^|]*)\|(?<name>[^|]*)\|(?<fp>.+)$") {
                        $fpRows.Add([pscustomobject]@{
                            family = $familySpec.Family
                            path = $Matches["path"]
                            filename = (Split-Path -Leaf $Matches["path"])
                            instance_id = $Matches["iid"]
                            name = $Matches["name"]
                            fingerprint = $Matches["fp"]
                        })
                    }
                }
            }
        }

        $fpRows.ToArray() |
            Export-Csv `
                -LiteralPath (Join-Path $dupRoot "ecosystem-fingerprints.csv") `
                -NoTypeInformation `
                -Encoding UTF8

        $duplicateRows = New-Object System.Collections.Generic.List[object]

        foreach ($group in ($fpRows | Group-Object fingerprint | Where-Object { $_.Count -gt 1 })) {
            $families = @($group.Group.family | Sort-Object -Unique)

            if ($families.Count -lt 2) {
                continue
            }

            foreach ($item in $group.Group) {
                $duplicateRows.Add([pscustomobject]@{
                    fingerprint = $group.Name
                    duplicate_count = $group.Count
                    families = ($families -join ";")
                    family = $item.family
                    filename = $item.filename
                    path = $item.path
                    relation = "EXACT_SUPPLY_CHAIN_DUPLICATE"
                })
            }
        }

        $duplicateRows.ToArray() |
            Export-Csv `
                -LiteralPath (Join-Path $dupRoot "cross-family-exact-duplicates.csv") `
                -NoTypeInformation `
                -Encoding UTF8

        Write-Host (
            "Cross-family exact duplicate rows: " +
            $duplicateRows.Count
        )
    }
}

# ============================================================
# GENEALOGY DOCUMENT
# ============================================================
$genealogy = @(
    [pscustomobject]@{
        parent_family = "TD1996"
        child_family = "STADTLER2003"
        subset = "C,D,E corresponding attributes"
        relation = "PUBLISHED_EXACT_MATCH_FOR_SOME_INSTANCES"
        evidence = "Stadtler/Suerie documentation states some C/D/E instances match Tempelmeier-Derstroff exactly."
        status = "NO_EXACT_CROSSWALK_UNTIL_TD1996_CORPUS_IS_ACQUIRED"
    },
    [pscustomobject]@{
        parent_family = "STADTLER2003"
        child_family = "SUERIE_CLSPL"
        subset = "B+ -> datab"
        relation = "PUBLISHED_SUBSET"
        evidence = "CLSPL website states datab contains 60 MLCLSP instances taken from Stadtler class B+."
        status = "CONTENT_CROSSWALK_AVAILABLE_VIA_LSDM_AND_RAW_PROVENANCE"
    }
)

$genealogy |
    Export-Csv `
        -LiteralPath (Join-Path $BenchmarkRepo "catalog\stadtler-ecosystem-genealogy-v0.4.0.csv") `
        -NoTypeInformation `
        -Encoding UTF8

# ============================================================
# GITHUB PAGES
# ============================================================
Write-Step "Generating Stadtler GitHub pages"

$totalXml = 0
$totalMaterialized = 0

$familyReadme = New-Object System.Collections.Generic.List[string]
$familyReadme.Add("# Stadtler 2003 MLCLSP benchmark")
$familyReadme.Add("")
$familyReadme.Add("> Official eight-set MLCLSP corpus generated from the upstream master files and `start_ini.bat` nomenclature.")
$familyReadme.Add("")
$familyReadme.Add("| Test set | T | J | M | Setup times | Materialized | LSDM XML |")
$familyReadme.Add("|---|---:|---:|---:|---|---:|---:|")

foreach ($spec in $specs) {
    $summary = @(
        $classSummary |
        Where-Object { $_.test_set -eq $spec.test_set } |
        Select-Object -First 1
    )

    $materialized = 0
    $xmlCount = 0

    if ($summary.Count -eq 1) {
        $materialized = [int]$summary[0].materialized
        $xmlCount = [int]$summary[0].converted_xml
    }

    $totalMaterialized += $materialized
    $totalXml += $xmlCount

    $folder = $spec.test_set.Replace("+","plus")
    $familyReadme.Add(
        "| [" + $spec.test_set + "](./" + $folder + "/) | " +
        $spec.periods + " | " +
        $spec.items + " | " +
        $spec.resources + " | " +
        $spec.setup_times + " | " +
        $materialized + " | " +
        $xmlCount + " |"
    )

    $classPath = Join-Path $familyRoot $folder
    Ensure-Dir $classPath

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Stadtler test set " + $spec.test_set)
    $lines.Add("")
    $lines.Add("| Attribute | Value |")
    $lines.Add("|---|---|")
    $lines.Add("| Periods | " + $spec.periods + " |")
    $lines.Add("| Items | " + $spec.items + " |")
    $lines.Add("| Resources | " + $spec.resources + " |")
    $lines.Add("| Setup times | " + $spec.setup_times + " |")
    $lines.Add("| Materialized instances | **" + $materialized + "** |")
    $lines.Add("| LSDM XML | **" + $xmlCount + "** |")
    $lines.Add("")
    $lines.Add("Instances are generated only from parameter values documented by Stadtler and Suerie and accepted only when `start_ini.bat` produces the complete published source-file contract.")

    [System.IO.File]::WriteAllLines(
        (Join-Path $classPath "README.md"),
        $lines,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

$familyReadme.Add("")
$familyReadme.Add("## Coverage")
$familyReadme.Add("")
$familyReadme.Add("- Materialized official instances: **" + $totalMaterialized + "**")
$familyReadme.Add("- LotSizingDataModel XML: **" + $totalXml + "**")
$familyReadme.Add("- Values from spreadsheets remain `LITERATURE_BEST_KNOWN` / `LITERATURE_LOWER_BOUND` until a complete solution is checked.")
$familyReadme.Add("- `classcm.zip` is preserved as a legacy archive but is not presented as a ninth official Table 1 test set.")
$familyReadme.Add("")
$familyReadme.Add("## Genealogy")
$familyReadme.Add("")
$familyReadme.Add("- `SUERIE_CLSPL/datab` is a published 60-instance subset of Stadtler B+.")
$familyReadme.Add("- Some C, D and E instances with corresponding attributes are documented as exact matches of Tempelmeier-Derstroff (1996); exact file-level crosswalk awaits the TD1996 corpus.")

[System.IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $familyReadme,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "v0.4.0 summary"
Write-Host ("Requested classes: " + ($Classes -join ","))
Write-Host ("Official sets processed: " + $specs.Count)
Write-Host ("Official instances materialized: " + $totalMaterialized)
Write-Host ("STADTLER2003 LSDM XML: " + $totalXml)
Write-Host ("Legacy classcm labelled non-official: " + $legacyRows.Count)
Write-Host ("Reports: " + $reportRoot)
