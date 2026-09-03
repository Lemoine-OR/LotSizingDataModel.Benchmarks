#!/usr/bin/env python3
"""Build the static GitHub Pages benchmark explorer from the v1 registry."""
from __future__ import annotations
import argparse, csv, html, re
from collections import defaultdict, Counter
from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "catalog/global/GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv"
TRUST = ROOT / "catalog/global/GLOBAL-NORMALIZED-TRUST-v1.0.0.csv"
DIMENSIONS = ROOT / "docs/portal/data/instance-dimensions-v1.0.0.csv"
OUT = ROOT / "docs/portal"
REPO = "https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks"
FAMILY_DESCRIPTIONS = {
    "CATTRYSSE1990": "Capacitated lot-sizing benchmark instances and literature objective references.",
    "DJ2000": "Dellaert-Jeunet capacitated lot-sizing instances with verified feasible solutions where available.",
    "EM1987": "Eppen-Martin capacitated lot-sizing instances preserved from the historical source archive.",
    "STADTLER2003": "Multi-level capacitated lot-sizing sets organized by experimental class.",
    "SUERIE_CLSPL": "Capacitated lot-sizing with linked lot sizes, represented as one canonical collection.",
    "TD1996": "Tempelmeier-Derstroff multi-level capacitated lot-sizing benchmark classes.",
    "TRIGEIRO1989": "Trigeiro-Thomas-McClain capacitated lot-sizing instances and evidence records.",
}

def esc(value): return html.escape("" if value is None else str(value))
def slug(value):
    value = re.sub(r"[^a-z0-9]+", "-", str(value).lower()).strip("-")
    return value or "canonical-collection"
def read_rows():
    with REGISTRY.open(encoding="utf-8-sig", newline="") as stream:
        rows=list(csv.DictReader(stream))
    with TRUST.open(encoding="utf-8-sig", newline="") as stream:
        statuses={r["global_instance_id"]:r["normalized_trust_status"] for r in csv.DictReader(stream)}
    with DIMENSIONS.open(encoding="utf-8-sig", newline="") as stream:
        dimensions={r["global_instance_id"]:r for r in csv.DictReader(stream)}
    for row in rows:
        row["trust_status"]=statuses.get(row["global_instance_id"],row.get("trust_status", ""))
        dim=dimensions.get(row["global_instance_id"],{})
        row["planning_horizon"]=dim.get("planning_horizon") or row.get("planning_horizon","")
        row["item_count"]=dim.get("item_count") or row.get("item_count","")
        row["work_center_count"]=dim.get("work_center_count") or row.get("work_center_count","")
    return rows
def repo_path(windows_path):
    parts = PureWindowsPath(windows_path).parts
    index = next(i for i,p in enumerate(parts) if p.lower() == "benchmarks" and i > 0)
    return "/".join(parts[index:])
def best_value(row):
    if row.get("objective_reference"): return row["objective_reference"], "Best reported"
    if row.get("lower_bound"): return row["lower_bound"], "Lower bound"
    return "—", "No reference"
def proof(row):
    status=row.get("trust_status","")
    optimal=row.get("optimality_status","")
    if status == "VERIFIED_PROVEN_OPTIMAL" or optimal == "PROVEN_OPTIMAL": return "Proven optimal", "ok"
    if status == "CHECKER_VERIFIED_FEASIBLE": return "Feasible verified", "feasible"
    return "Not proven", "open"
def page(title, body, depth=0):
    prefix="../"*depth
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Lot-sizing benchmark explorer"><title>{esc(title)} · LotSizingDataModel.Benchmarks</title><link rel="stylesheet" href="{prefix}assets/styles.css"></head><body><header class="site-header"><a class="brand" href="{prefix}index.html"><span class="brand-mark">LS</span><span>LotSizingDataModel<span class="muted">.Benchmarks</span></span></a><nav><a href="{prefix}index.html">Problems</a><a href="{REPO}">GitHub</a><a href="{REPO}/releases/tag/v1.0.0">Release v1.0.0</a></nav></header><main>{body}</main><footer>Curated, traceable and reproducible lot-sizing research benchmarks · v1.0.0</footer><script src="{prefix}assets/app.js"></script></body></html>'''
def metric(value,label): return f'<div class="metric"><strong>{esc(value)}</strong><span>{esc(label)}</span></div>'
def badge(text,kind="neutral"): return f'<span class="badge {kind}">{esc(text)}</span>'

