#!/usr/bin/env python3
from pathlib import Path
import csv
import hashlib
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
catalog = root / "catalog" / "global"

def read(name):
    with (catalog / name).open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))

registry = read("GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv")
trust = read("GLOBAL-NORMALIZED-TRUST-v1.0.0.csv")
challenges = read("GLOBAL-OPEN-CHALLENGES-v1.0.0.csv")
deferred = read("V2-DEFERRED-WORK-v1.0.0.csv")
collisions = read("GLOBAL-HISTORICAL-ID-COLLISIONS-v0.16.4.csv")

expected = {
    "CATTRYSSE1990": 120, "DJ2000": 176, "EM1987": 17,
    "STADTLER2003": 2100, "SUERIE_CLSPL": 1291,
    "TD1996": 3450, "TRIGEIRO1989": 751,
}
errors = []
if len(registry) != 7905: errors.append("registry rows")
if len(trust) != 7905: errors.append("trust rows")
if len(challenges) != 125: errors.append("challenge rows")
if len(deferred) != 27: errors.append("v2 workstreams")
ids = [r["global_instance_id"] for r in registry]
if len(ids) != len(set(ids)): errors.append("global ID uniqueness")
fps = [r["fingerprint"] for r in registry if r.get("fingerprint")]
if len(fps) != len(set(fps)): errors.append("fingerprint uniqueness")
for family, count in expected.items():
    if sum(r["family"] == family for r in registry) != count:
        errors.append(f"family count {family}")
groups = {(r["family"], r["original_instance_id"]) for r in collisions}
if len(collisions) != 100 or len(groups) != 50: errors.append("historical collisions")
guard = (catalog / "GLOBAL-G30-G30B-NONIDENTITY-GUARD.csv").read_text(encoding="utf-8-sig")
if "PASS_NON_IDENTITY_GUARD" not in guard: errors.append("G30/G30b guard")
hash_failures = 0
for row in registry:
    marker = "\\benchmarks\\"
    source_path = row["canonical_xml_path"]
    offset = source_path.lower().find(marker)
    if offset < 0:
        hash_failures += 1
        continue
    relative = source_path[offset + 1:].replace("\\", "/")
    local_path = root / Path(relative)
    if not local_path.is_file():
        hash_failures += 1
        continue
    digest = hashlib.sha256(local_path.read_bytes()).hexdigest().upper()
    if digest != row["canonical_xml_sha256"].upper():
        hash_failures += 1
if hash_failures: errors.append(f"canonical XML hashes ({hash_failures} failures)")
if errors:
    print("v1.0.0 validation failed: " + ", ".join(errors))
    raise SystemExit(1)
print("GLOBAL_V1.0.0_VALID")
print("ROWS|7905")
print("FAMILIES|7")
print("COLLISIONS|50|100")
print("CHALLENGES|125")
print("V2_WORKSTREAMS|27")
print("CANONICAL_XML_HASHES|7905|PASS")
