import asyncio, io
from playwright.async_api import async_playwright
from PIL import Image

HTML = r"""
<html><body style="margin:0;width:960px;height:540px;background:#0f172a;font-family:Arial,Helvetica,sans-serif;color:#e2e8f0;overflow:hidden">
<style>
.t{position:absolute;left:40px;top:24px;font-size:30px;font-weight:bold}
.s{position:absolute;left:40px;top:66px;font-size:17px;color:#94a3b8}
.box{position:absolute;border-radius:12px;padding:10px 14px;font-size:16px;opacity:0;transition:none;box-sizing:border-box}
.on{opacity:1}
.done{background:#14532d;border:2px solid #22c55e}
.wip{background:#713f12;border:2px solid #f59e0b}
.next{background:#1e293b;border:2px solid #64748b}
.blue{background:#1e3a8a;border:2px solid #60a5fa}
.pur{background:#4c1d95;border:2px solid #a78bfa}
.arr{position:absolute;font-size:28px;color:#fbbf24;opacity:0}
.cap{position:absolute;left:40px;bottom:22px;right:40px;font-size:19px;color:#fde68a;opacity:0}
b{color:#fff}
</style>
<div id="root"></div>
</body></html>
"""

def box(x,y,w,h,cls,text,i,size=16):
    return f'<div class="box {cls}" data-i="{i}" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;font-size:{size}px">{text}</div>'
def arr(x,y,t,i):
    return f'<div class="arr" data-i="{i}" style="left:{x}px;top:{y}px">{t}</div>'
def cap(t,i):
    return f'<div class="cap" data-i="{i}">{t}</div>'

scenes=[]
# Scene 1: roadmap
s=['<div class="t">SplitEasy roadmap</div><div class="s">green = built &amp; tested in CI · amber = in progress · grey = next</div>']
items=[("Stage 1","Contact picker<br>for Add Member","done"),("Stage 2a","Record IDs, times,<br>merge rules","done"),("Stage 2b","Delete markers,<br>offline queue","done"),
("Stage 3a","Settlement upgrade:<br>methods, statuses","next"),("Stage 3","Sign-in done; sharing<br>+ invites in test","wip"),("Stage 3c","Pay from app:<br>GPay/PhonePe/UPI ID","next"),
("Stage 4","Share screenshot,<br>paste SMS, auto-read","next"),("Stage 5","UPI app diagnostics,<br>parser tuning","next"),("Stage 6","Proof image sync,<br>device checklist","next")]
for k,(a,b_,c) in enumerate(items):
    x=40+(k%3)*295; y=110+(k//3)*125
    s.append(box(x,y,270,105,c,f"<b>{a}</b><br>{b_}",k+1,18))
s.append(cap("One stage at a time. Each stage: branch → CI build → you test → you say 'merge'.",10))
scenes.append(s)

# Scene 2: sync architecture
s=['<div class="t">How sync will work (Stage 3)</div><div class="s">Your phone is the source of truth. Firebase is only a small relay.</div>']
s.append(box(40,170,240,150,'blue',"<b>Phone A</b><br>SQLite database<br>(all records)<br>+ outbox queue",1,17))
s.append(box(360,170,240,150,'pur',"<b>Firebase relay</b><br>Auth + Firestore<br>(free tier)<br>invites, copies",3,17))
s.append(box(680,170,240,150,'blue',"<b>Phone B</b><br>SQLite database<br>(all records)<br>+ outbox queue",5,17))
s.append(arr(292,225,"⇄",2)); s.append(arr(612,225,"⇄",4))
s.append(box(40,350,880,60,'next',"Offline? Changes wait in the outbox, then go out when internet returns. Same change twice = applied once.",6,17))
s.append(box(40,420,880,60,'done',"Both phones apply the merge rules (newest wins; tie → delete, then higher device id) → same balances everywhere.",7,17))
s.append(cap("No server for you to run. Balances are always recomputed from raw records on each phone.",8))
scenes.append(s)

# Scene 3: payment proof
s=['<div class="t">Payment proof flow</div><div class="s">A screenshot or UTR alone never makes a payment "verified"</div>']
st=[("1. Pending","Settle-up shows who owes whom",'next'),("2. Pay","UPI app or cash/bank",'blue'),("3. Share proof","Screenshot / SMS → OCR reads amount, UTR",'blue'),
("4. Matched","Matched to the pending payment: <b>recorded</b>, counts in balance",'wip'),("5. Verified","Receiver confirms, or both sides show same UTR",'done')]
for k,(a,b_,c) in enumerate(st):
    s.append(box(40+k*180,170,165,170,c,f"<b>{a}</b><br><br>{b_}",k+1,16))
s.append(box(40,370,880,60,'next',"Duplicates blocked: same UTR or same image fingerprint is refused. Disputed payments are excluded from balances.",6,17))
s.append(cap("Rule: no auto-verify. SMS auto-read only in the direct APK, never the Play build.",7))
scenes.append(s)

# Scene 4: how to add a feature
s=['<div class="t">Adding a new feature: where things go</div><div class="s">Follow this order and CI will tell you if anything breaks</div>']
st=[("lib/logic/","Pure Dart rules (money, parsing, merge). No Flutter imports.",'done'),("test/","Add tests first: logic_test, merge_test, contact_utils_test",'done'),
("lib/data/repo.dart","DB changes: bump schema, set updated_at, call _bump()",'blue'),("lib/ui/","Screens only. Money as integer paise via parseMoney",'blue'),
("docs/DEV_GUIDE.md","Update status table + decisions",'pur'),("GitHub Actions","analyze → tests → signed APK + AAB",'wip')]
for k,(a,b_,c) in enumerate(st):
    s.append(box(40+(k%3)*295,115+(k//3)*150,270,130,c,f"<b>{a}</b><br><br>{b_}",k+1,16))
s.append(box(40,420,880,50,'next',"Never: hard-delete members (archive), skip _bump(), store money as decimals, mark verified automatically.",7,16))
s.append(cap("Give the agent: 'Read docs/DEV_GUIDE.md, then do Stage X only.'",8))
scenes.append(s)

async def main():
    frames=[]; durs=[]
    async with async_playwright() as p:
        b=await p.chromium.launch(); pg=await b.new_page(viewport={'width':960,'height':540})
        await pg.set_content(HTML)
        for sc in scenes:
            await pg.evaluate("h=>document.getElementById('root').innerHTML=h","".join(sc))
            n=max(int(e.split('data-i="')[1].split('"')[0]) for x in sc for e in [x] if 'data-i' in x)
            for i in range(0,n+1):
                await pg.evaluate("i=>document.querySelectorAll('[data-i]').forEach(e=>{e.style.opacity=(+e.dataset.i<=i)?1:0})",i)
                img=Image.open(io.BytesIO(await pg.screenshot())).convert('P',palette=Image.ADAPTIVE)
                frames.append(img); durs.append(1400 if i<n else 3500)
        await b.close()
    frames[0].save('docs/blueprint/splitEasy_blueprint.gif',save_all=True,append_images=frames[1:],duration=durs,loop=0,optimize=True)
    print(len(frames))
asyncio.run(main())
