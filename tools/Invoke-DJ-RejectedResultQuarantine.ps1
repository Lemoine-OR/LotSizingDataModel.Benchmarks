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

function Extract-PhId {
    param([string]$Text)
    if ($Text -match "(?i)(ph[123]in[0-9]+(?:st[0-9]+de[0-9]+mh[0-9]+ms[0-9]+)?)") {
        return $Matches[1].ToLowerInvariant()
    }
    return ""
}

function Escape-Md {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace("|","\|")
}

$familyRoot = Join-Path $BenchmarkRepo "benchmarks\DJ2000"
$gateCsv = Join-Path $familyRoot "metadata\DJ-TRUST-GATE.csv"
$phaseSummary = Join-Path $familyRoot "metadata\DJ-CHECKER-PHASE-SUMMARY.csv"

if (-not (Test-Path -LiteralPath $gateCsv -PathType Leaf)) {
    throw "Trust gate output missing. Install/run v0.2.6 first."
}

$gateRows = Import-Csv -LiteralPath $gateCsv
$phaseRows = Import-Csv -LiteralPath $phaseSummary

$badRoot = Join-Path $familyRoot "known-bad-results"
New-Item -ItemType Directory -Path $badRoot -Force | Out-Null

$rejected = New-Object System.Collections.Generic.List[object]

