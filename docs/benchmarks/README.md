# LotSizingDataModel benchmark registry

**7,905 canonical instances · DataModel 1.3.0 · Benchmark DataModel Alignment R2**

[Open the scientific catalogue](alignment-r2/index.html)

| Browse by | View |
|---|---|
| Bibliographic family | [Families](alignment-r2/family.html) |
| Legacy problem family | [Legacy families](alignment-r2/legacy.html) |
| LSI 1.0 | [LSI classifications](alignment-r2/lsi.html) |
| Product structure | [Detected structures](alignment-r2/structure.html) |
| Capacity | [Capacity regimes](alignment-r2/capacity.html) |
| Setups | [Setup characteristics](alignment-r2/setups.html) |
| Scheduling | [Scheduling characteristics](alignment-r2/scheduling.html) |
| Benchmark status | [Status](alignment-r2/status.html) |
| Open challenges | [Challenges and resolution criteria](alignment-r2/challenge.html) |

The catalogue uses `SupplyChain → FeatureExtractor → Descriptor → UniversalNotation → LSI` from LotSizingDataModel. Benchmarks contains no independent scientific classification rules.

The original XML files, numerical data, global identifiers, fingerprints, known objectives and known solutions are retained. The G30/G30b non-identity guard remains mandatory. Round-trip guards compare the complete SupplyChain XML, original fingerprints, instance identity and embedded known results for all 7,905 instances.

The historical registry fields remain available unchanged. `DetectedItemCount`, `DetectedPlanningHorizon` and `DetectedWorkCenterCount` expose the current DataModel findings alongside the older metadata. Confidence is explicitly unavailable because the Descriptor/LSI API does not expose a score. Missing reference solutions are not treated as verified solutions.

- [Enriched JSON registry](../../catalog/global/GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.json)
- [Enriched CSV registry](../../catalog/global/GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.csv)
- [Preservation evidence](../../reports/alignment-r2/preservation-evidence.json)
- [Validation report](../../reports/alignment-r2/FINAL-VALIDATION.md)

The historical 7,888-instance corpus is preserved in full; 17 EM1987 instances admitted in v0.21.0 bring the current total to 7,905.
