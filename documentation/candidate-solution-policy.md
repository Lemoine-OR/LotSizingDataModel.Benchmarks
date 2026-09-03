# Candidate solution policy

A candidate reference result can be improved at any time.

A complete candidate solution must pass `LotSizingDataModel.Checker` before promotion. The checker is used
non-destructively first; promotion is a separate repository action.

A rejected candidate is retained for traceability. Historical values are never overwritten.
