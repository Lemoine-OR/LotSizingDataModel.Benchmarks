# Roadmap update - v0.25.0

Pack F MULTILSB semantic normalization is complete for 120/120 official instances.

- Official raw acquisition: complete
- Deterministic semantic normalization: 120/120
- Normalized JSON reload/round-trip validation: 120/120 pass
- Backlogging representation: supported by LotSizingDataModel
- Remaining blocking gap: shared family setup binary and family setup capacity consumption
- Canonical admission: intentionally zero
- Trust promotion: zero

Next pack: add the family-setup decision semantics to LotSizingDataModel with serialization, validation, classification, solver formulation and tests. Only then generate and admit the 120 canonical MULTILSB XML files and verify the three MIPLIB overlaps.
