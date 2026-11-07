#!/usr/bin/env python3
"""Validate the packaged ARMv7 executables before uploading the iOS preview."""
import io
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tarfile
import zipfile


def verify_macho(executable):
    magic, cpu, subtype, kind, count, _, _ = struct.unpack_from("<7I", executable)
    if (magic, cpu, subtype & 0xFFFFFF, kind) != (0xFEEDFACE, 12, 9, 2):
        raise ValueError("Executável não é Mach-O ARMv7 de 32 bits")
    cursor = 28
    minimum = signature = None
    for _ in range(count):
        command, size = struct.unpack_from("<II", executable, cursor)
        if size < 8 or cursor + size > len(executable):
            raise ValueError("Load command inválido")
        if command == 0x25:
            minimum = struct.unpack_from("<I", executable, cursor + 8)[0]
        if command == 0x1D:
            signature = struct.unpack_from("<II", executable, cursor + 8)
        cursor += size
    if minimum != 0x00080000:
        raise ValueError("Versão mínima do Mach-O diferente de iOS 8.0")
    if signature is None or not signature[1] or sum(signature) > len(executable):
        raise ValueError("Assinatura ad hoc ausente ou inválida")


def main():
    ipa, deb = map(Path, sys.argv[1:])
    with zipfile.ZipFile(ipa) as app:
        info = plistlib.loads(app.read("Payload/DNSBlock.app/Info.plist"))
        if info.get("MinimumOSVersion") != "8.0" or info.get("CFBundleExecutable") != "DNSBlock":
            raise ValueError("Info.plist incompatível com a build")
        verify_macho(app.read("Payload/DNSBlock.app/DNSBlock"))
    payload = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(deb)])
    with tarfile.open(fileobj=io.BytesIO(payload)) as package:
        daemon = package.extractfile("./usr/libexec/ipadmini-dnsblock")
        verify_macho(daemon.read())
    print("IPA e DEB verificados: Mach-O ARMv7, iOS 8.0 e assinatura ad hoc.")


if __name__ == "__main__":
    main()
