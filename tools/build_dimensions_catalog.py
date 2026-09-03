#!/usr/bin/env python3
"""Extract lightweight dimensional metadata from canonical XML instances."""
from pathlib import Path, PureWindowsPath
import csv, xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
REGISTRY=ROOT/'catalog/global/GLOBAL-BENCHMARK-REGISTRY-v1.0.0.csv'
OUTPUT=ROOT/'docs/portal/data/instance-dimensions-v1.0.0.csv'

def local(tag): return tag.rsplit('}',1)[-1]
def relative_path(value):
    parts=PureWindowsPath(value).parts
    index=next(i for i,p in enumerate(parts) if p.lower()=='benchmarks' and i>0)
    return ROOT.joinpath(*parts[index:])

with REGISTRY.open(encoding='utf-8-sig',newline='') as stream:
    registry=list(csv.DictReader(stream))
OUTPUT.parent.mkdir(parents=True,exist_ok=True)
with OUTPUT.open('w',encoding='utf-8',newline='') as stream:
    writer=csv.DictWriter(stream,fieldnames=['global_instance_id','planning_horizon','item_count','work_center_count'])
    writer.writeheader()
    for index,row in enumerate(registry,1):
        horizon=''; items=0; centers=0
        for _,element in ET.iterparse(relative_path(row['canonical_xml_path']),events=('start',)):
            name=local(element.tag)
            if name=='supplyChain': horizon=element.attrib.get('planningHorizon','')
            elif name=='item': items+=1
            elif name=='workCenter' and 'id' in element.attrib: centers+=1
        writer.writerow({'global_instance_id':row['global_instance_id'],'planning_horizon':horizon,'item_count':items,'work_center_count':centers})
        if index%500==0: print(f'PROGRESS|{index}|{len(registry)}')
print(f'DIMENSIONS_BUILT|{len(registry)}')
