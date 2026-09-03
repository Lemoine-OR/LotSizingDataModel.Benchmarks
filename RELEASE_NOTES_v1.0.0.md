# LotSizingDataModel.Benchmarks v1.0.0

This release closes the first scientific edition of the benchmark registry.

## Validated corpus

- 7,905 canonical instances across seven families
- globally unique instance identifiers
- 50 historical identifier-collision groups covering 100 rows
- zero exact fingerprint-duplicate clusters
- zero exact lineage edges
- permanent G30/G30b non-identity guard: PASS
- 7,905 canonical XML SHA-256 checks: PASS in the controlled local corpus

## Trust and open work

- 7,684 `NO_REFERENCE_KNOWN`
- 120 `LITERATURE_BEST_REPORTED`
- 96 `CHECKER_VERIFIED_FEASIBLE`
- five `REFERENCE_WITH_LOWER_BOUND`
- 125 actionable evidence challenges
- 27 explicitly documented v2 workstreams

MULTILSB source acquisition and normalization reached 120/120 instances, but canonical admission remains deferred to v2 because shared production-family setup semantics require a separately reviewed extension to LotSizingDataModel. No model change is included in this release.

The repository publishes the useful, maintainable release surface: 7,905 canonical XML instances, schemas, metadata, provenance, documentation, normalized catalogues, validation reports and reproducibility tools. Raw working archives, enriched duplicate copies, intermediate build copies and duplicated historical reports are deliberately excluded.
