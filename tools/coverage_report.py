#!/usr/bin/env python3
from pathlib import Path
import csv

root = Path(".")
registry_path = root / "catalog" / "global" / "GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv"
trust_path = root / "catalog" / "global" / "GLOBAL-NORMALIZED-TRUST-v1.0.0.csv"
challenge_path = root / "catalog" / "global" / "GLOBAL-OPEN-CHALLENGES-v1.0.0.csv"
with registry_path.open(encoding="utf-8-sig") as f:
    registry = list(csv.DictReader(f))
with trust_path.open(encoding="utf-8-sig") as f:
    trust = list(csv.DictReader(f))
with challenge_path.open(encoding="utf-8-sig") as f:
    challenges = list(csv.DictReader(f))

families = sorted({r["family"] for r in registry})
statuses = {}
for row in trust:
    status = row["normalized_trust_status"]
    statuses[status] = statuses.get(status, 0) + 1

print(f"Canonical families: {len(families)}")
print(f"Canonical instances: {len(registry)}")
print(f"Actionable challenges: {len(challenges)}")
for status, count in sorted(statuses.items()):
    print(f"Trust {status}: {count}")
