# Known-result policy

A benchmark may have a known objective without a known complete solution.

## Result status hierarchy

1. `PROVEN_OPTIMAL`
2. `LITERATURE_BEST_KNOWN`
3. `AUTHOR_BEST_KNOWN`
4. `CURRENT_SOLVER_BEST`
5. `FEASIBLE_SOLUTION`
6. `LOWER_BOUND_ONLY`
7. `UNKNOWN`

The hierarchy is not purely chronological: evidence quality matters.

## Required fields

Every known result records:

- instance identity;
- objective value when known;
- lower/upper bounds when known;
- status;
- source reference;
- publication year/date;
- method/solver if known;
- whether a complete solution is available;
- whether the complete solution has been independently checked.

Historical results are retained when a better result is discovered. The preferred current result is only a
pointer; history is never overwritten.
