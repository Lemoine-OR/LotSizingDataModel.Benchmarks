# Repository layout

Each benchmark family contains five directories:

- `raw/`: unmodified upstream data when redistribution is permitted;
- `instances/`: pure LotSizingDataModel XML instances;
- `instances-with-reference/`: same instances with reference-result metadata;
- `solutions/`: complete production plans when available;
- `metadata/`: source, licence, hashes, mappings and conversion notes.

The separation between pure instances and enriched instances is intentional. It prevents answer leakage in
algorithmic benchmarks while still providing a convenient curated distribution for validation and comparison.
