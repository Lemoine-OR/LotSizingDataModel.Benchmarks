# DJ2000 phases 1 and 2 — stocks échelon

136 canonical instances from the local LotSizingDataModel.Benchmarks repository.
Source XML SHA256 fingerprints are recorded in manifest.json. No source instance or
installed repository is modified. The model source is a disposable clone of v0.50.

The Clark-Armentano F(E) builder is reused with the LotSizingDataModel CPLEX translator.
All 136 instances have zero lead times, zero initial stocks and production unit costs,
nonnegative setup costs and strictly positive physical holding costs. All calendars
therefore coincide, eliminating the shifted-window objective issue of the general
positive-lead bridge. Ten Phase 2 instances have three end items. An explicit
zero-lead graph extension sets every offset to zero without creating artificial items.
The algebraic F(I)/F(E) equations and objective are unchanged. This extension is
confined to the campaign clone and is not silently deployed to MLLPAlgorithm.

39 Phase 2 XML files use a named standalone warehouse containing no costs, capacity,
or other decision parameters. The baseline core rejects the mere presence of that
warehouse category. For input qualification only, the runner checks that these
warehouse records have no child data and only name/id attributes, then maps their
inventory references to the single plant warehouse in memory. Original XML files,
item inventory costs and optimization inputs are unchanged. The final checker reads
the original XML directly. Warehouses with any additional model data remain rejected.

Setup linking bounds are the remaining cumulative external demand recursively
expanded through the BOM for each item and period. With zero initial stock, no
minimum lot sizes and nonnegative production/setup and positive holding costs, an
optimum without surplus production exists. These bounds preserve such an optimum.

CPLEX parameters: no time limit; 4 threads; seed 1; relative MIP gap 0;
absolute MIP gap 1e-7 (stricter than the requested final 1e-5); integrality tolerance 0;
simplex feasibility and optimality tolerances 1e-9; numerical emphasis enabled.
The actual native parameter file and model are saved for every instance. Native
parameters are applied directly because the pinned adapter defers string parameters.
The existing LotSizingDataModel translator is still used; no alternative solver
formulation is substituted.

After the original MIP reports Optimal, every binary is fixed to exact 0/1 and
converted to continuous before a new LP optimization. The original unfixed MIP
bound is preserved. Fixed-binary LP optimality alone never establishes MIP optimality.
The final quantities are reconstructed as rational numbers (denominator <= 1,000,000,
maximum permitted correction 1e-8). Physical inventories are rebuilt from original
decimal XML values interpreted exactly, with exact nonnegativity and material balances.
Setup linking bounds, echelon balance equations and equality of the physical/echelon
costs are checked in rational arithmetic. The exact final cost is compared against
the ORIGINAL global MIP bound: absolute difference <= 1e-5 is required.

Bounds above the exact cost due to floating point are explicitly recorded by a
signed gap; the discrepancy is never silently clamped. This is numerical optimality
within the requested tolerance using a CPLEX global bound, not an independently
verified exact rational lower-bound certificate. Any failure remains REVIEW_REQUIRED
and is not counted as an optimal solution. Such cases require investigation/re-solve.

The solution files preserve exact binary values and rational quantities, both stock
representations, objective and bound. No generic NoProof export is relabelled blindly.
Status OPTIMAL_WITHIN_ABSOLUTE_GAP refers specifically to the checked final solution.
Dashboard columns separate MIP, fixed-binary LP, independent verification and total time.

Preflight tests: F(I)/F(E) native solves on single-item, two-end-item and shared-component
instances with independently known optima 6, 12 and 17. A forged bound must fail final
optimality validation. These synthetic cases are never counted in the benchmark results.

Canonical solution.xml files retain ProvenOptimal, the ACTUAL nonzero absolute gap,
global bound and the explicit 1e-5 qualification. Their round-trip validation uses
LotSizingSolutionValidator(numericalTolerance: 1e-5), matching the requested criterion.
The library default is 1e-9 and can flag a proven-optimal metadata gap above 1e-9;
use the campaign tolerance when importing these results. No gap is rewritten to zero.
This does not relax binary or material-balance checks: those are independently exact.

## Public verification

All 136 source files match benchmark commit 58778770900df49c724ced4ed6ab7744b0f7661f byte for byte. Run `python docs/portal/campaigns/dj2000-echelon-2026-09-19/audit_final.py` from the repository, or pass `--repository PATH` after extracting the download. This reopens every canonical solution, checks its recorded SHA256 and exact decisions against the source XML, recalculates costs and checks final optimality against the retained numerical bound. No CPLEX installation is required for this audit.

Published runtime totals cover successful solves and their verification, not software preparation, unsuccessful qualification attempts, or subsequent XML export and final re-audit. Historical v1.0.0 registry data are retained unchanged; the portal applies this dated campaign as additional evidence.
