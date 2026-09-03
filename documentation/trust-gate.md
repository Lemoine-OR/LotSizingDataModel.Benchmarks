# Result trust gate

No benchmark result is considered verified merely because a source XML or publication labels it optimal.

The trust pipeline is:

`CLAIMED / LITERATURE VALUE → full LotSizingDataModel.Checker campaign → VERIFIED or REVIEW REQUIRED`

The checker campaign is run non-destructively with:
- `--level full`;
- objective absolute and relative tolerances;
- `--no-update-known-result`;
- `--no-promote-known-result`.

Only a phase for which every selected candidate is valid is eligible for automatic promotion in this initial
conservative gate. If one candidate is invalid, the whole phase remains unpromoted until the checker report
identifies and resolves the offending result.

This is deliberately stricter than simply trusting historical benchmark tables, because some published medium
and large DJ reference values are known to be erroneous or inconsistent across papers.
