#!/usr/bin/env python3
import html,json,os,subprocess,time
from http.server import BaseHTTPRequestHandler,HTTPServer
from urllib.parse import parse_qs,urlparse

HOST=os.environ.get("HOST","0.0.0.0")
PORT=int(os.environ.get("PORT","8080"))
POSTQUEUE="/usr/sbin/postqueue"
POSTSUPER="/usr/sbin/postsuper"
MAILQ="/usr/bin/mailq"
POSTCONF="/usr/sbin/postconf"
JOURNAL_LINES=int(os.environ.get("JOURNAL_LINES","80"))
APT_TTL=int(os.environ.get("APT_CACHE_SECONDS","1800"))
APT_CACHE_FILE=os.environ.get("APT_CACHE_FILE","/tmp/postfix-queue-viewer-apt.json")
SERVICE_NAME="postfix.service"
PROCESS_CANDIDATES=["master","qmgr","pickup","cleanup","tlsmgr","trivial-rewrite","smtp"]


def run(cmd, timeout=10):
    try:
        p=subprocess.run(cmd,capture_output=True,text=True,timeout=timeout)
        return p.returncode,p.stdout,p.stderr
    except Exception as ex:
        return 1,"",str(ex)


def pc(key):
    _,out,_=run([POSTCONF,key])
    return out.split("=",1)[-1].strip() if "=" in out else ""


def get_config():
    return {
        "hostname":pc("myhostname") or "unknown",
        "version":pc("mail_version") or "?",
        "relayhost":pc("relayhost") or "(direct)",
        "mynetworks":pc("mynetworks"),
        "interfaces":pc("inet_interfaces"),
        "tls":pc("smtp_tls_security_level"),
        "sasl":pc("smtp_sasl_auth_enable"),
    }


def get_postfix_service():
    rc,out,_=run(["systemctl","is-active",SERVICE_NAME])
    active=(out.strip() if out else "unknown")
    rc2,out2,_=run(["systemctl","is-enabled",SERVICE_NAME])
    enabled=(out2.strip() if out2 else "unknown")
    rc3,out3,_=run(["systemctl","show",SERVICE_NAME,"-p","SubState","-p","ActiveEnterTimestamp"])
    substate=""
    since=""
    for line in (out3 or "").splitlines():
        if line.startswith("SubState="):
            substate=line.split("=",1)[1].strip()
        elif line.startswith("ActiveEnterTimestamp="):
            since=line.split("=",1)[1].strip()
    return {"name":SERVICE_NAME,"active":active,"enabled":enabled,"substate":substate,"since":since}


def get_processes():
    found=[]
    rc,out,_=run(["ps","-eo","comm="])
    if rc!=0:
        return found
    lines=[x.strip() for x in out.splitlines() if x.strip()]
    for name in PROCESS_CANDIDATES:
        count=sum(1 for x in lines if x==name)
        if count:
            found.append({"name":name,"count":count})
    return found


def read_log():
    for unit in ["postfix","postfix.service"]:
        rc,out,_=run(["journalctl","-u",unit,"--no-pager","-n",str(JOURNAL_LINES),"--output","short"])
        if rc==0 and out.strip():
            return out
    return "No journal output found."


def load_queue():
    rc,out,err=run([POSTQUEUE,"-j"])
    if rc!=0:
        items,_=_text_queue()
        return items,"postqueue -j failed: "+(err or "").strip(),"text"
    out=out.strip()
    if not out:
        return [],"","json"
    items=[]
    for line in out.splitlines():
        line=line.strip()
        if not line:
            continue
        try:
            o=json.loads(line)
            recips=[r.get("address","") for r in o.get("recipients",[])]
            state=o.get("queue_name") or ("deferred" if o.get("delay_reason") else "active")
            items.append({
                "id":o.get("queue_id",""),
                "size":o.get("message_size",0),
                "sender":o.get("sender",""),
                "recipients":recips,
                "state":state,
                "delay":o.get("delay_reason","")
            })
        except Exception:
            continue
    return items,"","json"


def _text_queue():
    rc,out,err=run([MAILQ])
    if rc!=0:
        return [],(err or "mailq failed").strip()
    if "Mail queue is empty" in out:
        return [],""
    items=[]
    cur=None
    for raw in out.splitlines():
        line=raw.rstrip()
        if not line or line.startswith("--"):
            continue
        if raw and not raw.startswith(" ") and "@" in line:
            pts=line.split()
            qr=pts[0]
            qid=qr.rstrip("*!")
            flag=qr[-1] if qr and qr[-1] in ("*","!") else ""
            state="hold" if flag=="*" else ("deferred" if flag=="!" else "active")
            cur={"id":qid,"size":pts[1] if len(pts)>1 else "","sender":pts[-1] if len(pts)>1 else "","recipients":[],"state":state,"delay":""}
            items.append(cur)
        elif raw.startswith(" ") and cur:
            v=line.strip()
            if "@" in v and not cur["recipients"]:
                cur["recipients"].append(v)
            elif v.startswith("(") and v.endswith(")"):
                cur["delay"]=v[1:-1]
    return items,""


