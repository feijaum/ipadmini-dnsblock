import importlib.util
import json
import subprocess
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "integrations/youtube-audio/server.py"
SPEC = importlib.util.spec_from_file_location("youtube_audio", SOURCE)
converter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(converter)

TOKEN = "Bearer " + "a" * 48
VIDEO_ID = "BaW_jenozKc"


class AudioServerTest(unittest.TestCase):
    def setUp(self):
        self.server = converter.ThreadingHTTPServer(("127.0.0.1", 0), converter.AudioHandler)
        self.server.authorization = TOKEN.encode()
        self.server.conversion = threading.BoundedSemaphore(1)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def request(self, path, token=TOKEN):
        connection = HTTPConnection(*self.server.server_address, timeout=2)
        try:
            connection.request("GET", path, headers={"Authorization": token})
            response = connection.getresponse()
            return response.status, response.headers, response.read()
        finally:
            connection.close()

    def test_requires_token_and_rejects_arbitrary_urls(self):
        with patch.object(converter, "extract") as extract:
            self.assertEqual(self.request("/audio/" + VIDEO_ID, token="wrong")[0], 401)
            self.assertEqual(self.request("/audio/https://example.org")[0], 404)
            self.assertEqual(self.request("/audio/short")[0], 404)
            extract.assert_not_called()

    def test_serves_mp3_and_removes_temporary_file(self):
        def extract(arguments, directory, timeout):
            self.assertIn("-x", arguments)
            self.assertIn("mp3", arguments)
            self.assertEqual(arguments[-1], "https://www.youtube.com/watch?v=" + VIDEO_ID)
            self.assertEqual(timeout, 90)
            file = Path(directory, "track.mp3")
            file.write_bytes(b"mp3 fixture")
            files.append(file)

        files = []
        with patch.object(converter, "extract", side_effect=extract):
            status, headers, body = self.request("/audio/" + VIDEO_ID)
        self.assertEqual((status, headers["Content-Type"], body), (200, "audio/mpeg", b"mp3 fixture"))
        self.assertTrue(self.server.conversion.acquire(timeout=2))
        self.server.conversion.release()
        self.assertFalse(files[0].exists())

    def test_lists_only_valid_playlist_entries(self):
        output = {"entries": [None, {"id": "invalid"}, {"id": VIDEO_ID, "title": "Faixa"}]}
        with patch.object(converter, "extract", return_value=json.dumps(output).encode()):
            status, headers, body = self.request("/playlist/PL123")
        self.assertEqual((status, headers["Content-Type"]), (200, "application/json"))
        self.assertEqual(json.loads(body), [{"id": VIDEO_ID, "title": "Faixa"}])

    def test_reports_timeout_and_releases_conversion_slot(self):
        with patch.object(converter, "extract", side_effect=subprocess.TimeoutExpired("yt-dlp", 90)):
            self.assertEqual(self.request("/audio/" + VIDEO_ID)[0], 504)
        self.assertTrue(self.server.conversion.acquire(blocking=False))
        try:
            self.assertEqual(self.request("/audio/" + VIDEO_ID)[0], 503)
        finally:
            self.server.conversion.release()
