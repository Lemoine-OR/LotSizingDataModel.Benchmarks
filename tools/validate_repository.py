#!/usr/bin/env python3
from pathlib import Path
import csv, re, sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
rx = re.compile(r"^LSDM_[A-Za-z0-9-]+_[A-Za-z0-9-]+_[0-9]+_(stationary|increasing|decreasing|erratic|seasonal|mixed|unknown)_[A-Za-z0-9._-]+\.xml$")

errors = []

family_ids = set()
with (root/"catalog"/"families.csv").open(encoding="utf-8") as f:
    for row in csv.DictReader(f):
        family_ids.add(row["family_id"])

for family in family_ids:
    if not (root/"benchmarks"/family).exists():
        errors.append(f"Missing family directory: {family}")

for p in (root/"benchmarks").rglob("LSDM_*.xml"):
    if not rx.match(p.name):
        errors.append(f"Invalid LSDM filename: {p}")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)

print(f"Repository validation OK ({len(family_ids)} families).")
