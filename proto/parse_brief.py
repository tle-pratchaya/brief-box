"""ต้นแบบ parser แบบกฎ (ไม่ใช้ AI) สำหรับอีเมล MARCOM BRIEF
ใช้: python3 -I parse_brief.py <owner-email> file.eml [...]
พิสูจน์ว่าโครงสร้างบรีฟจริงแยกด้วยกฎได้แค่ไหน ก่อนตัดสินใจว่า AI ต้องทำส่วนไหน
"""
import email, email.policy, json, re, sys
from datetime import datetime
from email.utils import parsedate_to_datetime

MONTHS = {m: i for i, m in enumerate(
    "january february march april may june july august september october november december".split(), 1)}
# หัวส่วนของแต่ละคน: "Graphic: @Designer, Ploy<mailto:x@y>"
SECTION = re.compile(r"^(?P<role>[A-Z][\w &/]+):\s*@(?P<name>[^<\n]+)<mailto:(?P<mail>[^>]+)>", re.M)
ARTWORK = re.compile(r"^Artwork\s+(?P<n>\d+)\s*:\s*(?P<spec>.+)$", re.M | re.I)
DATE = re.compile(r"(?P<d>\d{1,2})\s+(?P<m>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b(?:\s+(?P<y>\d{4}))?", re.I)
PENDING = re.compile(r"[^.\n]*(share with you later|let me check|to be confirmed|TBC|TBA later|will send)[^.\n]*", re.I)
URL = re.compile(r"https?://[^\s<>\"]+")
SIZE = re.compile(r"(\d{3,4})\s*[x×]\s*(\d{3,4})\s*px|\b(\d{1,2}:\d{1,2})\b|\b(A[3-6])\b|IG Story|LCD", re.I)


def dates_in(line, sent):
    out = []
    for m in DATE.finditer(line):
        y = int(m["y"]) if m["y"] else sent.year
        mon = next(v for k, v in MONTHS.items() if k.startswith(m["m"].lower()[:3]))
        d = datetime(y, mon, int(m["d"]))
        if not m["y"] and d.date() < sent.date():  # ไม่มีปี และอยู่ก่อนวันส่งเมล → ปีหน้า
            d = d.replace(year=y + 1)
        out.append(d.date().isoformat())
    return out


def variants(spec):
    """แตกชิ้นงานย่อย: (horizontal and vertical) / (printed and digital) / variety"""
    v = []
    if re.search(r"horizontal and vertical", spec, re.I): v += ["แนวนอน", "แนวตั้ง"]
    if re.search(r"printed and digital", spec, re.I): v += ["ไฟล์พิมพ์", "ไฟล์ดิจิทัล"]
    if re.search(r"variety|multiple", spec, re.I): v += ["หลายแบบ (จำนวน?)"]
    return v


def parse(path, owner):
    m = email.message_from_binary_file(open(path, "rb"), policy=email.policy.default)
    sent = parsedate_to_datetime(m["Date"])
    body = m.get_body(preferencelist=("plain",)).get_content().replace("\r", "")
    secs = list(SECTION.finditer(body))
    mine = None
    for i, s in enumerate(secs):
        if s["mail"].lower() == owner.lower():
            end = secs[i + 1].start() if i + 1 < len(secs) else len(body)
            mine = (s["role"], body[s.end():end])
    intro = body[: secs[0].start()] if secs else body
    others = [f'{s["role"]} → {s["name"].strip()}' for s in secs if s["mail"].lower() != owner.lower()]
    my_text = mine[1] if mine else ""
    arts = [{"n": int(a["n"]), "spec": a["spec"].strip(),
             "size": [x for x in SIZE.findall(a["spec"]) for x in x if x] or None,
             "variants": variants(a["spec"])} for a in ARTWORK.finditer(my_text)]
    deadlines = []
    for line in my_text.splitlines():
        if re.search(r"deadline|draft|due", line, re.I) and DATE.search(line):
            for part in re.split(r"/", line):
                ds = dates_in(part, sent)
                if ds:
                    label = "ไฟนอล" if re.search(r"final", part, re.I) else "ดราฟต์แรก" if re.search(r"first", part, re.I) else "ส่งงาน"
                    deadlines.append({"label": label, "date": ds[0]})
    picture = next((l.split(":", 1)[1].strip() for l in my_text.splitlines() if l.lower().startswith("picture")), None)
    pending = sorted({p.strip() for p in PENDING.findall(body) and [x.group(0) for x in PENDING.finditer(body)]})
    # วันใช้งานจริงจากส่วนของทีมอื่น (เช่น วันโพสต์) = บริบทว่าชิ้นงานต้องพร้อมก่อนเมื่อไร
    used_on = []
    for s in secs:
        if s["mail"].lower() == owner.lower(): continue
        seg_end = next((t.start() for t in secs if t.start() > s.start()), len(body))
        for line in body[s.end():seg_end].splitlines():
            ds = dates_in(line, sent)
            if ds and not any(u["what"].startswith(line.strip(" *")[:40]) for u in used_on): used_on.append({"what": re.sub(r"\s+", " ", line.strip(" *"))[:90], "date": ds[0], "team": s["role"]})
    copy_blocks = [h for h in ("Short Text", "Long Text", "Package Prices", "AGENDA") if h.lower() in body.lower()]
    return {
        "subject": str(m["Subject"]), "from": str(m["From"]), "sent": sent.date().isoformat(),
        "message_id": m["Message-ID"], "is_reply": bool(m["In-Reply-To"]),
        "is_brief": str(m["Subject"]).upper().startswith("MARCOM BRIEF"),
        "mentions_me": owner.lower() in (m["X-Mentions"] or "").lower(),
        "my_role": mine[0] if mine else None, "other_teams": others,
        "artworks": arts, "deadlines": deadlines, "picture": picture,
        "waiting_for": pending, "used_on": used_on, "copy_blocks": copy_blocks,
        "links": sorted(set(URL.findall(body))),
        "attachments": [p.get_filename() for p in m.walk() if p.get_filename()],
        "intro_chars": len(intro), "my_section_chars": len(my_text), "body_chars": len(body),
    }


if __name__ == "__main__":
    owner = sys.argv[1]
    for f in sys.argv[2:]:
        print(json.dumps(parse(f, owner), ensure_ascii=False, indent=1))
