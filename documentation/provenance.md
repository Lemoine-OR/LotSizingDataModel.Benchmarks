# Provenance rules

## Identity

Preserve the exact upstream ID and filename.

## Transformations

If a source transforms another benchmark, record the relationship explicitly in `catalog/genealogy.csv`.
Never copy a best-known objective across representations unless equivalence has been demonstrated.

## Corrections

A corrected source file must preserve:
- the unmodified raw input;
- the correction description;
- before/after values;
- justification;
- converter version.

## Missing data

Use `unknown`. Do not reconstruct values unless the published generator is sufficiently specified; reconstructed
instances must be labelled `RECONSTRUCTED_FROM_GENERATOR`, never `ORIGINAL`.
