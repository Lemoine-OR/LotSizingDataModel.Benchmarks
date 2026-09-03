Set-StrictMode -Version Latest

function Get-XmlFilesExact {
    param(
        [string[]]$Roots,
        [switch]$Recurse
    )

    $result =
        New-Object System.Collections.Generic.List[object]

    foreach ($root in $Roots) {
        if (-not (
            Test-Path `
                -LiteralPath $root `
                -PathType Container
        )) {
            continue
        }

        if ($Recurse) {
            $files =
                @(
                    Get-ChildItem `
                        -LiteralPath $root `
                        -Filter "*.xml" `
                        -File `
                        -Recurse
                )
        }
        else {
            $files =
                @(
                    Get-ChildItem `
                        -LiteralPath $root `
                        -Filter "*.xml" `
                        -File
                )
        }

        foreach ($file in $files) {
            $result.Add($file)
        }
    }

    return @(
        $result.ToArray() |
        Sort-Object FullName -Unique
    )
}

function Resolve-CanonicalCorpus {
    param(
        [string]$BenchmarkRepo,
        [string]$Family,
        [int]$ExpectedCount
    )

    $familyRoot =
        Join-Path $BenchmarkRepo (
            "benchmarks\" +
            $Family
        )

    if (-not (
        Test-Path `
            -LiteralPath $familyRoot `
            -PathType Container
    )) {
        throw (
            "Benchmark family root missing: " +
            $familyRoot
        )
    }

    $files = @()
    $layout = ""

    switch ($Family) {
        "SUERIE_CLSPL" {
            $canonicalRoot =
                Join-Path $familyRoot "instances"

            $files =
                @(
                    Get-XmlFilesExact `
                        -Roots @($canonicalRoot) `
                        -Recurse
                )

            $layout =
                "benchmarks\SUERIE_CLSPL\instances"
        }

        "TRIGEIRO1989" {
            $canonicalRoot =
                Join-Path $familyRoot "instances"

            $files =
                @(
                    Get-XmlFilesExact `
                        -Roots @($canonicalRoot) `
                        -Recurse
                )

            $layout =
                "benchmarks\TRIGEIRO1989\instances"
        }

        "TD1996" {
            $canonicalRoot =
                Join-Path $familyRoot "instances"

            $files =
                @(
                    Get-XmlFilesExact `
                        -Roots @($canonicalRoot) `
                        -Recurse
                )

            $layout =
                "benchmarks\TD1996\instances"
        }

        "CATTRYSSE1990" {
            $canonicalRoot =
                Join-Path $familyRoot "instances"

            $files =
                @(
                    Get-XmlFilesExact `
                        -Roots @($canonicalRoot) `
                        -Recurse
                )

            $layout =
                "benchmarks\CATTRYSSE1990\instances"
        }

        "STADTLER2003" {
            $classFolders =
                @(
                    "Aplus",
                    "Bplus",
                    "C",
                    "Cplus",
                    "D",
                    "Dplus",
                    "E",
                    "Eplus"
                )

            $roots =
                @(
                    foreach ($classFolder in $classFolders) {
                        Join-Path $familyRoot (
                            $classFolder +
                            "\instances"
                        )
                    }
                )

            $files =
                @(
                    Get-XmlFilesExact `
                        -Roots $roots `
                        -Recurse
                )

            $layout =
                "eight explicit STADTLER2003 class instance roots"
        }

        "DJ2000" {
            # Prefer a dedicated canonical instances tree when present.
            $dedicatedRoot =
                Join-Path $familyRoot "instances"

            $dedicated =
                @(
                    Get-XmlFilesExact `
                        -Roots @($dedicatedRoot) `
                        -Recurse
                )

            if ($dedicated.Count -eq $ExpectedCount) {
                $files =
                    $dedicated

                $layout =
                    "benchmarks\DJ2000\instances"
            }
            else {
                # Historical DJ layouts used phase-specific canonical trees.
                $phase1InstancesRoot =
                    Join-Path $familyRoot "Phase1\instances"

                $phase2InstancesRoot =
                    Join-Path $familyRoot "Phase2\instances"

                $phase3InstancesRoot =
                    Join-Path $familyRoot "Phase3\instances"

                $phaseInstanceRoots =
                    @(
                        $phase1InstancesRoot
                        $phase2InstancesRoot
                        $phase3InstancesRoot
                    )

                $phaseInstances =
                    @(
                        Get-XmlFilesExact `
                            -Roots $phaseInstanceRoots `
                            -Recurse
                    )

                if ($phaseInstances.Count -eq $ExpectedCount) {
                    $files =
                        $phaseInstances

                    $layout =
                        "DJ2000 Phase1/Phase2/Phase3 instances roots"
                }
                else {
                    # Some stabilized DJ revisions store canonical XML directly
                    # in Phase1/Phase2/Phase3, without an intermediate folder.
                    $phase1Root =
                        Join-Path $familyRoot "Phase1"

                    $phase2Root =
                        Join-Path $familyRoot "Phase2"

                    $phase3Root =
                        Join-Path $familyRoot "Phase3"

                    $phaseRoots =
                        @(
                            $phase1Root
                            $phase2Root
                            $phase3Root
                        )

                    $phaseDirect =
                        @(
                            Get-XmlFilesExact `
                                -Roots $phaseRoots
                        )

                    if ($phaseDirect.Count -eq $ExpectedCount) {
                        $files =
                            $phaseDirect

                        $layout =
                            "DJ2000 Phase1/Phase2/Phase3 direct XML roots"
                    }
                    else {
                        throw (
                            "DJ2000 canonical layout unresolved. " +
                            "Dedicated instances=" +
                            $dedicated.Count +
                            "; phase instances=" +
                            $phaseInstances.Count +
                            "; phase direct=" +
                            $phaseDirect.Count +
                            "; expected=" +
                            $ExpectedCount
                        )
                    }
                }
            }
        }

        default {
            throw (
                "No explicit canonical-corpus rule for family " +
                $Family
            )
        }
    }

    if ($files.Count -ne $ExpectedCount) {
        throw (
            "Canonical corpus count failed for " +
            $Family +
            " using layout '" +
            $layout +
            "': expected=" +
            $ExpectedCount +
            " found=" +
            $files.Count
        )
    }

    return [pscustomobject]@{
        family = $Family
        layout = $layout
        files = $files
        count = $files.Count
    }
}

