# Stadtler 2003 MLCLSP - v0.4.0 method

The primary documentation defines exactly eight official test sets: A+, B+, C, C+, D, D+, E and E+.

Each instance is identified by seven parameters: operation structure, resource assignment, setup-time
profile, demand coefficient-of-variation profile, utilization profile, TBO profile and seasonality.

The source explicitly states that `start_ini.bat` creates instances from master files and permits
systematic variation of the attributes. The v0.4.0 materializer therefore enumerates only documented
class-compatible parameter domains and retains a candidate only when the original batch generator
produces the complete published twelve-file instance contract.

Class-specific restrictions:
- A+, C, C+, E, E+: no setup time, so setup profile 0.
- B+: setup profiles 1, 2, 3 and 4.
- D and D+: setup profiles 1 and 4, as documented.
- E and E+: only the documented general/cyclic structure and zero-seasonality demand series.

`classcm.zip` is preserved as legacy provenance but is not labelled an official ninth test set because
the primary source Table 1 defines eight sets.

Published objectives and lower bounds remain literature evidence, never automatically VERIFIED.
