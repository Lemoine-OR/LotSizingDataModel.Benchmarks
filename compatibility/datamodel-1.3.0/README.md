# DataModel 1.3.0 XML compatibility prerequisite

The R2 adapter requires the two tested partial-class additions in this directory. They restore historical fingerprints by omitting newly introduced defaults during serialization: an empty sales collection, fixed initial-inventory mode, and zero initial-inventory decision cost. Nondefault values remain serialized.

The matching tests cover default and nondefault values. These files were used in the validated local run of all 7,905 instances and 441 Core/Instance/Checker tests. They contain no classification logic and are not compiled into Benchmarks.

This Benchmarks publication does not modify any other repository. To reproduce R2 with the upstream 1.3.0 source, the corresponding files must first be present in its `LotSizingDataModel.Core` and `LotSizingDataModel.Core.Tests` directories. The R2 runner fails its exact-symbol preflight when they are missing. Do not overwrite differing files.

The precomputed registry and public explorer do not require running the adapter.
