# Candidate solutions

A candidate must provide a metadata JSON file and, whenever possible, a complete LotSizingDataModel solution.

## Promotion conditions

1. canonical instance identity resolved;
2. complete solution loads successfully;
3. LotSizingDataModel.Checker --level full returns valid;
4. objective is recomputed independently;
5. recomputed objective equals the declared objective within tolerance;
6. candidate is strictly better than the current reference, or proves optimality;
7. prior reference remains in result history.

A value-only publication may update the literature history but cannot become VERIFIED_BEST_KNOWN without a complete valid solution.
