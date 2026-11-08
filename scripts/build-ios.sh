#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

archs="${IOS_ARCHS:-armv7}"
sdk="${IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
min_version="${IOS_MIN_VERSION:-8.0}"
clang="${IOS_CLANG:-$(xcrun --sdk iphoneos --find clang)}"
ldid="${LDID:-ldid}"
version="$(awk '/^Version:/ {print $2}' packaging/control)"
for tool in "$clang" "$ldid" dpkg-deb python3; do
    command -v "$tool" >/dev/null || { echo "Ferramenta ausente: $tool" >&2; exit 1; }
done
[[ -d "$sdk" ]] || { echo "SDK do iOS não encontrado: $sdk" >&2; exit 1; }

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
package="$build/deb"
app="$package/Applications/DNSBlockCentral.app"
mkdir -p "$package"/{DEBIAN,usr/libexec,Library/LaunchDaemons,etc/ipadmini-dnsblock} "$app" dist

arch_flags=()
for arch in $archs; do
    case "$arch" in armv7|arm64) arch_flags+=(-arch "$arch");; *) exit 1;; esac
done
flags=("${arch_flags[@]}" -isysroot "$sdk" "-miphoneos-version-min=$min_version" -O2 -Wall -Wextra)
if [[ -n "${IOS_LINKER:-}" ]]; then
    flags+=(--target="armv7-apple-ios$min_version" "-fuse-ld=$IOS_LINKER"
        -Werror=unguarded-availability -mlinker-version=609 -Wl,-segalign,4000 -Wl,-no_data_const)
fi
"$clang" "${flags[@]}" -std=c99 -pthread -DDNSBLOCK_IOS -c src/dnsblock.c -o "$build/dnsblock.o"
"$clang" "${flags[@]}" -fobjc-arc -fblocks -c src/blocklist-download.m -o "$build/blocklist-download.o"
"$clang" "${flags[@]}" "$build/dnsblock.o" "$build/blocklist-download.o" \
    -framework Foundation -framework CFNetwork -framework Security -lobjc -o "$package/usr/libexec/ipadmini-dnsblock"
# The iOS 8 runtime provides the ARC and Foundation features used here.
# Pass ARC to compilation only, so Clang does not force-load libarclite.
objects=()
for source in app/main.m app/Weather.m app/DrivePhotos.m app/Music.m app/YouTube.m; do
    object="$build/$(basename "$source" .m).o"
    "$clang" "${flags[@]}" -fobjc-arc -fblocks -c "$source" -o "$object"
    objects+=("$object")
done
"$clang" "${flags[@]}" "${objects[@]}" -framework UIKit -framework Foundation -framework EventKit -framework AVFoundation \
    -framework QuartzCore -framework CoreGraphics -framework CoreLocation -framework CFNetwork -framework ImageIO -framework Security -lobjc -o "$app/DNSBlock"
"$ldid" -S "$package/usr/libexec/ipadmini-dnsblock"
"$ldid" -S "$app/DNSBlock"

install -m 644 app/Info.plist app/Icon-*.png app/ISRG-Root-*.der app/GTS-Root-*.der "$app/"
python3 - "$app/Info.plist" "$min_version" <<'PLIST'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
info["MinimumOSVersion"] = sys.argv[2]
with open(sys.argv[1], "wb") as stream:
    plistlib.dump(info, stream)
PLIST
install -m 644 packaging/com.feijaum.ipadminidnsblock.plist "$package/Library/LaunchDaemons/"
install -m 644 config/{blocklist.txt,upstream} "$package/etc/ipadmini-dnsblock/"
install -m 644 packaging/{control,conffiles} "$package/DEBIAN/"
install -m 755 packaging/{postinst,prerm,postrm} "$package/DEBIAN/"

dpkg-deb --root-owner-group -Zgzip --build "$package" "dist/dnsblock-central-$version.deb"
echo "Pacote gerado em dist/."
