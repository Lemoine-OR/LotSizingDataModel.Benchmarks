#!/usr/bin/env python3
"""Build the static GitHub Pages benchmark explorer from the v1 registry."""
from __future__ import annotations
import argparse, csv, html, re, json
from collections import defaultdict, Counter
from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "catalog/global/GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv"
TRUST = ROOT / "catalog/global/GLOBAL-NORMALIZED-TRUST-v1.0.0.csv"
DIMENSIONS = ROOT / "docs/portal/data/instance-dimensions-v1.0.0.csv"
ALIGNMENT = ROOT / "catalog/global/GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.json"
OUT = ROOT / "docs/portal"
REPO = "https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks"
DJ_SOLUTIONS = ROOT / "benchmarks/DJ2000/Phase1/solutions"
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
    with ALIGNMENT.open(encoding="utf-8-sig") as stream:
        alignment={r["global_instance_id"]:r for r in json.load(stream)}
    with REGISTRY.open(encoding="utf-8-sig", newline="") as stream:
        rows=list(csv.DictReader(stream))
    with TRUST.open(encoding="utf-8-sig", newline="") as stream:
        trust={r["global_instance_id"]:r for r in csv.DictReader(stream)}
    with DIMENSIONS.open(encoding="utf-8-sig", newline="") as stream:
        dimensions={r["global_instance_id"]:r for r in csv.DictReader(stream)}
    for row in rows:
        semantic=alignment[row["global_instance_id"]]
        row["UniversalNotation"]=semantic["UniversalNotation"]
        row["Lsi10Notation"]=semantic["Lsi10Notation"]
        evidence=trust.get(row["global_instance_id"],{})
        for key in ("normalized_trust_status","objective_reference","lower_bound","complete_solution_available","checker_verified_solution","optimality_status","literature_source"):
            if evidence.get(key) != "": row[key]=evidence.get(key,"")
        row["trust_status"]=evidence.get("normalized_trust_status",row.get("trust_status", ""))
        dim=dimensions.get(row["global_instance_id"],{})
        row["planning_horizon"]=dim.get("planning_horizon") or row.get("planning_horizon","")
        row["item_count"]=dim.get("item_count") or row.get("item_count","")
        row["work_center_count"]=dim.get("work_center_count") or row.get("work_center_count","")
    return rows

def notation_cell(row):
    return f'<td class="notation-cell"><span>Universal</span><code>{esc(row["UniversalNotation"])}</code><span>LSI 1.0</span><code>{esc(row["Lsi10Notation"])}</code></td>'
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
def yes(value): return str(value).strip().lower() in {"true","1","yes"}
def solution_record(row):
    if published_solution(row): return "Download verified XML", "ok"
    if yes(row.get("checker_verified_solution")): return "Verified; file unavailable", "feasible"
    if yes(row.get("complete_solution_available")): return "Recorded; file unavailable", "open"
    return "Unavailable", "neutral"
def published_solution(row):
    if row.get("family") != "DJ2000" or row.get("subfamily") != "Phase1": return None
    matches=sorted(DJ_SOLUTIONS.glob(f"{row['original_instance_id']}.solver-*.solution.xml"))
    return matches[0] if len(matches) == 1 else None
def solution_cell(row, text, kind):
    path=published_solution(row)
    if not path: return badge(text,kind)
    link=f"{REPO}/blob/main/{path.relative_to(ROOT).as_posix()}"
    return f'<a class="solution-link" href="{link}">{badge(text,kind)}</a>'
def gap(row):
    try:
        incumbent=float(row.get("objective_reference") or "")
        bound=float(row.get("lower_bound") or "")
        if incumbent == 0: return "0%" if bound == 0 else "—"
        return f"{max(0,(incumbent-bound)/abs(incumbent))*100:.3f}%"
    except ValueError: return "—"