Write-Step "Inspecting checker candidate reports for invalid references"

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $candidateDir = Join-Path $familyRoot ("checker-reports\" + $phase + "\candidates")
    if (-not (Test-Path -LiteralPath $candidateDir -PathType Container)) {
        continue
    }

    foreach ($report in Get-ChildItem -LiteralPath $candidateDir -Filter "candidate-*.txt" -File) {
        $text = Get-Content -LiteralPath $report.FullName -Raw -Encoding UTF8

        # The standard checker report uses VALID/INVALID in the candidate report.
        $isInvalid = ($text -match "(?im)\bINVALID\b")
        if (-not $isInvalid) { continue }

        $canonicalId = Extract-PhId -Text $text

        if ([string]::IsNullOrWhiteSpace($canonicalId)) {
            # Fall back to the only claimed candidate in this phase if unique.
            $claimed = @($gateRows | Where-Object {
                $_.phase -eq $phase -and
                $_.previous_claim -ne "UNKNOWN" -and
                -not [string]::IsNullOrWhiteSpace($_.objective)
            })
            if ($claimed.Count -eq 1) {
                $canonicalId = $claimed[0].canonical_id
            }
        }

        if ([string]::IsNullOrWhiteSpace($canonicalId)) {
            $canonicalId = "unknown-candidate"
        }

        $matchingGate = @($gateRows | Where-Object {
            $_.phase -eq $phase -and $_.canonical_id -eq $canonicalId
        } | Select-Object -First 1)

        $objective = ""
        $previousClaim = ""
        if ($matchingGate.Count -gt 0) {
            $objective = $matchingGate[0].objective
            $previousClaim = $matchingGate[0].previous_claim
        }

        $targetDir = Join-Path $badRoot ($phase + "\" + $canonicalId)
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

        Copy-Item -LiteralPath $report.FullName -Destination (Join-Path $targetDir $report.Name) -Force

        $manifest = Join-Path $familyRoot ("checker-reports\" + $phase + "\campaign-items.tsv")
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            Copy-Item -LiteralPath $manifest -Destination (Join-Path $targetDir "campaign-items.tsv") -Force
        }

        $validation = Join-Path $familyRoot ("checker-reports\" + $phase + "\campaign-validation.txt")
        if (Test-Path -LiteralPath $validation -PathType Leaf) {
            Copy-Item -LiteralPath $validation -Destination (Join-Path $targetDir "campaign-validation.txt") -Force
        }

        $summary = Join-Path $familyRoot ("checker-reports\" + $phase + "\campaign-summary.txt")
        if (Test-Path -LiteralPath $summary -PathType Leaf) {
            Copy-Item -LiteralPath $summary -Destination (Join-Path $targetDir "campaign-summary.txt") -Force
        }

        $rejected.Add([pscustomobject]@{
            phase = $phase
            canonical_id = $canonicalId
            rejected_objective = $objective
            previous_claim = $previousClaim
            status = "REJECTED_BY_CHECKER"
            checker_report = $report.FullName
            reason = "Full LotSizingDataModel.Checker campaign marked this candidate invalid."
        })
    }
}

$rejectedCsv = Join-Path $familyRoot "metadata\DJ-REJECTED-RESULTS.csv"
$rejected | Export-Csv -LiteralPath $rejectedCsv -NoTypeInformation -Encoding UTF8

Write-Step "Updating trust catalogue"

foreach ($r in $gateRows) {
    $bad = @($rejected | Where-Object {
        $_.phase -eq $r.phase -and $_.canonical_id -eq $r.canonical_id
    })
    if ($bad.Count -gt 0) {
        $r.trust_status = "REJECTED_BY_CHECKER"
        $r.automatic_promotion_allowed = "False"
        $r.trust_reason = "Candidate rejected by full LotSizingDataModel.Checker campaign."
    }
}

$gateRows | Export-Csv -LiteralPath $gateCsv -NoTypeInformation -Encoding UTF8

Write-Step "Generating known-bad-results page"

$badLines = New-Object System.Collections.Generic.List[string]
$badLines.Add("# Known rejected benchmark results")
$badLines.Add("")
$badLines.Add("> These records are preserved for scientific traceability. They are **not** valid benchmark references.")
$badLines.Add("")
$badLines.Add("| Phase | Instance | Rejected objective | Previous claim | Status |")
$badLines.Add("|---|---|---:|---|---|")

foreach ($b in ($rejected | Sort-Object phase,canonical_id)) {
    $obj = $b.rejected_objective
    if ([string]::IsNullOrWhiteSpace($obj)) { $obj = "unknown" }
    $badLines.Add("| $($b.phase) | ``$($b.canonical_id)`` | $obj | $(Escape-Md $b.previous_claim) | **REJECTED_BY_CHECKER** |")
}

if ($rejected.Count -eq 0) {
    $badLines.Add("| - | - | - | - | No rejected candidates found |")
}

[System.IO.File]::WriteAllLines(
    (Join-Path $badRoot "README.md"),
    $badLines,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "Regenerating phase result pages"

foreach ($phase in @("Phase1","Phase2","Phase3")) {
    $phaseRoot = Join-Path $familyRoot $phase
    $rows = @($gateRows | Where-Object { $_.phase -eq $phase } | Sort-Object canonical_id)
    $checkerPhase = @($phaseRows | Where-Object { $_.Phase -eq $phase } | Select-Object -First 1)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Dellaert-Jeunet - $phase")
    $lines.Add("")
    $lines.Add("> Result status is trust-gated by `LotSizingDataModel.Checker`.")
    $lines.Add("")
    if ($checkerPhase.Count -gt 0) {
        $lines.Add("## Checker campaign")
        $lines.Add("")
        $lines.Add("| Candidates | Valid | Invalid | Overall |")
        $lines.Add("|---:|---:|---:|---|")
        $lines.Add("| $($checkerPhase[0].Candidates) | $($checkerPhase[0].Valid) | $($checkerPhase[0].Invalid) | **$($checkerPhase[0].Overall)** |")
        $lines.Add("")
    }
    $lines.Add("## Instances")
    $lines.Add("")
    $lines.Add("| Instance | Objective | Trust status | Solution |")
    $lines.Add("|---|---:|---|---|")

    foreach ($r in $rows) {
        $obj = $r.objective
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = "unknown" }
        $sol = "No"
        if ($r.solution_available -eq "True") { $sol = "Yes" }
        $lines.Add("| ``$($r.canonical_id)`` | $obj | **$($r.trust_status)** | $sol |")
    }

    [System.IO.File]::WriteAllLines(
        (Join-Path $phaseRoot "README.md"),
        $lines,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

$verified = @($gateRows | Where-Object { $_.trust_status -eq "VERIFIED_PROVEN_OPTIMAL" }).Count
$rejectedCount = @($gateRows | Where-Object { $_.trust_status -eq "REJECTED_BY_CHECKER" }).Count
$unknown = @($gateRows | Where-Object { $_.trust_status -eq "UNKNOWN" }).Count

$familyReadme = New-Object System.Collections.Generic.List[string]
$familyReadme.Add("# Dellaert-Jeunet benchmark")
$familyReadme.Add("")
$familyReadme.Add("> Curated and independently checked LotSizingDataModel benchmark corpus.")
$familyReadme.Add("")
$familyReadme.Add("| Trust state | Count |")
$familyReadme.Add("|---|---:|")
$familyReadme.Add("| Verified proven optimal | **$verified** |")
$familyReadme.Add("| Rejected by checker | **$rejectedCount** |")
$familyReadme.Add("| Unknown objective | **$unknown** |")
$familyReadme.Add("")
$familyReadme.Add("Rejected historical/local claims are preserved under [`known-bad-results/`](./known-bad-results/) for traceability.")
$familyReadme.Add("")
$familyReadme.Add("A rejected result is never silently deleted and can never be promoted as a BKV without a new valid solution.")

[System.IO.File]::WriteAllLines(
    (Join-Path $familyRoot "README.md"),
    $familyReadme,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Step "Quarantine summary"
Write-Host ("Rejected candidate records: " + $rejected.Count)
foreach ($b in $rejected) {
    Write-Host ("  " + $b.phase + " " + $b.canonical_id + " objective=" + $b.rejected_objective)
}
Write-Host ("Verified proven optimal remaining: " + $verified)
Write-Host ("Unknown objectives: " + $unknown)
