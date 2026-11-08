import json
from pathlib import Path
import plistlib
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LOOPBACK = "127.0.0.1"


def read_exact(stream, size):
    output = bytearray()
    while len(output) < size:
        chunk = stream.recv(size - len(output))
        if not chunk:
            raise EOFError("Resposta incompleta")
        output.extend(chunk)
    return bytes(output)


def framed(payload):
    return struct.pack("!H", len(payload)) + payload


def query(name, record_type=1):
    labels = b"".join(bytes([len(label)]) + label.encode() for label in name.split("."))
    return struct.pack("!HHHHHH", 0x3456, 0x0100, 1, 0, 0, 0) + labels + b"\0" + struct.pack(
        "!HH", record_type, 1
    )


def mock_answer(packet):
    flags = 0x8380 if b"truncated" in packet else 0x8180
    transaction = b"\0\0" if b"wrong-id" in packet else packet[:2]
    return transaction + struct.pack("!H", flags) + packet[4:]


class MockUDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(mock_answer(data), self.client_address)


class MockTCP(socketserver.BaseRequestHandler):
    def handle(self):
        size = struct.unpack("!H", read_exact(self.request, 2))[0]
        self.request.sendall(framed(mock_answer(read_exact(self.request, size))))


class DNSBlockTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream_udp = socketserver.UDPServer((LOOPBACK, 0), MockUDP)
        cls.upstream_port = cls.upstream_udp.server_address[1]
        cls.upstream_tcp = socketserver.TCPServer((LOOPBACK, cls.upstream_port), MockTCP)
        for server in (cls.upstream_udp, cls.upstream_tcp):
            threading.Thread(target=server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        for server in (cls.upstream_udp, cls.upstream_tcp):
            server.shutdown()
            server.server_close()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        folder = Path(self.directory.name)
        self.state = folder / "enabled"
        self.blocklist = folder / "blocklist.txt"
        self.blocklist.write_text("# comment\n ADS.Example. # note\ninvalid..example\n")
        self.upstream_file = folder / "upstream"
        self.upstream_file.write_text(LOOPBACK + "\n")
        with socket.socket() as dns, socket.socket() as control:
            dns.bind((LOOPBACK, 0))
            control.bind((LOOPBACK, 0))
            self.dns_port = dns.getsockname()[1]
            self.control_port = control.getsockname()[1]
        self.process = None
        self.addCleanup(self.stop_service)
        self.start_service()

    def start_service(self):
        self.process = subprocess.Popen(
            [
                str(ROOT / "build/dnsblock"),
                "lo",
                str(self.dns_port),
                str(self.control_port),
                "@" + str(self.upstream_file),
                str(self.upstream_port),
                str(self.blocklist),
                str(self.state),
                "-",
                LOOPBACK,
            ]
        )
        for _ in range(50):
            if self.process.poll() is not None:
                self.fail("O serviço encerrou durante a inicialização")
            try:
                self.control(b"status\n")
                return
            except OSError:
                time.sleep(0.02)
        self.fail("O serviço não respondeu")

    def stop_service(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None

    def control(self, message):
        with socket.create_connection((LOOPBACK, self.control_port), timeout=3) as client:
            client.sendall(message)
            with client.makefile("rb") as stream:
                return json.loads(stream.readline())

    def ask(self, packet, tcp=False):
        if tcp:
            with socket.create_connection((LOOPBACK, self.dns_port), timeout=3) as client:
                client.sendall(framed(packet))
                size = struct.unpack("!H", read_exact(client, 2))[0]
                return read_exact(client, size)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.settimeout(3)
            client.sendto(packet, (LOOPBACK, self.dns_port))
            return client.recv(65535)

    def test_loads_automatic_list_alongside_local_rules(self):
        cache = self.state.with_suffix(".blocklist")
        cache.write_text("# Number of entries: 1000\n" + "".join(
            f"ads-{index}.example.net\n" for index in range(1000)
        ))
        self.stop_service()
        self.start_service()

        self.assertEqual(self.control(b"status\n")["automatic_domains"], 1000)
        self.assertEqual(self.ask(query("sub.ads-42.example.net"), tcp=True)[3] & 0x0F, 3)
        self.assertEqual(self.ask(query("ads.example"))[3] & 0x0F, 3)
        self.assertEqual(self.ask(query("example.net"))[3] & 0x0F, 0)
        self.control(b"disable\n")
        self.assertEqual(self.ask(query("ads-42.example.net"))[3] & 0x0F, 0)

    def test_ignores_incomplete_automatic_list(self):
        self.state.with_suffix(".blocklist").write_text(
            "# Number of entries: 1001\n" + "ads.other.example\n" * 1000
        )
        self.stop_service()
        self.start_service()

        self.assertEqual(self.control(b"status\n")["automatic_domains"], 0)
        self.assertEqual(self.ask(query("ads.other.example"))[3] & 0x0F, 0)
        self.assertEqual(self.ask(query("ads.example"))[3] & 0x0F, 3)

    def test_blocks_domain_and_subdomain_on_udp_and_tcp(self):
        for tcp in (False, True):
            for name in ("ADS.Example", "sub.ads.example"):
                packet = query(name, 28)
                answer = self.ask(packet, tcp)
                self.assertEqual(answer[:2], packet[:2])
                self.assertEqual(answer[3] & 0x0F, 3)
                self.assertEqual(answer[12:], packet[12:])
        self.assertEqual(self.control(b"status\n")["blocked"], 4)

    def test_forwarding_preserves_question_and_truncation(self):
        for tcp in (False, True):
            for name in ("notads.example", "truncated.example"):
                packet = query(name)
                self.assertEqual(self.ask(packet, tcp), mock_answer(packet))

    def test_disable_persists_and_enable_restores_filter(self):
        self.assertFalse(self.control(b"disable\n")["enabled"])
        self.stop_service()
        self.start_service()
        packet = query("ads.example")
        self.assertEqual(self.ask(packet), mock_answer(packet))
        self.assertTrue(self.control(b"enable\n")["enabled"])
        self.assertEqual(self.ask(packet)[3] & 0x0F, 3)

    def test_compatibility_keeps_blocking_without_nxdomain(self):
        self.stop_service()
        self.state.write_text("1\n")  # Preference written by releases before compatibility mode.
        self.start_service()
        self.assertFalse(self.control(b"status\n")["compatibility"])
        self.assertTrue(self.control(b"compat\n")["compatibility"])
        self.stop_service()
        self.start_service()
        self.assertTrue(self.control(b"status\n")["compatibility"])

        for tcp in (False, True):
            for record_type, address_size in ((1, 4), (28, 16), (65, 0)):
                packet = query("sub.ads.example", record_type)
                answer = self.ask(packet, tcp)
                self.assertEqual(answer[:2], packet[:2])
                self.assertEqual(answer[3] & 0x0F, 0)
                self.assertEqual(answer[12:len(packet)], packet[12:])
                self.assertEqual(struct.unpack("!H", answer[6:8])[0], bool(address_size))
                if address_size:
                    record = struct.pack("!HHHIH", 0xC00C, record_type, 1, 0, address_size)
                    self.assertEqual(answer[len(packet):], record + bytes(address_size))
                else:
                    self.assertEqual(len(answer), len(packet))
            packet = query("plain.example")
            self.assertEqual(self.ask(packet, tcp), mock_answer(packet))

        self.assertEqual(self.control(b"status\n")["blocked"], 6)
        self.assertTrue(self.control(b"disable\n")["compatibility"])
        packet = query("ads.example")
        self.assertEqual(self.ask(packet), mock_answer(packet))
        self.assertTrue(self.control(b"enable\n")["compatibility"])
        self.assertFalse(self.control(b"standard\n")["compatibility"])
        self.assertEqual(self.ask(packet)[3] & 0x0F, 3)

    def test_rejects_malformed_dns_and_mismatched_upstream_reply(self):
        malformed = query("ads.example")[:14]
        self.assertEqual(self.ask(malformed)[3] & 0x0F, 1)
        self.assertEqual(self.ask(query("wrong-id.example"))[3] & 0x0F, 2)

    def test_tcp_accepts_multiple_queries_in_one_connection(self):
        with socket.create_connection((LOOPBACK, self.dns_port), timeout=3) as client:
            for name in ("plain.example", "other.example"):
                packet = query(name)
                client.sendall(framed(packet))
                size = struct.unpack("!H", read_exact(client, 2))[0]
                self.assertEqual(read_exact(client, size), mock_answer(packet))

    def test_http_request_cannot_toggle_filter(self):
        self.assertIn("error", self.control(b"POST /disable HTTP/1.1\r\n"))
        self.assertTrue(self.control(b"status\n")["enabled"])


class PackagingTest(unittest.TestCase):
    def test_panel_and_service_use_the_same_control_port(self):
        with (ROOT / "app/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        with (ROOT / "packaging/com.feijaum.ipadminidnsblock.plist").open("rb") as file:
            service = plistlib.load(file)
        self.assertEqual(info["MinimumOSVersion"], "8.0")
        self.assertEqual(info["CFBundleExecutable"], "DNSBlock")
        self.assertEqual(service["ProgramArguments"][2:4], ["53", "8753"])
        self.assertIn("htons(8753)", (ROOT / "app/main.m").read_text())


if __name__ == "__main__":
    unittest.main()
