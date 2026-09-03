# Cattrysse-Maes-Van Wassenhove CLSP benchmark

> Complete 120-instance corpus and associated historical result workbooks integrated by v0.14.1.

| Group | Instances | Dimensions | Workbook |
|---|---:|---|---|
| Set 1 | 40 | 50 items x 8 periods | lot50.xls |
| Set 2 | 40 | 20 items x 20 periods | lot20b.xls |
| Set 3 | 40 | 8 items x 50 periods | lot8.xls |

## Provenance

The 
ote bundled in the user archive explicitly associates the three 40-instance sets with the three Excel result workbooks and identifies Prof. Dirk Cattrysse / Centre for Industrial Management, KU Leuven as the source.

## Source format

Each original TEST file is parsed as a numeric token stream: (items, periods), items x periods demand values, periods capacities, then items triples interpreted as fixed setup cost, holding cost and unit capacity consumption. This contract matches all 120 source files exactly.

## Result trust

All numeric cells on workbook rows identified with TEST1..TEST120 are preserved as LITERATURE_WORKBOOK_RESULT_CELL. The workbooks contain several heuristic/method columns (for example ABCX, ABCX20, ABCXexp, HEUR1...). v0.14.1 does not guess which numeric cells are objective values versus timings or auxiliary measurements, and therefore promotes no value to BEST_KNOWN or VERIFIED_*.

Structural Checker: **VALID 120/120**.