def page(title, body, depth=0):
    prefix="../"*depth
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Lot-sizing benchmark explorer"><title>{esc(title)} · LotSizingDataModel.Benchmarks</title><link rel="stylesheet" href="{prefix}assets/styles.css"><link rel="stylesheet" href="{prefix}assets/results.css"></head><body><header class="site-header"><a class="brand" href="{prefix}index.html"><span class="brand-mark">LS</span><span>LotSizingDataModel<span class="muted">.Benchmarks</span></span></a><nav><a href="{prefix}index.html">Problems</a><a href="{prefix}results.html">Known results</a><a href="{prefix}../benchmarks/alignment-r2/index.html">Scientific notation</a><a href="{REPO}">GitHub</a><a href="{REPO}/releases/tag/v1.0.0">Release v1.0.0</a></nav></header><main>{body}</main><footer>Curated, traceable and reproducible lot-sizing research benchmarks · v1.0.0 · DataModel 1.3.0 R2</footer><script src="{prefix}assets/app.js"></script></body></html>'''
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
            solutions=sum(yes(r.get('complete_solution_available')) for r in lot_rows)
            proven=sum(proof(r)[1]=='ok' for r in lot_rows)
            lot_cards.append(f'''<a class="card lot-card" href="{target}"><div class="card-kicker">Instance lot</div><h2>{esc(lot_name)}</h2><div class="card-stats"><span>{len(lot_rows):,} instances</span><span>{refs:,} known values</span></div><p>Horizons: {esc(', '.join(horizons[:6]) or 'not recorded')}<br>Items: {esc(', '.join(items[:6]) or 'not recorded')}</p><div class="evidence-strip"><span>{solutions} solutions recorded</span><span>{proven} proven optimal</span></div></a>''')
            table_rows=[]
            for r in sorted(lot_rows,key=lambda x:x['original_instance_id'].lower()):
                value,value_kind=best_value(r); proof_text,proof_kind=proof(r); solution_text,solution_kind=solution_record(r); path=repo_path(r['canonical_xml_path'])
                link=f"{REPO}/blob/v1.0.0/{path}"
                source=r.get('literature_source') or 'Not documented'
                search=' '.join([r['original_instance_id'],r.get('trust_status',''),value,proof_text,solution_text,source,r['UniversalNotation'],r['Lsi10Notation']]).lower()
                has_result='true' if r.get('objective_reference') or r.get('lower_bound') else 'false'
                is_proven='true' if proof_kind == 'ok' else 'false'
                table_rows.append(f'''<tr data-search="{esc(search)}" data-result="{has_result}" data-proven="{is_proven}"><td><a href="{link}">{esc(r['original_instance_id'])}</a></td>{notation_cell(r)}<td>{esc(r.get('planning_horizon') or '—')}</td><td>{esc(r.get('item_count') or '—')}</td><td>{esc(r.get('work_center_count') or '—')}</td><td>{esc(r.get('objective_reference') or '—')}</td><td>{esc(r.get('lower_bound') or '—')}</td><td>{esc(gap(r))}</td><td>{badge(proof_text,proof_kind)}</td><td>{solution_cell(r,solution_text,solution_kind)}</td><td>{esc(source)}</td></tr>''')
            lot_body=f'''<section class="hero compact"><div class="eyebrow"><a href="../families/{slug(family)}.html">{esc(family)}</a> / Instance lot</div><h1>{esc(lot_name)}</h1><p>Best-known values, bounds, solution availability and proof status for every canonical instance.</p><div class="metrics">{metric(len(lot_rows),'Instances')}{metric(refs,'Known values / bounds')}{metric(solutions,'Solutions recorded')}{metric(proven,'Proven optimal')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Results and solutions</span><h2>Instance results table</h2></div><label class="search">Search<input type="search" data-table-filter placeholder="ID, notation, status or value"></label></div><div class="filter-bar"><button class="active" data-result-filter="all">All instances</button><button data-result-filter="known">Known values only</button><button data-result-filter="proven">Proven optimal only</button></div><div class="table-wrap"><table><thead><tr><th>Instance</th><th>Notation · Universal / LSI</th><th>Periods</th><th>Items</th><th>Centers</th><th>Best-known objective</th><th>Lower bound</th><th>Gap</th><th>Optimality</th><th>Solution file</th><th>Source</th></tr></thead><tbody>{''.join(table_rows)}</tbody></table></div><p class="table-note"><span data-visible-count>{len(lot_rows)}</span> of {len(lot_rows)} instances shown. “Not proven” means that no proof is preserved here; it does not assert that the value is non-optimal. Published solution files contain the complete decision vector and checker evaluation.</p></section>'''
            outputs[OUT/f"lots/{slug(family)}--{slug(lot_name)}.html"]=page(f"{family} · {lot_name}",lot_body,1)
        fam_body=f'''<section class="hero compact"><div class="eyebrow"><a href="../index.html">Benchmark problems</a> / Family</div><h1>{esc(family)}</h1><p>{esc(FAMILY_DESCRIPTIONS.get(family,''))}</p><div class="metrics">{metric(len(group),'Canonical instances')}{metric(len(lots),'Instance lots')}{metric(sum(bool(r.get('objective_reference') or r.get('lower_bound')) for r in group),'Known references')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Available datasets</span><h2>Select an instance lot</h2></div></div><div class="card-grid">{''.join(lot_cards)}</div></section>'''
        outputs[OUT/f"families/{slug(family)}.html"]=page(family,fam_body,1)
    result_rows=[r for r in rows if r.get('objective_reference') or r.get('lower_bound') or yes(r.get('complete_solution_available'))]
    global_rows=[]
    for r in sorted(result_rows,key=lambda x:(x['family'],x.get('subfamily',''),x['original_instance_id'].lower())):
        proof_text,proof_kind=proof(r); solution_text,solution_kind=solution_record(r)
        lot_link=f"lots/{slug(r['family'])}--{slug(r.get('subfamily','') or 'Canonical collection')}.html"
        search=' '.join([r['family'],r.get('subfamily',''),r['original_instance_id'],r.get('objective_reference',''),r.get('lower_bound',''),proof_text,r['UniversalNotation'],r['Lsi10Notation']]).lower()
        global_rows.append(f'''<tr data-search="{esc(search)}" data-result="{'true' if r.get('objective_reference') or r.get('lower_bound') else 'false'}" data-proven="{'true' if proof_kind=='ok' else 'false'}"><td>{esc(r['family'])}</td><td><a href="{lot_link}">{esc(r.get('subfamily') or 'Canonical collection')}</a></td><td>{esc(r['original_instance_id'])}</td>{notation_cell(r)}<td>{esc(r.get('objective_reference') or '—')}</td><td>{esc(r.get('lower_bound') or '—')}</td><td>{badge(proof_text,proof_kind)}</td><td>{solution_cell(r,solution_text,solution_kind)}</td></tr>''')
    results_body=f'''<section class="hero compact"><div class="eyebrow">Scientific evidence catalogue</div><h1>Known results &amp; solutions</h1><p>One consolidated view of every instance for which an objective, lower bound or solution evidence record is currently available.</p><div class="metrics">{metric(len(result_rows),'Evidence records')}{metric(sum(bool(r.get('objective_reference')) for r in rows),'Best-known objectives')}{metric(sum(bool(r.get('lower_bound')) for r in rows),'Lower bounds')}{metric(sum(proof(r)[1]=='ok' for r in rows),'Proven optimal')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Cross-family results</span><h2>Search all known evidence</h2></div><label class="search">Search<input type="search" data-table-filter placeholder="Family, ID, notation or value"></label></div><div class="filter-bar"><button class="active" data-result-filter="all">All evidence</button><button data-result-filter="known">Values / bounds</button><button data-result-filter="proven">Proven optimal</button></div><div class="table-wrap"><table><thead><tr><th>Family</th><th>Instance lot</th><th>Instance</th><th>Notation · Universal / LSI</th><th>Best-known objective</th><th>Lower bound</th><th>Optimality</th><th>Solution file</th></tr></thead><tbody>{''.join(global_rows)}</tbody></table></div><p class="table-note"><span data-visible-count>{len(result_rows)}</span> of {len(result_rows)} evidence records shown. Empty fields are explicit research gaps, never inferred values.</p></section>'''
    outputs[OUT/'results.html']=page('Known results and solutions',results_body,0)
    body=f'''<section class="hero"><div class="eyebrow">Scientific benchmark explorer · v1.0.0</div><h1>Lot-sizing problems,<br><span>organized for evidence.</span></h1><p>Explore 7,905 canonical instances by problem family and experimental lot. Each catalogue exposes dimensions, reference values and proof status without overstating the available evidence.</p><div class="hero-actions"><a class="primary-action" href="results.html">View known results &amp; solutions</a></div><div class="metrics">{metric(len(rows),'Canonical instances')}{metric(len(families),'Problem families')}{metric(125,'Open evidence challenges')}{metric(0,'Exact duplicates')}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Benchmark library</span><h2>Choose a problem family</h2></div><p>Every card opens the available instance lots and their result tables.</p></div><div class="card-grid">{''.join(cards)}</div></section><section class="principles"><h2>Scientific reading guide</h2><div><p><strong>Best reported is not proven optimal.</strong><br>Objective values retain their evidence status.</p><p><strong>Canonical means traceable.</strong><br>Every XML is linked to its registry identity and SHA-256 record.</p><p><strong>Open means actionable.</strong><br>Missing solutions and proofs remain visible in the trust catalogue.</p></div></section>'''
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
