import os
import uuid
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
import markdown
import aiosqlite
from fastapi import FastAPI, Request, Form, Response, Depends, HTTPException, status
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.security import HTTPBasic, HTTPBasicCredentials

DB_FILE = "pastebin.db"
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

@asynccontextmanager
async def lifespan(app: FastAPI):
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
            
    return templates.TemplateResponse(request, "index.html", {"mode": "dashboard", "pastes": pastes})

@app.get("/dashboard/{paste_id}", response_class=HTMLResponse)
async def dashboard_view_paste(request: Request, paste_id: str, author: str = Depends(get_current_author)):
    # This route is protected by your admin password!
    paste = await get_paste(paste_id)
    if not paste:
        return HTMLResponse("<h1>Paste not found</h1>", status_code=404)

    # We skip the "burn" check here so the author can still load the page.
    # The content will render as [CONTENT DESTROYED], but comments are preserved.
    html_content = markdown.markdown(paste["content"], extensions=['fenced_code', 'tables'])
    
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM comments WHERE paste_id = ? ORDER BY created_at ASC", (paste_id,)) as cursor:
            comments = await cursor.fetchall()

    return templates.TemplateResponse(request, "index.html", {
        "mode": "read", 
        "paste": paste, 
        "content": html_content, 
        "comments": comments
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
    
    # 0. Doesn't exist at all
    if not paste:
        return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "not_found"})

    # 1. Already burned previously
    if paste["is_burned"] == 1:
        return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "already_burned"})

    # 2. Time Expiration Check
    if paste["expires_at"]:
        expires_at = datetime.fromisoformat(paste["expires_at"])
        if datetime.now(timezone.utc) > expires_at:
            await burn_paste(paste_id)
            return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "time_expired"})

    # 3. View Limit (Burn) Check
    if paste["max_views"] > 0 and paste["views"] >= paste["max_views"]:
        await burn_paste(paste_id)
        return templates.TemplateResponse(request, "index.html", {"mode": "burned", "reason": "view_limit"})

    # 4. Password Check
    if paste["password_hash"]:
        auth_cookie = request.cookies.get(f"auth_{paste_id}")
        if auth_cookie != paste["password_hash"]:
            return templates.TemplateResponse(request, "index.html", {"mode": "auth", "paste": paste})

    # Increment views
    async with aiosqlite.connect(DB_FILE) as db:
        await db.execute("UPDATE pastes SET views = views + 1 WHERE id = ?", (paste_id,))
        await db.commit()
    
    paste = await get_paste(paste_id)
    html_content = markdown.markdown(paste["content"], extensions=['fenced_code', 'tables'])
    
    async with aiosqlite.connect(DB_FILE) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM comments WHERE paste_id = ? ORDER BY created_at ASC", (paste_id,)) as cursor:
            comments = await cursor.fetchall()

    return templates.TemplateResponse(request, "index.html", {
        "mode": "read", 
        "paste": paste, 
        "content": html_content, 
        "comments": comments
    })

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