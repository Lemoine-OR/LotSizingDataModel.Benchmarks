# Conversion pipeline

```text
upstream source
  → immutable raw file
  → source-specific importer
  → LotSizingInstance
  → model validation
  → XML serialization
  → XML reload / round-trip
  → scientific classification
  → solution checker
  → catalogue update
```

An importer should return the converted instance plus warnings, assumptions and a source mapping.

Target interface concept:

```csharp
public interface IBenchmarkImporter
{
    BenchmarkImportResult Import(
        BenchmarkSource source,
        BenchmarkImportOptions options);
}
```

`BenchmarkImportResult` should contain at least:

- `LotSizingInstance Instance`
- `ValidationReport Validation`
- `SourceMapping Mapping`
- `IReadOnlyList<ImportWarning> Warnings`
- `IReadOnlyList<ConversionAssumption> Assumptions`
- `IReadOnlyList<KnownResult> KnownResults`
```
