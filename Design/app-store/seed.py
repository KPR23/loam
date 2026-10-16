import json, uuid, datetime, subprocess, sys
from zoneinfo import ZoneInfo
TZ = ZoneInfo("Europe/Warsaw")
REF = datetime.datetime(2001,1,1,tzinfo=datetime.timezone.utc)
def ts(y,m,d,h=0,mi=0): return (datetime.datetime(y,m,d,h,mi,tzinfo=TZ)-REF).total_seconds()
def U(): return str(uuid.uuid4()).upper()
ME   = "6A1C2B3D-1111-4A4A-9F00-000000000001"
OLA  = "6A1C2B3D-2222-4A4A-9F00-000000000002"
KUBA = "6A1C2B3D-3333-4A4A-9F00-000000000003"
MARTA= "6A1C2B3D-4444-4A4A-9F00-000000000004"
NAMES = {OLA:"Ola", KUBA:"Kuba", MARTA:"Marta"}
expenses, activity, repayments = [], [], []
def share(uid, amt, status="accepted"): return {"id":U(),"userId":uid,"amountMinor":amt,"status":status,"acceptedViaTrust":False}
def exp(day, amt, cat, title=None, paid=ME, created=None, shares=None, note=None, h=12):
    y,m,d = day
    e = {"id":U(),"amountMinor":amt,"currency":"PLN","category":cat,"spentAt":ts(y,m,d),
         "paidBy":paid,"createdBy":created or paid,"version":1,
         "shares": shares or [share(paid, amt)],
         "createdAt":ts(y,m,d,h),"updatedAt":ts(y,m,d,h)}
    if title: e["title"]=title
    if note: e["note"]=note
    expenses.append(e); return e
def even(total, people, paid, pending=()):
    n=len(people); base=total//n; rem=total-base*n
    return [share(p, base+(1 if i<rem else 0), "pending" if p in pending else "accepted") for i,p in enumerate(people)]
def event(kind, actor, when, e=None, recips=(), share_amt=0, rep=None, title="", cat="other", total=0):
    ev = {"id":U(),"occurredAt":when,"kind":kind,"actorId":actor,"actorName":NAMES.get(actor,"You"),
          "recipientNames":[NAMES.get(r,"You") for r in recips],"recipientIds":list(recips),
          "expenseTitle": (e.get("title") if e else title) or title, "category": e["category"] if e else cat,
          "affectedShareMinor":share_amt,"expenseTotalMinor": e["amountMinor"] if e else total,"currency":"PLN"}
    if recips: ev["recipientId"]=recips[0]; ev["recipientName"]=NAMES.get(recips[0],"You")
    if e: ev["expenseId"]=e["id"]
    if rep: ev["repaymentId"]=rep
    activity.append({"event":ev,"audience":[ME]+[a for a in [actor,*recips] if a!=ME],"readBy":[]})

O=(2026,10)
# --- October (current month)
rent = exp((*O,1), 420000, "housing", "Rent", shares=even(420000,[ME,OLA],ME), note="October, Mokotów flat", h=9)
power = exp((*O,1), 28900, "utilities", "Internet & power", paid=OLA, shares=even(28900,[ME,OLA],OLA), h=18)
exp((*O,1), 11000, "transport", "Monthly metro pass", h=8)
exp((*O,2), 18640, "groceries", "Weekly shop", h=19)
exp((*O,2), 44900, "shopping", "Running shoes", h=15)
exp((*O,2), 3490, "transport", "Uber home", h=23)
dinner = exp((*O,3), 31200, "dining", "Dinner at Bibenda", shares=even(31200,[ME,OLA,KUBA],ME), h=21)
cinema = exp((*O,3), 6400, "entertainment", "Cinema", shares=even(6400,[ME,OLA],ME), h=17)
exp((*O,4), 4899, "health", "Pharmacy", h=11)
market = exp((*O,4), 9230, "groceries", "Farmers' market", shares=even(9230,[ME,OLA],ME), h=10)
exp((*O,4), 1850, "dining", "Coffee & croissant", h=9)
zak = exp((*O,4), 126000, "travel", "Weekend in Zakopane", paid=KUBA, shares=even(126000,[ME,KUBA,MARTA],KUBA,pending=(ME,)), h=12)
# --- September (history)
S=(2026,9)
exp((*S,1), 420000, "housing", "Rent", shares=even(420000,[ME,OLA],ME))
exp((*S,3), 21400, "groceries", "Weekly shop"); exp((*S,10), 19870, "groceries", "Weekly shop")
exp((*S,17), 23150, "groceries", "Weekly shop"); exp((*S,24), 17620, "groceries", "Weekly shop")
exp((*S,5), 11000, "transport", "Monthly metro pass")
concert = exp((*S,12), 36000, "entertainment", "Concert tickets", paid=KUBA, shares=even(36000,[ME,KUBA],KUBA))
gdansk = exp((*S,19), 90000, "travel", "Gdańsk Airbnb", paid=MARTA, shares=even(90000,[ME,OLA,MARTA],MARTA))
exp((*S,20), 24800, "dining", "Pierogi & drinks", shares=even(24800,[ME,OLA,MARTA],ME))
exp((*S,8), 15999, "health", "Dentist check-up"); exp((*S,14), 8900, "shopping", "Books")
exp((*S,26), 27300, "utilities", "Internet & power", paid=OLA, shares=even(27300,[ME,OLA],OLA))
# repayment: Ola paid back most of the rent
rep_id = U()
repayments.append({"id":rep_id,"fromUserId":OLA,"toUserId":ME,"amountMinor":180000,"currencyCode":"PLN","note":"Rent","paidAt":ts(*O,2,20),"createdAt":ts(*O,2,20)})
repayments.append({"id":U(),"fromUserId":OLA,"toUserId":ME,"amountMinor":210000,"currencyCode":"PLN","note":"Rent","paidAt":ts(*S,3,20),"createdAt":ts(*S,3,20)})
# --- activity (unread, newest first in app)
event("shared", KUBA, ts(*O,4,12,40), zak, recips=(ME,MARTA), share_amt=42000)
event("accepted", OLA, ts(*O,4,10,20), market, recips=(ME,), share_amt=4615)
event("accepted", KUBA, ts(*O,3,22,5), dinner, recips=(ME,), share_amt=10400)
event("accepted", OLA, ts(*O,3,21,48), dinner, recips=(ME,), share_amt=10400)
event("repayment_recorded", OLA, ts(*O,2,20), recips=(ME,), share_amt=180000, rep=rep_id, title="Rent", cat="other", total=180000)
event("shared", OLA, ts(*O,1,18,2), power, recips=(ME,), share_amt=14450)
event("accepted", OLA, ts(*O,1,9,30), rent, recips=(ME,), share_amt=210000)

def hexd(obj): return json.dumps(obj, ensure_ascii=False).encode().hex()
out = {"loam.local.expenses":hexd(expenses),"loam.local.activity.v1":hexd(activity),"loam.local.repayments":hexd(repayments)}
json.dump(out, open("/tmp/loam-shots/seed.json","w"))
print(len(expenses), "expenses", len(activity), "events")
