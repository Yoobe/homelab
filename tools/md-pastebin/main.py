import os
import uuid
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
import markdown
import aiosqlite
from fastapi import FastAPI, Request, Form, Response, Depends, HTTPException, status
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from fastapi.security import HTTPBasic, HTTPBasicCredentials

DB_FILE = "pastebin.db"
TRACKING_DB = "tracking.db"
templates = Jinja2Templates(directory="templates")
security = HTTPBasic()

AUTHOR_USER = os.getenv("AUTHOR_USER", "admin")
AUTHOR_PASS = os.getenv("AUTHOR_PASS", "admin")

def get_current_author(credentials: HTTPBasicCredentials = Depends(security)):
    is_correct_username = secrets.compare_digest(credentials.username, AUTHOR_USER)
    is_correct_password = secrets.compare_digest(credentials.password, AUTHOR_PASS)
    if not (is_correct_username and is_correct_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username

def get_client_ip(request: Request) -> str:
    # Safely extract the real IP from Traefik headers
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    real_ip = request.headers.get("X-Real-IP")
    if real_ip:
        return real_ip.strip()
    return request.client.host if request.client else "Unknown"

def simplify_ua(ua_string: str) -> str:
    if not ua_string: return "Unknown"
    ua = ua_string.lower()
    os_name = "Unknown OS"
    if "windows" in ua: os_name = "Windows"
    elif "mac os" in ua: os_name = "macOS"
    elif "linux" in ua: os_name = "Linux"
    elif "android" in ua: os_name = "Android"
    elif "iphone" in ua or "ipad" in ua: os_name = "iOS"
    
    browser = "Unknown Browser"
    if "firefox" in ua: browser = "Firefox"
    elif "chrome" in ua or "crios" in ua: browser = "Chrome"
    elif "safari" in ua: browser = "Safari"
    elif "edge" in ua: browser = "Edge"
    
    return f"{os_name} • {browser}"

def format_duration(seconds: int) -> str:
    if not seconds or seconds < 0: return "0s"
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h > 0: return f"{h}h {m}m"
    if m > 0: return f"{m}m {s}s"
    return f"{s}s"

@asynccontextmanager
async def lifespan(app: FastAPI):
    # 1. Main Database
    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS pastes (
                id TEXT PRIMARY KEY,
                title TEXT,
                content TEXT NOT NULL,
                password_hash TEXT,
                expires_at DATETIME,
                views INTEGER DEFAULT 0,
                max_views INTEGER DEFAULT 0,
                is_burned INTEGER DEFAULT 0
            )
        """)
        await db.execute("""
            CREATE TABLE IF NOT EXISTS comments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                paste_id TEXT,
                content TEXT NOT NULL,
                created_at DATETIME
            )
        """)
        await db.commit()
    
    # 2. Analytics Tracking Database (Second DB to protect content)
    async with aiosqlite.connect(TRACKING_DB) as tdb:
        await tdb.execute("""
            CREATE TABLE IF NOT EXISTS read_sessions (
                id TEXT PRIMARY KEY,
                paste_id TEXT,
                ip_address TEXT,
                user_agent TEXT,
                started_at DATETIME,
                last_seen_at DATETIME,
                duration_seconds INTEGER DEFAULT 0
            )
        """)
        await tdb.commit()
    yield

app = FastAPI(lifespan=lifespan)

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest() if password else None

async def get_paste(paste_id: str):
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM pastes WHERE id = ?", (paste_id,)) as cursor:
            return await cursor.fetchone()

async def burn_paste(paste_id: str):
    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute("UPDATE pastes SET is_burned = 1, content = '[CONTENT DESTROYED]' WHERE id = ?", (paste_id,))
        await db.commit()

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse(request, "index.html", {"mode": "create"})

@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request, author: str = Depends(get_current_author)):
    # Get pastes
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("""
            SELECT p.id, p.title, p.views, p.max_views, p.expires_at, p.is_burned, COUNT(c.id) as comment_count 
            FROM pastes p 
            LEFT JOIN comments c ON p.id = c.paste_id 
            GROUP BY p.id 
            ORDER BY p.is_burned ASC, p.expires_at ASC
        """) as cursor:
            pastes = await cursor.fetchall()
            
    # Get tracking aggregates from second DB
    async with aiosqlite.connect(TRACKING_DB) as tdb:
        tdb.row_factory = aiosqlite.Row
        async with tdb.execute("""
            SELECT paste_id, MAX(duration_seconds) as max_duration 
            FROM read_sessions GROUP BY paste_id
        """) as cursor:
            tracking_rows = await cursor.fetchall()
            tracking_map = {row["paste_id"]: row["max_duration"] for row in tracking_rows}
            
    enhanced_pastes = []
    for p in pastes:
        p_dict = dict(p)
        max_dur = tracking_map.get(p["id"], 0)
        p_dict["max_duration_fmt"] = format_duration(max_dur)
        enhanced_pastes.append(p_dict)
            
    return templates.TemplateResponse(request, "index.html", {"mode": "dashboard", "pastes": enhanced_pastes})

@app.get("/dashboard/{paste_id}", response_class=HTMLResponse)
async def dashboard_view_paste(request: Request, paste_id: str, author: str = Depends(get_current_author)):
    paste = await get_paste(paste_id)
    if not paste:
        return HTMLResponse("<h1>Paste not found</h1>", status_code=404)

    html_content = markdown.markdown(paste["content"], extensions=['fenced_code', 'tables'])
    
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM comments WHERE paste_id = ? ORDER BY created_at ASC", (paste_id,)) as cursor:
            comments = await cursor.fetchall()
            
    # Fetch read analytics for author
    sessions_data = []
    async with aiosqlite.connect(TRACKING_DB) as tdb:
        tdb.row_factory = aiosqlite.Row
        async with tdb.execute("SELECT * FROM read_sessions WHERE paste_id = ? ORDER BY started_at DESC", (paste_id,)) as cursor:
            rows = await cursor.fetchall()
            for r in rows:
                s = dict(r)
                s["ua_short"] = simplify_ua(s["user_agent"])
                s["duration_fmt"] = format_duration(s["duration_seconds"])
                # Format date nicer
                dt = datetime.fromisoformat(s["started_at"])
                s["date_fmt"] = dt.strftime("%b %d, %H:%M")
                sessions_data.append(s)

    return templates.TemplateResponse(request, "index.html", {
        "mode": "read", 
        "paste": paste, 
        "content": html_content, 
        "comments": comments,
        "is_author": True,
        "sessions": sessions_data
    })

@app.post("/create")
async def create_paste(
    response: Response,
    title: str = Form("Untitled"),
    content: str = Form(...),
    password: str = Form(None),
    expiration: str = Form("never"),
    burn_views: int = Form(0)
):
    paste_id = uuid.uuid4().hex[:10]
    pwd_hash = hash_password(password)
    
    expires_at = None
    now = datetime.now(timezone.utc)
    if expiration == "1h": expires_at = now + timedelta(hours=1)
    elif expiration == "1d": expires_at = now + timedelta(days=1)
    elif expiration == "1w": expires_at = now + timedelta(days=7)

    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute(
            "INSERT INTO pastes (id, title, content, password_hash, expires_at, max_views) VALUES (?, ?, ?, ?, ?, ?)",
            (paste_id, title, content, pwd_hash, expires_at, burn_views)
        )
        await db.commit()

    response.headers["HX-Redirect"] = f"/{paste_id}"
    return ""

@app.get("/{paste_id}", response_class=HTMLResponse)
async def view_paste(request: Request, paste_id: str):
    paste = await get_paste(paste_id)
    
    if not paste: return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "not_found"})
    if paste["is_burned"] == 1: return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "already_burned"})

    if paste["expires_at"]:
        expires_at = datetime.fromisoformat(paste["expires_at"])
        if datetime.now(timezone.utc) > expires_at:
            await burn_paste(paste_id)
            return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "time_expired"})

    if paste["max_views"] > 0 and paste["views"] >= paste["max_views"]:
        await burn_paste(paste_id)
        return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "view_limit"})

    if paste["password_hash"]:
        auth_cookie = request.cookies.get(f"auth_{paste_id}")
        if auth_cookie != paste["password_hash"]:
            return templates.TemplateResponse(request, "index.html", {"mode": "auth", "paste": paste})

    # Increment Views
    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute("UPDATE pastes SET views = views + 1 WHERE id = ?", (paste_id,))
        await db.commit()
    
    paste = await get_paste(paste_id)
    html_content = markdown.markdown(paste["content"], extensions=['fenced_code', 'tables'])
    
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM comments WHERE paste_id = ? ORDER BY created_at ASC", (paste_id,)) as cursor:
            comments = await cursor.fetchall()

    # --- Start Analytics Tracking ---
    session_id = uuid.uuid4().hex
    now = datetime.now(timezone.utc).isoformat()
    ip = get_client_ip(request)
    ua = request.headers.get("user-agent", "Unknown")
    
    async with aiosqlite.connect(TRACKING_DB) as tdb:
        await tdb.execute(
            "INSERT INTO read_sessions (id, paste_id, ip_address, user_agent, started_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
            (session_id, paste_id, ip, ua, now, now)
        )
        await tdb.commit()

    return templates.TemplateResponse(request, "index.html", {
        "mode": "read", 
        "paste": paste, 
        "content": html_content, 
        "comments": comments,
        "session_id": session_id,
        "is_author": False
    })

@app.post("/track/heartbeat/{session_id}")
async def heartbeat(session_id: str):
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(TRACKING_DB) as tdb:
        tdb.row_factory = aiosqlite.Row
        async with tdb.execute("SELECT started_at FROM read_sessions WHERE id = ?", (session_id,)) as cursor:
            row = await cursor.fetchone()
            if row:
                started_at = datetime.fromisoformat(row["started_at"])
                duration = int((now - started_at).total_seconds())
                await tdb.execute(
                    "UPDATE read_sessions SET last_seen_at = ?, duration_seconds = ? WHERE id = ?",
                    (now.isoformat(), duration, session_id)
                )
                await tdb.commit()
    return JSONResponse({"status": "ok"})

@app.post("/{paste_id}/auth", response_class=HTMLResponse)
async def auth_paste(request: Request, paste_id: str, password: str = Form(...)):
    paste = await get_paste(paste_id)
    pwd_hash = hash_password(password)
    
    if not paste or paste["password_hash"] != pwd_hash:
        return HTMLResponse("<p class='text-red-400 mt-2'>Incorrect password.</p>")
    
    response = HTMLResponse("")
    response.headers["HX-Redirect"] = f"/{paste_id}"
    response.set_cookie(key=f"auth_{paste_id}", value=pwd_hash, httponly=True, max_age=86400)
    return response

@app.post("/{paste_id}/comments", response_class=HTMLResponse)
async def add_comment(request: Request, paste_id: str, content: str = Form(...)):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute(
            "INSERT INTO comments (paste_id, content, created_at) VALUES (?, ?, ?)",
            (paste_id, content, now)
        )
        await db.commit()
    
    return templates.TemplateResponse(request, "index.html", {
        "mode": "comment_fragment",
        "comment": {"content": content, "created_at": now}
    })