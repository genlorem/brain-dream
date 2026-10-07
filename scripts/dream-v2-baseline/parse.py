import re,glob,json,os
out=[]
for f in sorted(glob.glob(os.path.expanduser('~/brain/dreams/dream-2026-*.md'))):
    d=re.search(r'(\d{4}-\d\d-\d\d)',f).group(1)
    if not ('2026-09-01'<=d<='2026-10-07'): continue
    t=open(f).read()
    i=t.find('## Синтез'); 
    if i<0: continue
    s=t[i:]
    j=re.search(r'\n## (Mermaid|Статистика)',s); s=s[:j.start()] if j else s
    items=[]
    rows=re.findall(r'^\|\s*(\d+)\s*\|(.+)$',s,re.M)
    if rows:
        for n,r in rows:
            c=[x.strip() for x in r.split('|')]
            items.append(dict(n=int(n),title=c[0],body=c[1],action=c[3] if len(c)>3 else '',src=c[4] if len(c)>4 else ''))
    else:
        parts=re.split(r'^(?:#{2,3} |\*\*)(\d+)\.\s*',s,flags=re.M)
        for k in range(1,len(parts),2):
            n=int(parts[k]); blk=parts[k+1]
            lines=blk.split('\n'); title=lines[0].strip().strip('*').strip()
            body='\n'.join(lines[1:])
            m=re.search(r'\*\*Суть:\*\*\s*(.+)',body); summ=m.group(1) if m else next((l for l in lines[1:] if l.strip() and not l.startswith('**')),'')
            a=re.search(r'(?:\*\*)?Действие:(?:\*\*)?\s*(.+)',body)
            sr=re.search(r'(?:Источники:\*?\*?)(.+)',body)
            items.append(dict(n=n,title=title,body=summ.strip(),action=a.group(1).strip() if a else '',src=(sr.group(1) if sr else ' '.join(re.findall(r'`([a-z]+:[^`]+)`',body)))))
    items=[x for x in items if 1<=x['n']<=10][:10]
    for x in items: x['date']=d; x['id']=f"{d}#{x['n']}"; out.append(x)
json.dump(out,open('ins.json','w'),ensure_ascii=False,indent=0)
from collections import Counter
c=Counter(x['date'] for x in out); print(len(c),len(out)); print(c)
print(sum(1 for x in out if not x['action']), sum(1 for x in out if not x['body']))
