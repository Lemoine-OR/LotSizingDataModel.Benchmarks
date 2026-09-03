# Tempelmeier-Derstroff 1996 benchmark

> Complete user-provided 3450-instance corpus integrated in LotSizingDataModel.Benchmarks v0.13.1.

| Metric | Count |
|---|---:|
| Source DAT files | **3450** |
| Canonical LotSizingDataModel XML | **3450** |
| Structural Checker invalid | **0** |
| Fingerprinted XML | **3450** |
| Exact cross-family fingerprint pairs | **0** |

## Structural classes

| Class | Instances |
|---|---:|
| TD-C100-T16-R10-F15 | **150** |
| TD-C10-T4-R3-F1 | **1050** |
| TD-C10-T4-R3-F4 | **1050** |
| TD-C40-T16-R6-F2 | **600** |
| TD-C40-T16-R6-F6 | **600** |

## Source-format ambiguity

Resource membership is explicit when a CL_Produit resource component is nonzero. The supplied format contains 1200 item rows whose entire setup-cost resource vector is zero. Of these, 600 have a positive scalar setup time. v0.13.1 does not invent a resource for those rows; the ambiguity is retained explicitly in the metadata catalogue.

## Reference values

No best-known objective or optimality status is promoted by this release. Reference status remains UNKNOWN_REFERENCE pending a dedicated trust-gate reconciliation.
