"""Experimental personal-use audio bridge. Never expose without a token."""
import asyncio
import os
import secrets
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from fastapi import FastAPI, HTTPException, Header, BackgroundTasks
from fastapi.responses import FileResponse, HTMLResponse
import yt_dlp

app = FastAPI(docs_url=None, redoc_url=None)
TOKEN = os.getenv("AUDIO_BRIDGE_TOKEN", "")
LOCK = asyncio.Lock()
MAX_BYTES = 32 * 1024 * 1024

def get_video_id(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in ("www.youtube.com", "youtube.com", "m.youtube.com", "youtu.be"):
        raise ValueError("Use an HTTPS YouTube video URL")
    vid = parsed.path.lstrip("/") if parsed.hostname == "youtu.be" else parse_qs(parsed.query).get("v", [""])[0]
    if len(vid) != 11 or not all(c.isalnum() or c in "_-" for c in vid):
        raise ValueError("Invalid video ID")
    return vid

def download(vid: str, folder: str) -> Path:
    opts = {
        "format": "bestaudio[ext=m4a]/bestaudio",
        "outtmpl": str(Path(folder) / "track.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "socket_timeout": 20,
        "retries": 2,
        "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a", "preferredquality": "128"}],
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([f"https://www.youtube.com/watch?v={vid}"])
    matches = list(Path(folder).glob("track.*"))
    if not matches:
        raise RuntimeError("No output file")
    file = next((p for p in matches if p.suffix == ".m4a"), matches[0])
    if file.stat().st_size > MAX_BYTES:
        raise ValueError("Audio exceeds 32 MB")
    return file

@app.get("/health")
def health():
    return {"status": "ok", "service": "audio-bridge"}

@app.get("/audio")
async def audio(url: str, background_tasks: BackgroundTasks, authorization: str | None = Header(None)):
    if not TOKEN or not authorization or not secrets.compare_digest(authorization, f"Bearer {TOKEN}"):
        raise HTTPException(401, "Unauthorized")
    try:
        vid = get_video_id(url)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    if LOCK.locked():
        raise HTTPException(429, "Another download is running")
    async with LOCK:
        folder = tempfile.TemporaryDirectory(prefix="ipad-audio-")
        try:
            file = await asyncio.wait_for(asyncio.to_thread(download, vid, folder.name), timeout=150)
            background_tasks.add_task(folder.cleanup)
            return FileResponse(file, media_type="audio/mp4", filename="track.m4a", background=background_tasks)
        except Exception as exc:
            folder.cleanup()
            raise HTTPException(502, f"Audio unavailable: {type(exc).__name__}")

@app.get("/test", response_class=HTMLResponse)
def test_page():
    return """<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Teste Audio Bridge</title><style>body{font:16px system-ui;margin:24px;max-width:640px}input,button{font:inherit;padding:12px;box-sizing:border-box;width:100%;margin:6px 0 14px}button{background:#155eef;color:white;border:0;border-radius:8px}pre{white-space:pre-wrap;overflow-wrap:anywhere}audio{width:100%}</style></head><body><h2>Teste de audio - iPad mini</h2><p>A senha fica apenas neste navegador durante o teste. Nao envie prints com a senha.</p><label>Token privado</label><input id="token" type="password" autocomplete="off"><label>Link do video do YouTube</label><input id="url" type="url" placeholder="https://www.youtube.com/watch?v=..." ><button id="go">Testar download</button><pre id="status">Aguardando...</pre><audio id="player" controls></audio><script>let old=null;document.getElementById('go').onclick=async()=>{let b=document.getElementById('go'),s=document.getElementById('status'),p=document.getElementById('player');b.disabled=true;s.textContent='Solicitando audio (pode demorar)...';if(old){URL.revokeObjectURL(old);old=null}p.removeAttribute('src');try{let r=await fetch('/audio?url='+encodeURIComponent(document.getElementById('url').value),{headers:{Authorization:'Bearer '+document.getElementById('token').value}});if(!r.ok){s.textContent='HTTP '+r.status+' - '+(await r.text()).slice(0,400);return}let blob=await r.blob();old=URL.createObjectURL(blob);p.src=old;s.textContent='Audio recebido: '+(blob.size/1024/1024).toFixed(2)+' MB. Toque no Play.'}catch(e){s.textContent='Falha: '+e.message}finally{b.disabled=false}};</script></body></html>"""
