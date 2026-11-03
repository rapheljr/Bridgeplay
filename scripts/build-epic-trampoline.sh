#!/bin/sh
# scripts/build-epic-trampoline.sh
# Compiles the universal bridgeplay-epic-trampoline Mach-O binary.
# Supported on macOS 12.0+ (ARM64 Apple Silicon & x86_64).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT_DIR/helpers/bridgeplay-epic-trampoline.c"
OUT_DIR="$ROOT_DIR/out"
DEST_BIN="$OUT_DIR/bridgeplay-epic-trampoline"
PAYLOAD_DIR="$ROOT_DIR/app/Sources/BridgeplayApp/Resources/payload"
SUPPORT_DIR="$HOME/Library/Application Support/bridgeplay"

echo "==> Building Bridgeplay Epic Trampoline..."

# 1. Check for Clang compiler
if ! command -v clang >/dev/null 2>&1; then
    echo "Error: clang compiler not found. Please install Xcode command line tools." >&2
    exit 1
fi

# 2. Check for macOS SDK
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found via xcrun." >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "Error: Source file $SRC does not exist." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# 3. Compile universal Mach-O binary (arm64 + x86_64) targeting macOS 12.0+
echo "--> Compiling universal binary (-arch arm64 -arch x86_64, min macOS 12.0)..."
export MACOSX_DEPLOYMENT_TARGET=12.0
clang \
    -isysroot "$SDK_PATH" \
    -arch arm64 \
    -arch x86_64 \
    -mmacosx-version-min=12.0 \
    -O3 \
    -Wall \
    -Wextra \
    -std=gnu99 \
    "$SRC" \
    -o "$DEST_BIN"

# 4. Strip symbols
echo "--> Stripping debugging symbols..."
strip -x "$DEST_BIN"

# 5. Ad-hoc codesign
echo "--> Signing ad-hoc with com.bridgeplay.epic-trampoline identifier..."
codesign --force --sign - --identifier "com.bridgeplay.epic-trampoline" "$DEST_BIN"

# 6. Verify fat universal binary architectures
ARCH_INFO="$(lipo -info "$DEST_BIN")"
echo "--> Binary info: $ARCH_INFO"
case "$ARCH_INFO" in
    *arm64*x86_64*|*x86_64*arm64*)
        echo "--> Architecture verification passed (Universal arm64/x86_64)."
        ;;
    *)
        echo "Error: Binary is not universal: $ARCH_INFO" >&2
        exit 1
        ;;
esac

# 7. Stage into app payload if payload directory exists
if [ -d "$PAYLOAD_DIR" ]; then
    echo "--> Installing into payload staging: $PAYLOAD_DIR/bridgeplay-epic-trampoline"
    cp -f "$DEST_BIN" "$PAYLOAD_DIR/bridgeplay-epic-trampoline"
fi

# 8. Optionally install to user support directory if active
if [ -d "$SUPPORT_DIR" ]; then
    echo "--> Staging template to $SUPPORT_DIR/bridgeplay-epic-trampoline"
    cp -f "$DEST_BIN" "$SUPPORT_DIR/bridgeplay-epic-trampoline"
fi

echo "==> Bridgeplay Epic Trampoline successfully built at: $DEST_BIN"