def read_apt_cache():
    try:
        with open(APT_CACHE_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def write_apt_cache(data):
    try:
        with open(APT_CACHE_FILE, "w") as f:
            json.dump(data, f)
    except Exception:
        pass


def get_apt_status():
    cached=read_apt_cache()
    now=time.time()
    if cached and now-cached.get("ts",0) < APT_TTL:
        return cached
    result={"ts":now,"updates":None,"sample":[],"unattended":"unknown","apt_daily":"unknown","apt_upgrade":"unknown","error":""}
    rc,out,_=run(["systemctl","is-active","unattended-upgrades.service"])
    result["unattended"]=(out.strip() if out else "unknown")
    rc,out,_=run(["systemctl","is-active","apt-daily.timer"])
    result["apt_daily"]=(out.strip() if out else "unknown")
    rc,out,_=run(["systemctl","is-active","apt-daily-upgrade.timer"])
    result["apt_upgrade"]=(out.strip() if out else "unknown")
    rc,out,err=run(["apt","list","--upgradable"], timeout=25)
    if rc == 0:
        lines=[x.strip() for x in out.splitlines() if x.strip() and not x.startswith("Listing...")]
        result["updates"]=len(lines)
        result["sample"]=lines[:8]
    else:
        result["error"]=(err or out or "apt failed").strip()
    write_apt_cache(result)
    return result


def esc(x):
    return html.escape(str(x))


def badge(state):
    s=(state or "").lower()
    if s in ("active","running","enabled"):
        return '<span class="badge ok">'+esc(state)+'</span>'
    if "defer" in s or s in ("activating","reloading","enabled-runtime"):
        return '<span class="badge warn">'+esc(state)+'</span>'
    if s in ("static","unknown"):
        return '<span class="badge neutral">'+esc(state)+'</span>'
    return '<span class="badge err">'+esc(state or "unknown")+'</span>'


def make_rows(items):
    if not items:
        return '<tr><td colspan="6" class="small" style="padding:16px 6px;">Queue is empty &#10003;</td></tr>'
    out=[]
    for i in items:
        recips="<br>".join(esc(r) for r in (i.get("recipients") or []))
        note=("<br><span class='small'>"+esc(i["delay"])+"</span>") if i.get("delay") else ""
        dbtn=("<form method='post' action='/action' class='inline'>"
              "<input type='hidden' name='op' value='delete'>"
              "<input type='hidden' name='id' value='"+esc(i.get("id",""))+"'>"
              "<button type='submit' class='danger' style='padding:3px 8px;font-size:11px;'>Del</button>"
              "</form>")
        out.append("<tr>"
            +"<td><code>"+esc(i.get("id",""))+"</code></td>"
            +"<td>"+esc(i.get("size",""))+"</td>"
            +"<td>"+esc(i.get("sender",""))+"</td>"
            +"<td>"+recips+note+"</td>"
            +"<td>"+badge(i.get("state",""))+"</td>"
            +"<td>"+dbtn+"</td></tr>")
    return "\n".join(out)


def cfg_rows(cfg):
    rows=[("relayhost",cfg["relayhost"]),("myhostname",cfg["hostname"]),("mynetworks",cfg["mynetworks"]),("inet_interfaces",cfg["interfaces"]),("smtp_tls_security_level",cfg["tls"]),("smtp_sasl_auth_enable",cfg["sasl"])]
    return "".join("<tr><td class='small' style='color:var(--muted);width:40%;'>"+esc(k)+"</td><td><code>"+esc(v)+"</code></td></tr>" for k,v in rows)


def process_html(procs):
    if not procs:
        return '<span class="small">No Postfix processes detected.</span>'
    return " ".join('<span class="pill"><code>'+esc(p["name"])+'</code> x '+str(p["count"])+"</span>" for p in procs)


def apt_html(info):
    sample=''.join('<div class="small"><code>'+esc(x)+'</code></div>' for x in info.get("sample",[]))
    if info.get("updates") is None:
        count='<span class="small">unknown</span>'
    else:
        count='<div class="value">'+str(info["updates"])+"</div>"
    err=''
    if info.get("error"):
        err='<div class="small" style="margin-top:8px;color:#ff7b72;">'+esc(info["error"])+"</div>"
    age=int(time.time()-info.get("ts",time.time()))
    return (
        '<div class="card"><div class="sec">APT updates</div>'
        '<div class="label">Upgradable packages</div>'+count+
        '<div style="margin:10px 0 12px 0;">'+
        '<span class="mini">unattended '+badge(info.get("unattended","unknown"))+'</span> '+
        '<span class="mini">apt-daily '+badge(info.get("apt_daily","unknown"))+'</span> '+
        '<span class="mini">apt-upgrade '+badge(info.get("apt_upgrade","unknown"))+'</span>'+
        '</div>'+
        sample+err+
        '<div class="small" style="margin-top:10px;">Cached '+str(age)+'s ago.</div></div>'
    )


def msg_box(cls,label,text):
    return ('<div class="card msg"><span class="badge '+cls+'">'+label+"</span>"+' <span class="small">'+esc(text)+"</span></div>")

CSS="""
:root{--bg:#0b0f14;--panel:#121922;--panel2:#18212d;--text:#e6edf3;--muted:#9fb0c0;--border:#263241;}*{box-sizing:border-box;}body{margin:0;padding:24px;background:var(--bg);color:var(--text);font:14px/1.5 ui-sans-serif,system-ui,sans-serif;}a{color:#58a6ff;text-decoration:none;}a:hover{text-decoration:underline;}.wrap{max-width:1280px;margin:0 auto;}.header{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:20px;flex-wrap:wrap;}.h1{font-size:24px;font-weight:700;}.sub{color:var(--muted);font-size:12px;margin-top:3px;}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:16px;}.card{background:linear-gradient(180deg,var(--panel),var(--panel2));border:1px solid var(--border);border-radius:12px;padding:14px;}.label{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px;}.value{font-size:22px;font-weight:700;}.row{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:16px;}.row3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:16px;margin-bottom:16px;}@media(max-width:980px){.row,.row3{grid-template-columns:1fr;}}pre{margin:0;white-space:pre-wrap;word-break:break-all;background:#0a0f15;border:1px solid var(--border);border-radius:10px;padding:12px;font-size:11px;max-height:480px;overflow:auto;}.tw{overflow:auto;}table{width:100%;border-collapse:collapse;}th,td{text-align:left;padding:7px 6px;border-bottom:1px solid var(--border);vertical-align:top;font-size:13px;}th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em;}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;}.ok{background:rgba(46,160,67,.18);color:#7ee787;}.warn{background:rgba(210,153,34,.18);color:#e3b341;}.err{background:rgba(248,81,73,.18);color:#ff7b72;}.neutral{background:rgba(88,166,255,.12);color:#79c0ff;}.actions{display:flex;gap:8px;flex-wrap:wrap;}button{background:#1f6feb;color:white;border:0;border-radius:8px;padding:8px 14px;font-weight:700;cursor:pointer;font-size:13px;}button.secondary{background:#21262d;border:1px solid var(--border);}button.danger{background:#da3633;}.small{font-size:12px;color:var(--muted);}form.inline{display:inline-flex;gap:8px;align-items:center;flex-wrap:wrap;}input[type=text]{min-width:200px;padding:8px 10px;border-radius:8px;border:1px solid var(--border);background:#0a0f15;color:var(--text);font-size:13px;}.sec{font-size:14px;font-weight:700;margin:0 0 10px 0;}.msg{margin-bottom:14px;padding:10px 14px;display:flex;align-items:center;gap:8px;}.footer{margin-top:14px;color:var(--muted);font-size:11px;}code{font-family:ui-monospace,monospace;font-size:12px;}.pill{display:inline-block;margin:0 8px 8px 0;padding:5px 9px;border:1px solid var(--border);border-radius:999px;background:#0a0f15;}.mini{display:inline-block;margin:0 8px 6px 0;}
"""


def render(message=""):
    cfg=get_config()
    svc=get_postfix_service()
    procs=get_processes()
    apt=get_apt_status()
    items,err,mode=load_queue()
    count=len(items)
    deferred=sum(1 for i in items if "defer" in (i.get("state") or "").lower())
    active=sum(1 for i in items if (i.get("state") or "").lower()=="active")
    hold=sum(1 for i in items if "hold" in (i.get("state") or "").lower())
    notices=message
    if err:
        notices=msg_box("err","error",err)+notices
    service_table=(
        '<table><thead><tr><th>Unit</th><th>Active</th><th>Enabled</th></tr></thead><tbody>'
        '<tr><td><code>'+esc(svc["name"])+'</code></td><td>'+badge(svc["active"])+'</td><td>'+badge(svc["enabled"])+'</td></tr>'
        '</tbody></table>'
        '<div class="small" style="margin-top:10px;">substate: '+esc(svc.get("substate") or "n/a")+'</div>'
        +('<div class="small">since: '+esc(svc["since"])+'</div>' if svc.get("since") else '')
    )
    parts=[
        '<!doctype html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        '<title>Postfix Queue Viewer</title><style>',CSS,'</style></head><body><div class="wrap">',
        '<div class="header"><div><div class="h1">&#9993; Postfix Queue Viewer</div><div class="sub">',esc(cfg["hostname"]),' &mdash; Postfix ',esc(cfg["version"]),'</div></div>',
        '<div class="actions"><form method="post" action="/action" class="inline"><input type="hidden" name="op" value="flush"><button type="submit">&#x21bb; Flush queue</button></form><a href="/raw"><button type="button" class="secondary">Raw queue</button></a><a href="/json"><button type="button" class="secondary">JSON</button></a></div></div>',
        notices,
        '<div class="grid"><div class="card"><div class="label">Queue entries</div><div class="value">',str(count),'</div></div><div class="card"><div class="label">Deferred</div><div class="value">',str(deferred),'</div></div><div class="card"><div class="label">Active</div><div class="value">',str(active),'</div></div><div class="card"><div class="label">Hold</div><div class="value">',str(hold),'</div></div></div>',
        '<div class="row3"><div class="card"><div class="sec">Postfix service</div>',service_table,'</div><div class="card"><div class="sec">Postfix processes</div>',process_html(procs),'</div>',apt_html(apt),'</div>',
        '<div class="row"><div class="card"><div class="sec">Postfix config</div><table><tbody>',cfg_rows(cfg),'</tbody></table></div><div class="card"><div class="sec">Postfix journal log (last ',str(JOURNAL_LINES),' lines)</div><pre>',esc(read_log()),'</pre></div></div>',
        '<div class="card"><div class="sec">Queue</div><div class="tw"><table><thead><tr><th>ID</th><th>Size</th><th>Sender</th><th>Recipients</th><th>State</th><th></th></tr></thead><tbody>',make_rows(items),'</tbody></table></div><div style="margin-top:14px;padding-top:14px;border-top:1px solid var(--border);"><div class="sec">Delete by queue ID</div><form method="post" action="/action" class="inline"><input type="hidden" name="op" value="delete"><input type="text" name="id" placeholder="e.g. 4F2C812345" required><button type="submit" class="danger">Delete</button></form></div></div>',
        '<div class="footer">All data live: postqueue / postconf / systemctl / ps / journalctl / apt.</div></div></body></html>'
    ]
    return ''.join(parts)


def do_action(form):
    op=(form.get("op") or [""])[0]
    if op=="flush":
        rc,out,err=run([POSTQUEUE,"-f"])
        text=(out or err or "flush requested").strip()
        return msg_box("ok","flushed",text) if rc==0 else msg_box("err","failed",text)
    if op=="delete":
        qid=(form.get("id") or [""])[0].strip()
        if not qid:
            return msg_box("err","error","Missing queue ID.")
        rc,out,err=run([POSTSUPER,"-d",qid])
        text=(out or err or qid).strip()
        return msg_box("ok","deleted",text) if rc==0 else msg_box("err","failed",text)
    return ""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def send(self, body, status=200, ctype="text/html; charset=utf-8"):
        b=body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type",ctype)
        self.send_header("Content-Length",str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        path=urlparse(self.path).path
        if path=="/json":
            items,err,mode=load_queue()
            self.send(json.dumps({
                "items":items,
                "error":err,
                "mode":mode,
                "service":get_postfix_service(),
                "processes":get_processes(),
                "config":get_config(),
                "apt":get_apt_status(),
            }, indent=2), ctype="application/json; charset=utf-8")
        elif path=="/raw":
            _,out,err=run([POSTQUEUE,"-p"])
            self.send(out or err, ctype="text/plain; charset=utf-8")
        else:
            self.send(render())
    def do_POST(self):
        length=int(self.headers.get("Content-Length","0"))
        data=self.rfile.read(length).decode("utf-8", errors="replace")
        form=parse_qs(data)
        self.send(render(do_action(form)))


if __name__=="__main__":
    print("Serving on http://{}:{}".format(HOST,PORT))
    HTTPServer((HOST,PORT),Handler).serve_forever()
