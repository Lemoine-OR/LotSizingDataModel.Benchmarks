# LotSizingDataModel.Benchmarks

> **A curated, traceable and reproducible benchmark library for lot-sizing research.**

[![Status](https://img.shields.io/badge/status-v1.0.0-blue)](#project-status)
[![Data model](https://img.shields.io/badge/format-LotSizingDataModel-blue)](#lot-sizing-data-model)
[![Provenance](https://img.shields.io/badge/provenance-required-success)](documentation/provenance.md)
[![BKV policy](https://img.shields.io/badge/BKV-versioned-informational)](documentation/known-results.md)

## Why this repository exists

Lot-sizing research has accumulated decades of benchmark instances across papers, university web pages,
FTP servers, supplementary archives, theses, generators and modern repositories. The same instance may appear
under several names, transformations or mathematical formats, while published objective values are not always
clearly distinguished between *optimal*, *best known*, *heuristic* and *lower bound*.

**LotSizingDataModel.Benchmarks** aims to provide one reproducible reference layer:

**Original source → provenance → LotSizingDataModel XML → validation → known results → reference solution**

No benchmark, parameter, objective value or solution is invented. Missing information is explicitly marked
`unknown`.

## Repository entry points

| I need... | Go to |
|---|---|
| Pure benchmark instances | `benchmarks/<FAMILY>/instances/` |
| Instances enriched with the best available reference | `benchmarks/<FAMILY>/instances-with-reference/` |
| Complete reference solutions | `benchmarks/<FAMILY>/solutions/` |
| Original upstream files | `benchmarks/<FAMILY>/raw/` |
| Source and conversion metadata | `benchmarks/<FAMILY>/metadata/` |
| Global benchmark catalogue | `catalog/` |
| Data generators | `generators/` |
| Conversion / validation rules | `documentation/` |

## Two canonical instance distributions

### 1. Pure instances

`instances/` contains the problem data only. These files are appropriate for algorithm benchmarking because
they contain no embedded answer.

### 2. Instances with reference information

`instances-with-reference/` contains the same problem plus the strongest known result metadata.

A reference may be:

- `PROVEN_OPTIMAL`
- `AUTHOR_BEST_KNOWN`
- `LITERATURE_BEST_KNOWN`
- `CURRENT_SOLVER_BEST`
- `FEASIBLE_SOLUTION`
- `LOWER_BOUND_ONLY`
- `UNKNOWN`

A **complete solution is optional**. If only the best objective value is known, the objective is stored and
`solution_available=false`.

## Complete solutions

When a complete production plan is available, it is stored separately under `solutions/`.
A solution is `VERIFIED` only when the LotSizingDataModel checker confirms feasibility **and** independently
recomputes the declared objective.

## Naming

`LSDM_<source>_<type>_<periods>_<profile>_<id>.xml`

Example:

`LSDM_TD1996_MLCLSP_16_mixed_example-id.xml`

The original source identifier is also stored in metadata; filenames are never the sole identity.

## Initial benchmark families

The bootstrap catalogue already includes Wagner–Whitin, Dixon–Silver, Eppen–Martin, Trigeiro–Thomas–McClain,
Diaby et al., Diaby–Martel, Tempelmeier–Derstroff, Stadtler, Sürie, Dellaert–Jeunet, MULTILSB,
Tempelmeier–Buschkühl, Afentakis–Gavish, Clark–Armentano, Armentano–Berretta–França, Maes–Van Wassenhove,
Haase, Kimms, Fleischmann, Fleischmann–Meyr, Seeanner, Belvaux–Wolsey, CHES, industrial pharmaceutical
instances, Willems-derived networks, CLSP-PM, stochastic timing benchmarks and MIPLIB-derived cases.

See [`catalog/families.csv`](catalog/families.csv).

## Project status

**v1.0.0 — final scientific release of the v1 corpus**

The validated registry contains **7,905 canonical instances across seven families**. Global identifiers are
unique; the 50 historical identifier-collision groups are explicitly namespaced; exact duplicate fingerprint
clusters and exact lineage edges are both zero; and the G30/G30b non-identity guard passes.

The public repository contains the 7,905 canonical XML instances together with the code, schemas,
documentation, final registry, trust catalogue, validation reports and reproducibility manifests. Duplicated
enriched copies, raw working archives, intermediate reports and build outputs are deliberately excluded.

The remaining 125 evidence challenges and 27 v2 workstreams are documented in
`catalog/global/V2-DEFERRED-WORK-v1.0.0.csv`. MULTILSB remains deferred because its shared production-family
setup semantics require a separately reviewed LotSizingDataModel extension.

## Scientific principle

A transformed instance is **not** assumed to be the original instance. A published incumbent is **not**
called optimal without proof. A MIP representation is **not** treated as semantic source data unless the
mapping is documented.

That distinction is the core design rule of this library.
