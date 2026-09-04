/* This viewer groups DataModel-produced fields; it performs no classification. */
const views={family:'Bibliographic family',legacy:'Legacy family',lsi:'LSI 1.0',structure:'Product structure',capacity:'Capacity',setups:'Setups',scheduling:'Scheduling',status:'Status',challenge:'Open challenges'};
const view=document.body.dataset.view;
const source=window.ALIGNMENT_DATA.filter(r=>view!=='challenge'||r.challenge);
const nav=document.getElementById('nav');
for(const [key,label] of Object.entries(views)){const a=document.createElement('a');a.href=key+'.html';a.textContent=label;if(key===view)a.setAttribute('aria-current','page');nav.append(a);}
const group=document.getElementById('group');
const counts=new Map();for(const row of source){const key=row[view]||'Unknown';counts.set(key,(counts.get(key)||0)+1);}
for(const [key,count] of [...counts].sort((a,b)=>a[0].localeCompare(b[0]))){const option=document.createElement('option');option.value=key;option.textContent=key+' ('+count+')';group.append(option);}
let page=0;
function render(){
 const query=document.getElementById('search').value.toLowerCase();
 const filtered=source.filter(r=>(!group.value||(r[view]||'Unknown')===group.value)&&(!query||JSON.stringify(r).toLowerCase().includes(query)));
 const total=Math.max(1,Math.ceil(filtered.length/50));page=Math.min(page,total-1);
 const body=document.getElementById('rows');body.replaceChildren();
 for(const r of filtered.slice(page*50,(page+1)*50)){
  const tr=document.createElement('tr');const first=document.createElement('td');const a=document.createElement('a');a.href=r.url;a.textContent=r.id;first.append(a);tr.append(first);
  for(const text of [r.family+' / '+r.legacy,r.structure+' / '+r.capacity,r.items+' items · '+r.periods+' periods',r.status+' / '+(r.objective||'Unknown')]){const td=document.createElement('td');td.textContent=text;tr.append(td);}
  const td=document.createElement('td');td.className='notation-cell';
  for(const [label,text] of [['Universal',r.universal],['LSI 1.0',r.lsi]]){const strong=document.createElement('strong');strong.textContent=label;const code=document.createElement('code');code.textContent=text;td.append(strong,code);}
  const details=document.createElement('details');const summary=document.createElement('summary');summary.textContent='Features and challenges';details.append(summary);
  for(const text of ['Setups: '+r.setups,'Scheduling: '+r.scheduling,r.challenge]){if(text){const p=document.createElement('p');p.textContent=text;details.append(p);}}td.append(details);tr.append(td);body.append(tr);
 }
 document.getElementById('summary').textContent=filtered.length.toLocaleString()+' matching instances';document.getElementById('pagination').textContent=' Page '+(page+1)+' / '+total+' ';
 document.getElementById('previous').disabled=page===0;document.getElementById('next').disabled=page===total-1;
}
document.getElementById('search').addEventListener('input',()=>{page=0;render();});group.addEventListener('change',()=>{page=0;render();});document.getElementById('previous').addEventListener('click',()=>{page--;render();});document.getElementById('next').addEventListener('click',()=>{page++;render();});render();
