# Benchmark DataModel Alignment R2

Validated corpus: **7,905 instances**, preserving the original 7,888 and the 17 EM1987 admissions. DataModel version: **1.3.0**.

## Preservation and classification

All 7,905 instances were deserialized and serialized in memory with the freshly built DataModel. The complete SupplyChain XML was compared after namespace/attribute-order/formatting normalization; data values and child order were not normalized or changed. All original fingerprints were recomputed with the DataModel factory and matched exactly. A second deserialization preserved those fingerprints. Embedded known results, instance IDs and best-known-result IDs were checked across the round trip. Classification was also checked not to mutate the SupplyChain fingerprint.

Canonical XML files were not rewritten. Every historical registry field remains unchanged, including global IDs, fingerprints, known objectives, bounds and solution status. New detected size fields are separate from the old metadata.

Classification is produced only through `SupplyChain → LotSizingProblemFeatureExtractor → LotSizingProblemDescriptor → UniversalNotationGenerator → Lsi10ScientificProjector`. Benchmarks performs projection, preservation checks and display grouping, not scientific classification.

`ClassificationConfidence` is null because this projection API has no confidence score. `ClassificationWarnings` explicitly records that limitation. The existing G30/G30b guard and the authoritative G30 fingerprint are preserved; no name-based merge is allowed.

## Compatibility correction in DataModel

The initial seven-family probe exposed a reproducible serialization regression: new default inventory attributes and an empty sales collection changed historical fingerprints. Two new partial-class files suppress serialization only for `salesOptions` when empty, `initialInventoryDecisionMode` when `FixedParameter`, and `initialInventoryDecisionUnitCost` when zero. Nondefault values remain serialized. Existing DataModel sources were not rewritten.

Seven new test cases cover absent defaults, nondefault inventory modes and costs, empty sales and nonempty sales. The corrected seven-family probe and full 7,905-instance run pass exact historical fingerprint checks. Initial diagnostic evidence is retained in the package.

## Builds and tests

- Core: 32 passing tests.
- Instance: 208 passing tests.
- Checker: 201 passing tests.
- Total: **441 passed, zero failed or skipped**.
- All **14 existing Benchmarks tools** rebuilt against the local DataModel with `--no-incremental`.
- Adapter build: zero errors and warnings.
- Existing GlobalRegistryValidator: 7,905 rows, seven families, PASS.
- Negative hash and fingerprint fixtures were rejected as expected.
- Source hashes, exact-symbol preflight, PowerShell parser and fresh-build timestamp guards are supplied.

## Pages

Nine views cover bibliographic family, legacy family, LSI, product structure, capacity, setups, scheduling, status and open challenges. Static checks verify the 7,905 data records against the enriched registry, every XML link, all page assets, and the 125 challenge instances. JavaScript syntax checks pass.

Visual browser testing was blocked by the browser policy for local file URLs. `PAGES|PASS` means the documented static data/link/syntax checks, not a visual-browser certification.

## Installation

The installer verifies the archive and payload SHA-256 hashes, exact source preconditions, protected canonical/result files, paths and parsers before writing. Replaced files are backed up under `.lsi-pack-backups`; new files are journaled. It rebuilds and reclassifies the installed corpus, requires the fresh registry to match the packaged registry, reruns the tests/tools, and rechecks protected files. A validation failure triggers guarded rollback of changed package files. Logs and backup paths are printed by the installer.

The original R2 validation was local. The GitHub publication adds visible Universal and LSI notation cells to all 7,905 instance rows and the 221 known-result rows. Public links target the repository, and the existing normalized evidence catalogue retains the 96 verified DJ2000 solutions. The JSON registry is compacted without changing any value to fit repository file-size limits.

The DataModel compatibility additions are included under `compatibility/datamodel-1.3.0` for reproducibility. This publication modifies only LotSizingDataModel.Benchmarks. The public pages use the validated precomputed registry.