function Get-FamilyXmlAudit {
    param(
        [string]$BenchmarkRepo,
        [string]$Family,
        [System.IO.FileInfo[]]$CanonicalFiles
    )

    $familyRoot =
        Join-Path $BenchmarkRepo (
            "benchmarks\" +
            $Family
        )

    $canonicalIndex = @{}

    foreach ($file in $CanonicalFiles) {
        $canonicalIndex[
            $file.FullName.ToUpperInvariant()
        ] = $true
    }

    $allXml =
        @(
            Get-ChildItem `
                -LiteralPath $familyRoot `
                -Filter "*.xml" `
                -File `
                -Recurse
        )

    $nonCanonical =
        @(
            $allXml |
            Where-Object {
                -not $canonicalIndex.ContainsKey(
                    $_.FullName.ToUpperInvariant()
                )
            }
        )

    $groups =
        @(
            $nonCanonical |
            ForEach-Object {
                $relative =
                    $_.FullName.Substring(
                        $familyRoot.Length
                    ).TrimStart("\")

                $firstSeparator =
                    $relative.IndexOf("\")

                if ($firstSeparator -lt 0) {
                    $bucket =
                        "(family-root)"
                }
                else {
                    $bucket =
                        $relative.Substring(
                            0,
                            $firstSeparator
                        )
                }

                [pscustomobject]@{
                    bucket = $bucket
                    path = $_.FullName
                }
            } |
            Group-Object bucket |
            ForEach-Object {
                [pscustomobject]@{
                    family = $Family
                    bucket = $_.Name
                    xml_count = $_.Count
                }
            } |
            Sort-Object bucket
        )

    return [pscustomobject]@{
        all_count = $allXml.Count
        canonical_count = $CanonicalFiles.Count
        noncanonical_count = $nonCanonical.Count
        groups = $groups
    }
}
