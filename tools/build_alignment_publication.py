"""Adapt validated DataModel fields to public URLs and current evidence; no classification rules."""
import argparse, csv, json
from pathlib import Path, PureWindowsPath

ROOT=Path(__file__).resolve().parents[1]
PAGES=ROOT/'docs/benchmarks/alignment-r2'
NAME='GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2'
REPO='https://github.com/Lemoine-OR/LotSizingDataModel.Benchmarks'
RAW='https://raw.githubusercontent.com/Lemoine-OR/LotSizingDataModel.Benchmarks/main'

def csv_rows(name):
    with (ROOT/'catalog/global'/name).open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))

def generate():
    rows=json.loads((ROOT/'catalog/global'/f'{NAME}.json').read_text(encoding='utf-8-sig'))
    baseline=json.loads((ROOT/'catalog/global/GLOBAL-BENCHMARK-REGISTRY-v1.0.0.json').read_text(encoding='utf-8-sig'))
    by_id={r['global_instance_id']:r for r in baseline}
    assert len(rows)==len(by_id)==7905
    assert len({r['global_instance_id'] for r in rows})==7905
    for r in rows:
        assert all(r[k]==v for k,v in by_id[r['global_instance_id']].items()),r['global_instance_id']
        assert r['DataModelVersion']=='1.3.0' and r['UniversalNotation'] and r['Lsi10Notation']
    trust={r['global_instance_id']:r for r in csv_rows('GLOBAL-NORMALIZED-TRUST-v1.0.0.csv')}
    challenges={}
    for c in csv_rows('GLOBAL-OPEN-CHALLENGES-v1.0.0.csv'):
        challenges.setdefault(c['global_instance_id'],[]).append(c['challenge_type']+': '+c['reason']+' Resolution: '+c['resolution_criterion'])
    data=[]
    for r in rows:
        evidence=trust.get(r['global_instance_id'],{})
        parts=PureWindowsPath(r['canonical_xml_path']).parts
        index=next(i for i,p in enumerate(parts) if p.lower()=='benchmarks')
        relative='/'.join(parts[index:])
        assert (ROOT/relative).is_file()
        data.append(dict(id=r['global_instance_id'],family=r['family'],legacy=r['LegacyFamily'],lsi=r['Lsi10Notation'],universal=r['UniversalNotation'],structure=r['ProductStructureDetected'],declared=r['ProductStructureDeclared'],capacity=r['CapacityProfile']['Regime'],setups=', '.join(k for k,v in r['SetupFeatures'].items() if v is True) or 'None detected',scheduling=json.dumps(r['SchedulingFeatures'],separators=(',',':')),status=evidence.get('normalized_trust_status') or r['trust_status'],challenge=' / '.join(challenges.get(r['global_instance_id'],[])),items=r['DetectedItemCount'],periods=r['DetectedPlanningHorizon'],objective=evidence.get('objective_reference') or r['objective_reference'],url=REPO+'/blob/main/'+relative,confidence=r['ClassificationConfidence'],warnings=r['ClassificationWarnings']))
    return 'window.ALIGNMENT_DATA='+json.dumps(data,ensure_ascii=False,separators=(',',':'))+';'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    expected=generate();target=PAGES/'data.js'
    if args.check:assert target.read_text(encoding='utf-8')==expected,'Public alignment data is stale'
    else:target.write_text(expected,encoding='utf-8',newline='\n')
    for page in PAGES.glob('*.html'):
        text=page.read_text(encoding='utf-8')
        for ext in ('json','csv'):
            old=f'../../../catalog/global/{NAME}.{ext}'
            new=f'{RAW}/catalog/global/{NAME}.{ext}'
            if args.check:assert old not in text and new in text,page.name
            else:text=text.replace(old,new)
        if not args.check:page.write_text(text,encoding='utf-8',newline='\n')
    print('PUBLIC_ALIGNMENT_VALID|7905|ORIGINAL_REGISTRY_FIELDS_PRESERVED')

if __name__=='__main__':main()
