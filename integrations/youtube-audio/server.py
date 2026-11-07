"""Convert one YouTube track at a time to MP3 for the Central's local player."""
import argparse
import hmac
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

VIDEO = re.compile(r"[A-Za-z0-9_-]{11}")
PLAYLIST = re.compile(r"[A-Za-z0-9_-]{2,150}")
TOKEN = re.compile(r"[A-Za-z0-9_-]{32,128}")
MAX_BYTES = 32 * 1024 * 1024
PLAYLIST_LIMIT = 50


def extract(arguments, directory, timeout):
    command = [sys.executable, "-m", "yt_dlp", "--ignore-config", "--no-cache-dir",
               "--js-runtimes", "node", "--socket-timeout", "10", "--retries", "1",
               "--quiet", "--no-warnings", *arguments]
    with subprocess.Popen(command, cwd=directory, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as process:
        try:
            output, errors = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        if process.returncode:
            print(errors.decode(errors="replace")[-1500:], file=sys.stderr, flush=True)
            raise RuntimeError("Falha no yt-dlp")
        return output


class AudioHandler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def send_payload(self, status, mime, body):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        supplied = self.headers.get("Authorization", "").encode("utf-8")
        if not hmac.compare_digest(supplied, self.server.authorization):
            self.send_payload(401, "text/plain", b"Unauthorized")
            return

        path = urlsplit(self.path).path
        if path == "/health":
            self.send_payload(200, "text/plain", b"OK")
            return
        _, route, identifier = (path.split("/", 2) + ["", ""])[:3]
        if route == "audio" and VIDEO.fullmatch(identifier):
            operation = self.audio
        elif route == "playlist" and PLAYLIST.fullmatch(identifier):
            operation = self.playlist
        else:
            self.send_payload(404, "text/plain", b"Not found")
            return

        if not self.server.conversion.acquire(blocking=False):
            self.send_payload(503, "text/plain", b"Busy")
            return
        try:
            with tempfile.TemporaryDirectory(prefix="central-youtube-") as directory:
                operation(identifier, directory)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except subprocess.TimeoutExpired:
            self.send_payload(504, "text/plain", b"Timed out")
        except (OSError, ValueError, RuntimeError):
            self.send_payload(502, "text/plain", b"Media unavailable")
        finally:
            self.server.conversion.release()

    def audio(self, identifier, directory):
        extract(["--no-playlist", "--no-progress", "--abort-on-unavailable-fragments",
                 "--match-filters", "duration <= 1200 & !is_live",
                 "--max-filesize", "32M", "-f", "bestaudio",
                 "-x", "--audio-format", "mp3", "--audio-quality", "128K",
                 "-o", "track.%(ext)s", "--", "https://www.youtube.com/watch?v=" + identifier],
                directory, 90)
        file = Path(directory, "track.mp3")
        size = file.stat().st_size
        if not 0 < size <= MAX_BYTES:
            raise RuntimeError("Tamanho de áudio inválido")
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with file.open("rb") as track:
            shutil.copyfileobj(track, self.wfile)

    def playlist(self, identifier, directory):
        data = json.loads(extract(["--flat-playlist", "--dump-single-json", "--ignore-errors",
                                   "--playlist-end", str(PLAYLIST_LIMIT), "--",
                                   "https://www.youtube.com/playlist?list=" + identifier],
                                  directory, 35))
        if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
            raise RuntimeError("Playlist indisponível")
        tracks = [{"id": entry["id"], "title": str(entry.get("title") or "YouTube")[:150]}
                  for entry in data["entries"] if isinstance(entry, dict)
                  and isinstance(entry.get("id"), str) and VIDEO.fullmatch(entry["id"])]
        if not tracks:
            raise RuntimeError("Playlist sem faixas")
        self.send_payload(200, "application/json", json.dumps(tracks[:PLAYLIST_LIMIT]).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    token = os.environ.get("CENTRAL_YOUTUBE_TOKEN", "")
    if not TOKEN.fullmatch(token):
        parser.error("defina CENTRAL_YOUTUBE_TOKEN com 32 a 128 letras, números, hífens ou sublinhados")
    for binary in ("ffmpeg", "ffprobe", "node"):
        if not shutil.which(binary):
            parser.error(f"{binary} não encontrado no PATH")

    with ThreadingHTTPServer((args.bind, args.port), AudioHandler) as server:
        server.authorization = ("Bearer " + token).encode("ascii")
        server.conversion = threading.BoundedSemaphore(2)
        print(f"Áudio da Central em http://{args.bind}:{args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
