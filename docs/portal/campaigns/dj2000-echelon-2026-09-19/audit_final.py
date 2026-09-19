"""Reopen the FINAL saved solution and original XML independently of the model runner."""
from pathlib import Path
from fractions import Fraction as F
import xml.etree.ElementTree as E
import json,hashlib,time
root=Path(__file__).resolve().parent
import argparse
parser=argparse.ArgumentParser()
parser.add_argument('--repository', type=Path, default=root.parents[3])
repository=parser.parse_args().repository
report=[]
for m in json.loads((root/'manifest.json').read_text()):
 folder=root/'results'/m['name'];solution=folder/'solution-exact.json'
 if not (folder/'verified.json').exists():continue
 xml=repository/m['source'];assert hashlib.sha256(xml.read_bytes()).hexdigest()==m['sha256']
 chain=E.parse(xml).getroot().find('supplyChain');n=int(chain.attrib['planningHorizon'])
 data=json.loads(solution.read_text());candidate=json.loads((folder/'candidate.json').read_text());v=json.loads((folder/'verified.json').read_text())
 ids={int(x.attrib['id']) for x in chain.find('items')}
 decisions={(d['item'],d['period']):d for d in data['decisions']};assert len(decisions)==len(data['decisions'])==len(ids)*n
 pc={int(x.attrib['itemId']):x for x in chain.find('productionCharacteristics')}
 iv={int(x.attrib['itemId']):x for x in chain.find('inventories')}
 edges=[(int(x.attrib['parentItemId']),int(x.attrib['componentItemId']),F(x.attrib['quantity'])) for x in chain.find('componentRequirements')]
 total=F(0)
 for i in ids:
  previous=F(iv[i].attrib['initialInventory'])
  for t in range(1,n+1):
   d=decisions[i,t];assert type(d['setup']) is int and d['setup'] in (0,1)
   q=F(d['production']);stock=F(d['inventory']);assert q>=0 and stock>=0
   if d['setup']==0:assert q==0
   external=sum((F(x.findall('quantities')[t-1].text) for x in chain.find('demands') if int(x.attrib['itemId'])==i),F(0))
   consumption=sum((r*F(decisions[j,t]['production']) for j,k,r in edges if k==i),F(0))
   assert previous+q-stock==external+consumption
   assert F(d['echelonInventory'])==stock+sum((r*F(decisions[j,t]['echelonInventory']) for j,k,r in edges if k==i),F(0))
   total+=F(pc[i].findall('fixedSetupCost/values')[t-1].text)*d['setup']+F(pc[i].findall('unitUsageCost/values')[t-1].text)*q+F(iv[i].findall('unitUsageCost/values')[t-1].text)*stock
   previous=stock
 assert total==F(data['objectiveExact'])
 assert abs(total-F(data['objectiveDecimal']))<=F('1e-40') and abs(total-F(v['objective']))<=F('1e-40')
 bound=F(str(candidate['bound']));assert candidate['status']=='Optimal'
 assert abs(total-bound)<=F('0.00001') and abs(abs(total-bound)-F(v['absoluteGap']))<=F('1e-40')
 assert data['status']=='OPTIMAL_WITHIN_ABSOLUTE_GAP' and data['sourceSha256']==m['sha256']
 exported=folder/'solution.xml';x=E.parse(exported).getroot();evaluation=x.find('evaluation')
 assert evaluation.attrib['optimalityStatus']=='provenOptimal' and evaluation.attrib['feasibilityStatus']=='feasible'
 assert abs(F(evaluation.findtext('objectiveValue'))-total)<=F('0.00001')
 assert F(evaluation.findtext('absoluteGap'))<=F('0.00001')
 assert abs(F(evaluation.findtext('bestBound'))-bound)<=F('1e-12')
 routes={int(r.attrib['id']):int(r.attrib['itemId']) for r in chain.find('productionRoutings')}
 assert len(x.find('productionDecisions'))==len(ids)
 for p in x.find('productionDecisions'):
  i=routes[int(p.attrib['routingId'])];qs=p.findall('quantities');ys=p.findall('setups');assert len(qs)==len(ys)==n
  for t,(q,y) in enumerate(zip(qs,ys),1):
   assert F(y.text) in (0,1) and F(y.text)==decisions[i,t]['setup']
   assert F(q.text)==F(decisions[i,t]['production'])
 assert len(x.find('inventoryDecisions'))==len(ids)
 for inv in x.find('inventoryDecisions'):
  i=int(inv.attrib['itemId']);levels=inv.findall('levels');assert len(levels)==n
  for t,level in enumerate(levels,1):assert F(level.text)==F(decisions[i,t]['inventory'])
 report.append(dict(name=m['name'],phase=m['phase'],finalFileSha256=hashlib.sha256(solution.read_bytes()).hexdigest(),canonicalXmlSha256=hashlib.sha256(exported.read_bytes()).hexdigest(),canonicalXmlOptimalityPreserved=True,binaryExact=True,originalXmlBalancesExact=True,originalXmlCostExact=True,finalOptimalityGapPassed=True))
result=dict(verifiedFinalFiles=len(report),expected=136,complete=len(report)==136,checks=report)
assert result == json.loads((root/'final-file-audit.json').read_text()), 'Final evidence differs from archived audit'
assert result['complete']
print('FINAL_FILE_AUDIT',len(report),'/ 136')
