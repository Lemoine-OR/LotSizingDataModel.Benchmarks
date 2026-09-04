"""Check the visible notation cells in all generated instance tables."""
import json
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
class Cells(HTMLParser):
    def __init__(self):
        super().__init__();self.inside=False;self.code=False;self.values=[];self.text='';self.cells=[]
    def handle_starttag(self,tag,attrs):
        if tag=='td' and 'notation-cell' in dict(attrs).get('class','').split():self.inside=True;self.values=[]
        if self.inside and tag=='code':self.code=True;self.text=''
    def handle_data(self,data):
        if self.code:self.text+=data
    def handle_endtag(self,tag):
        if tag=='code' and self.code:self.values.append(self.text);self.code=False
        if tag=='td' and self.inside:
            assert len(self.values)==2,'Each instance needs both visible notations'
            self.cells.append(tuple(self.values));self.inside=False

rows=json.loads((ROOT/'catalog/global/GLOBAL-BENCHMARK-REGISTRY-DATAMODEL-1.3.0-R2.json').read_text(encoding='utf-8-sig'))
expected=Counter((r['UniversalNotation'],r['Lsi10Notation']) for r in rows)
actual=Counter()
for path in (ROOT/'docs/portal/lots').glob('*.html'):
    parser=Cells();parser.feed(path.read_text(encoding='utf-8'));assert parser.cells,path
    actual.update(parser.cells)
assert actual==expected,'Published instance notations differ from DataModel registry'
parser=Cells();parser.feed((ROOT/'docs/portal/results.html').read_text(encoding='utf-8'))
assert parser.cells and all(pair in expected for pair in parser.cells)
print(f'VISIBLE_INSTANCE_NOTATION|{sum(actual.values())}|PASS')
print(f'VISIBLE_KNOWN_RESULT_NOTATION|{len(parser.cells)}|PASS')