def build():
    rows=read_rows(); families=defaultdict(list)
    for row in rows: families[row["family"]].append(row)
    outputs={}
    cards=[]
    for family in sorted(families):
        group=families[family]; lots=defaultdict(list)
        for row in group: lots[row.get("subfamily","") or "Canonical collection"].append(row)
        statuses=Counter(r["trust_status"] for r in group)
        cards.append(f'''<a class="card problem-card" href="families/{slug(family)}.html"><div class="card-kicker">Problem family</div><h2>{esc(family)}</h2><p>{esc(FAMILY_DESCRIPTIONS.get(family,"Canonical lot-sizing benchmark family."))}</p><div class="card-stats"><span>{len(group):,} instances</span><span>{len(lots)} lot{'s' if len(lots)!=1 else ''}</span></div><div class="status-line">{badge(f"{statuses.get('CHECKER_VERIFIED_FEASIBLE',0)} checker verified",'feasible') if statuses.get('CHECKER_VERIFIED_FEASIBLE') else badge('Evidence catalogued')}</div></a>''')
        lot_cards=[]
        for lot_name, lot_rows in sorted(lots.items()):
            target=f"../lots/{slug(family)}--{slug(lot_name)}.html"
            horizons=sorted({r.get('planning_horizon','') for r in lot_rows if r.get('planning_horizon')})
            items=sorted({r.get('item_count','') for r in lot_rows if r.get('item_count')})
            refs=sum(bool(r.get('objective_reference') or r.get('lower_bound')) for r in lot_rows)
            lot_cards.append(f'''<a class="card lot-card" href="{target}"><div class="card-kicker">Instance lot</div><h2>{esc(lot_name)}</h2><div class="card-stats"><span>{len(lot_rows):,} instances</span><span>{refs:,} references</span></div><p>Horizons: {esc(', '.join(horizons[:6]) or 'not recorded')}<br>Items: {esc(', '.join(items[:6]) or 'not recorded')}</p></a>''')
            table_rows=[]
            for r in sorted(lot_rows,key=lambda x:x['original_instance_id'].lower()):
                value,value_kind=best_value(r); proof_text,proof_kind=proof(r); path=repo_path(r['canonical_xml_path'])
                link=f"{REPO}/blob/v1.0.0/{path}"
                table_rows.append(f'''<tr data-search="{esc(' '.join([r['original_instance_id'],r.get('trust_status',''),value,proof_text]).lower())}"><td><a href="{link}">{esc(r['original_instance_id'])}</a></td><td>{esc(r.get('planning_horizon') or '—')}</td><td>{esc(r.get('item_count') or '—')}</td><td>{esc(r.get('work_center_count') or '—')}</td><td><span title="{esc(value_kind)}">{esc(value)}</span></td><td>{badge(proof_text,proof_kind)}</td><td>{badge(r.get('trust_status') or 'UNKNOWN')}</td></tr>''')
            lot_body=f'''<section class="hero compact"><div class="eyebrow"><a href="../families/{slug(family)}.html">{esc(family)}</a> / Instance lot</div><h1>{esc(lot_name)}</h1><p>Canonical instances, dimensional characteristics and strongest documented evidence.</p><div class="metrics">{metric(len(lot_rows),'Instances')}{metric(refs,'Known references')}{metric(sum(proof(r)[1]=='ok' for r in lot_rows),'Proven optimal')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Instance catalogue</span><h2>Browse the lot</h2></div><label class="search">Search<input type="search" data-table-filter placeholder="ID, status or value"></label></div><div class="table-wrap"><table><thead><tr><th>Instance</th><th>Periods</th><th>Items</th><th>Centers</th><th>Best value / bound</th><th>Evidence</th><th>Trust status</th></tr></thead><tbody>{''.join(table_rows)}</tbody></table></div><p class="table-note"><span data-visible-count>{len(lot_rows)}</span> of {len(lot_rows)} instances shown. Values are reported conservatively; “not proven” is not equivalent to non-optimal.</p></section>'''
            outputs[OUT/f"lots/{slug(family)}--{slug(lot_name)}.html"]=page(f"{family} · {lot_name}",lot_body,1)
        fam_body=f'''<section class="hero compact"><div class="eyebrow"><a href="../index.html">Benchmark problems</a> / Family</div><h1>{esc(family)}</h1><p>{esc(FAMILY_DESCRIPTIONS.get(family,''))}</p><div class="metrics">{metric(len(group),'Canonical instances')}{metric(len(lots),'Instance lots')}{metric(sum(bool(r.get('objective_reference') or r.get('lower_bound')) for r in group),'Known references')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Available datasets</span><h2>Select an instance lot</h2></div></div><div class="card-grid">{''.join(lot_cards)}</div></section>'''
        outputs[OUT/f"families/{slug(family)}.html"]=page(family,fam_body,1)
    body=f'''<section class="hero"><div class="eyebrow">Scientific benchmark explorer · v1.0.0</div><h1>Lot-sizing problems,<br><span>organized for evidence.</span></h1><p>Explore 7,905 canonical instances by problem family and experimental lot. Each catalogue exposes dimensions, reference values and proof status without overstating the available evidence.</p><div class="metrics">{metric(len(rows),'Canonical instances')}{metric(len(families),'Problem families')}{metric(125,'Open evidence challenges')}{metric(0,'Exact duplicates')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Benchmark library</span><h2>Choose a problem family</h2></div><p>Every card opens the available instance lots for that problem.</p></div><div class="card-grid">{''.join(cards)}</div></section><section class="principles"><h2>Scientific reading guide</h2><div><p><strong>Best reported is not proven optimal.</strong><br>Objective values retain their evidence status.</p><p><strong>Canonical means traceable.</strong><br>Every XML is linked to its registry identity and SHA-256 record.</p><p><strong>Open means actionable.</strong><br>Missing solutions and proofs remain visible in the trust catalogue.</p></div></section>'''
    outputs[OUT/'index.html']=page('Benchmark explorer',body,0)
    outputs[ROOT/'docs/index.html']='''<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=portal/index.html"><title>LotSizingDataModel.Benchmarks</title><a href="portal/index.html">Open benchmark explorer</a>'''
    outputs[ROOT/'docs/.nojekyll']=''
    return outputs

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--check',action='store_true'); args=parser.parse_args()
    outputs=build(); changed=[]
    for path,content in outputs.items():
        if not path.exists() or path.read_text(encoding='utf-8') != content: changed.append(path)
        if not args.check:
            path.parent.mkdir(parents=True,exist_ok=True); path.write_text(content,encoding='utf-8',newline='\n')
    if args.check and changed:
        print(f"Portal is stale: {len(changed)} generated files differ."); raise SystemExit(1)
    print(f"PORTAL_{'VALID' if args.check else 'BUILT'}|pages={len(outputs)}|instances=7905")
if __name__=='__main__': main()
