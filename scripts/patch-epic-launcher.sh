#!/usr/bin/env sh
#
# patch-epic-launcher.sh
# Bridgeplay integration script for Epic Games Launcher on macOS.
#
# Injects notepic.dylib into EpicGamesLauncher, configures LC_LOAD_DYLIB,
# clears stale platform cache, and signs the bundle with disable-library-validation.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EPIC_APP="/Applications/Epic Games Launcher.app"
EPIC_BIN="${EPIC_APP}/Contents/MacOS/EpicGamesLauncher"
NOTEPIC_SRC="${ROOT_DIR}/dylib/notepic/notepic.c"
OUT_DIR="${ROOT_DIR}/out"
NOTEPIC_DYLIB="${OUT_DIR}/notepic.dylib"
PAYLOAD_DIR="${ROOT_DIR}/app/Sources/BridgeplayApp/Resources/payload"
SUPPORT_DIR="${HOME}/Library/Application Support/bridgeplay"

echo "==> [Bridgeplay] Patching Epic Games Launcher for native Windows compatibility..."

if [ ! -d "${EPIC_APP}" ]; then
    echo "==> Error: ${EPIC_APP} not found."
    exit 1
fi

mkdir -p "${OUT_DIR}"
mkdir -p "${PAYLOAD_DIR}"
mkdir -p "${SUPPORT_DIR}"

# 1. Compile notepic.dylib if not already built
if [ ! -f "${NOTEPIC_DYLIB}" ] || [ "${NOTEPIC_SRC}" -nt "${NOTEPIC_DYLIB}" ]; then
    echo "--> Compiling notepic.dylib..."
    clang -dynamiclib -arch arm64 -mmacosx-version-min=12.0 \
        -Idylib -Ivendor/dobby/include -Ivendor/dobby/builtin-plugin/SymbolResolver \
        -install_name @rpath/notepic.dylib \
        -o "${NOTEPIC_DYLIB}" "${NOTEPIC_SRC}" \
        "${ROOT_DIR}/build/dobby/libdobby.a" \
        "${ROOT_DIR}/build/dobby/builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a" \
        -lc++
    codesign -f -s - --identifier com.bridgeplay.notepic "${NOTEPIC_DYLIB}"
fi

# Stage copies
cp "${NOTEPIC_DYLIB}" "${PAYLOAD_DIR}/notepic.dylib"
cp "${NOTEPIC_DYLIB}" "${SUPPORT_DIR}/notepic.dylib"
cp "${NOTEPIC_DYLIB}" "${EPIC_APP}/Contents/MacOS/notepic.dylib"

# 2. Clear stale macOS platform-availability cache
echo "--> Clearing stale Epic platform availability cache..."
python3 -c '
import glob, json, os

for p in glob.glob(os.path.expanduser("~/Library/Application Support/com.epicgames.eglv2/cache/prod/account/*/platform-availability-cache.json")):
    try:
        with open(p) as f:
            d = json.load(f)
        if d.get("platform") == "Mac":
            os.remove(p)
            print("  Removed stale cache:", p)
    except Exception:
        pass
'

# 3. Add LC_LOAD_DYLIB load command into EpicGamesLauncher binary
echo "--> Injecting notepic.dylib load command into EpicGamesLauncher..."
python3 -c '
import struct, subprocess

target = "'"${EPIC_BIN}"'"
dylib_path = b"@executable_path/notepic.dylib\x00"
str_offset = 24
cmdsize = (str_offset + len(dylib_path) + 7) & ~7
padding = cmdsize - (str_offset + len(dylib_path))

with open(target, "r+b") as f:
    header = f.read(32)
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack("<IiiIIIII", header)
    
    f.seek(32)
    cmds_data = f.read(sizeofcmds)
    if b"notepic.dylib" not in cmds_data:
        cmd_hdr = struct.pack("<IIIIII", 0xc, cmdsize, str_offset, 2, 0x10000, 0x10000)
        dylib_cmd = cmd_hdr + dylib_path + (b"\x00" * padding)
        
        f.seek(32 + sizeofcmds)
        f.write(dylib_cmd)
        
        ncmds += 1
        sizeofcmds += cmdsize
        f.seek(0)
        f.write(struct.pack("<IiiIIIII", magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved))
        print("  Added LC_LOAD_DYLIB for notepic.dylib")
    else:
        print("  LC_LOAD_DYLIB already present")
'

# 4. Inject LSEnvironment into Info.plist for LaunchServices
echo "--> Updating Info.plist LSEnvironment..."
if ! plutil -p "${EPIC_APP}/Contents/Info.plist" | grep -q "DYLD_INSERT_LIBRARIES"; then
    plutil -insert LSEnvironment -xml '<dict><key>DYLD_INSERT_LIBRARIES</key><string>@executable_path/notepic.dylib</string></dict>' "${EPIC_APP}/Contents/Info.plist" 2>/dev/null || true
fi

# 5. Codesign Epic Games Launcher ad-hoc with disable-library-validation
echo "--> Codesigning Epic Games Launcher with disable-library-validation..."
cat << 'EOF' > /tmp/epic_entitlements.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
EOF

codesign -f -s - --entitlements /tmp/epic_entitlements.plist "${EPIC_BIN}"
codesign --force --deep -s - --entitlements /tmp/epic_entitlements.plist "${EPIC_APP}"
rm -f /tmp/epic_entitlements.plist

echo "==> [Bridgeplay] Epic Games Launcher successfully patched and ready!"

