<div align="center">
  <img src="docs/assets/benchmark-hero.svg" width="100%" alt="LotSizingDataModel.Benchmarks — scientific benchmark explorer">

  <br>

  <a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/"><img src="https://img.shields.io/badge/OPEN_THE_BENCHMARK_EXPLORER-26C6DA?style=for-the-badge&logo=github&logoColor=071D43" alt="Open the benchmark explorer"></a>
  <a href="https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks/releases/tag/v1.0.0"><img src="https://img.shields.io/badge/RELEASE-v1.0.0-2E74B5?style=for-the-badge&logo=github" alt="Release v1.0.0"></a>

  <br><br>

  <strong>A curated, traceable and reproducible benchmark library for lot-sizing research.</strong>

  <br><br>

  [![Validation](https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks/actions/workflows/validate.yml/badge.svg)](https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks/actions/workflows/validate.yml)
  [![Pages](https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks/actions/workflows/pages.yml/badge.svg)](https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/)
  [![Instances](https://img.shields.io/badge/canonical_instances-7%2C905-071D43)](https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/)
  [![Families](https://img.shields.io/badge/problem_families-7-0B2D63)](https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/)
</div>

---

## Explore the benchmark library

The **[interactive benchmark explorer](https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/)** is the recommended entry point. It provides a three-level scientific catalogue:

> **Problem family → instance lot → searchable instance table**

Each lot page reports periods, items, work centers, the strongest known objective value or lower bound, the evidence status, and whether optimality has actually been proved. Every row links directly to its canonical XML file.

<table>
  <tr>
    <td width="33%" align="center"><h3>1 · Choose a problem</h3><p>Seven canonical lot-sizing families presented as visual panels.</p><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/"><strong>Browse problems →</strong></a></td>
    <td width="33%" align="center"><h3>2 · Select a lot</h3><p>Experimental classes and source-defined instance sets remain explicit.</p><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/td1996.html"><strong>View an example →</strong></a></td>
    <td width="33%" align="center"><h3>3 · Inspect evidence</h3><p>Filter instances and distinguish best reported, feasible and proven optimal.</p><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/lots/dj2000--phase1.html"><strong>Open an instance table →</strong></a></td>
  </tr>
</table>

## Canonical problem families

<table>
  <tr>
    <td><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/cattrysse1990.html"><strong>CATTRYSSE1990</strong></a><br><sub>120 instances · 3 lots</sub></td>
    <td><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/dj2000.html"><strong>DJ2000</strong></a><br><sub>176 instances · 3 lots</sub></td>
    <td><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/em1987.html"><strong>EM1987</strong></a><br><sub>17 instances · 8 lots</sub></td>
  </tr>
  <tr>
    <td><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/stadtler2003.html"><strong>STADTLER2003</strong></a><br><sub>2,100 instances · 8 lots</sub></td>
    <td><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/suerie-clspl.html"><strong>SUERIE_CLSPL</strong></a><br><sub>1,291 instances · 1 collection</sub></td>
    <td><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/td1996.html"><strong>TD1996</strong></a><br><sub>3,450 instances · 5 lots</sub></td>
  </tr>
  <tr><td colspan="3" align="center"><a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/portal/families/trigeiro1989.html"><strong>TRIGEIRO1989</strong></a><br><sub>751 instances · 5 lots</sub></td></tr>
</table>

## Release snapshot

| Scientific control | v1.0.0 result |
|---|---:|
| Canonical instances | **7,905** |
| Canonical families | **7** |
| Global identifiers | **Unique** |
| Historical ID collisions | **50 groups / 100 rows, explicitly namespaced** |
| Exact fingerprint duplicates | **0** |
| Exact lineage edges | **0** |
| G30 / G30b non-identity guard | **PASS** |
| Canonical XML SHA-256 checks | **7,905 / 7,905 PASS** |
| Actionable evidence challenges | **125** |

## Repository map

| I need… | Go to |
|---|---|
| Interactive catalogue | **[Benchmark Explorer](https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/)** |
| Canonical XML instances | [`benchmarks/<FAMILY>/instances/`](benchmarks/) |
| Global registry | [`GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv`](catalog/global/GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv) |
| Normalized trust catalogue | [`GLOBAL-NORMALIZED-TRUST-v1.0.0.csv`](catalog/global/GLOBAL-NORMALIZED-TRUST-v1.0.0.csv) |
| Open evidence challenges | [`GLOBAL-OPEN-CHALLENGES-v1.0.0.csv`](catalog/global/GLOBAL-OPEN-CHALLENGES-v1.0.0.csv) |
| Provenance and result policy | [`documentation/`](documentation/) |
| Schemas | [`schemas/`](schemas/) |
| Validation and generation tools | [`tools/`](tools/) |
| Reproducible archive | **[v1.0.0 release](https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks/releases/tag/v1.0.0)** |
| Deferred v2 programme | [`V2-DEFERRED-WORK-v1.0.0.csv`](catalog/global/V2-DEFERRED-WORK-v1.0.0.csv) |

## Evidence is deliberately conservative

An incumbent is not labelled optimal without proof. A complete solution is not labelled verified until the checker confirms feasibility and independently recomputes its objective. Missing evidence remains visible instead of being silently converted into confidence.

| Normalized trust status | Records |
|---|---:|
| `NO_REFERENCE_KNOWN` | 7,684 |
| `LITERATURE_BEST_REPORTED` | 120 |
| `CHECKER_VERIFIED_FEASIBLE` | 96 |
| `REFERENCE_WITH_LOWER_BOUND` | 5 |

The 125 remaining evidence challenges consist of 120 complete-solution/checker tasks for Cattrysse and five primary-source lower-bound reconciliations for Trigeiro.

## Reproducible lineage

```text
Original source
      ↓
Provenance and immutable source hash
      ↓
Lossless conversion to LotSizingDataModel XML
      ↓
Canonical fingerprint and global identity
      ↓
Reference evidence and independent validation
```

No benchmark, parameter, objective value or solution is invented. Missing information is recorded explicitly.

## Scope of v1.0.0

The public repository contains the 7,905 canonical XML instances, metadata, catalogues, schemas, validation reports and reproducibility tooling. Raw working archives, duplicated enriched copies, intermediate reports and build outputs are deliberately excluded.

MULTILSB acquisition and normalization reached 120/120 source instances, but canonical admission remains deferred to v2.0 because shared production-family setup semantics require a separately reviewed extension to `LotSizingDataModel`. No model change is included in v1.0.0.

---

<div align="center">
  <strong>Start with the live catalogue</strong><br><br>
  <a href="https://lemoine-or.github.io/LotSizingDataModel.Benchmarks/"><img src="https://img.shields.io/badge/EXPLORE_7%2C905_INSTANCES-26C6DA?style=for-the-badge&logo=github&logoColor=071D43" alt="Explore 7,905 instances"></a>
</div>
