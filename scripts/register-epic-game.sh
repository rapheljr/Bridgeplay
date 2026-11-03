#!/bin/bash
# scripts/register-epic-game.sh
# Registers a Windows Epic game directory into Epic Games Launcher on macOS,
# creating a synthetic .item manifest and deploying the Bridgeplay trampoline.
set -euo pipefail

usage() {
    echo "Usage: $0 <game-folder-path> [catalog-item-id] [target-exe]"
    echo ""
    echo "Examples:"
    echo "  $0 ~/Games/GTAV 0584d2013f0149a791e7b9bad0eec102 PlayGTAV.exe"
    echo "  $0 ~/Games/GTAVEnhanced 9a5f2780e5b741dc94f4bf6d07e6012a GTA5_Enhanced.exe"
    exit 1
}

[ $# -ge 1 ] || usage

GAME_DIR="$(cd "$1" && pwd)"
CATALOG_ID="${2:-0584d2013f0149a791e7b9bad0eec102}"
TARGET_EXE="${3:-PlayGTAV.exe}"
DISPLAY_NAME="Grand Theft Auto V"

if [ "$CATALOG_ID" = "9a5f2780e5b741dc94f4bf6d07e6012a" ]; then
    DISPLAY_NAME="Grand Theft Auto V Enhanced"
    [ $# -lt 3 ] && TARGET_EXE="GTA5_Enhanced.exe"
fi

TRAMPOLINE_SRC="$HOME/Library/Application Support/bridgeplay/bridgeplay-epic-trampoline"
if [ ! -f "$TRAMPOLINE_SRC" ]; then
    TRAMPOLINE_SRC="$(dirname "$0")/../out/bridgeplay-epic-trampoline"
fi

if [ ! -f "$TRAMPOLINE_SRC" ]; then
    echo "Error: bridgeplay-epic-trampoline binary not found. Run 'make deploy' first." >&2
    exit 1
fi

echo "==> Registering $DISPLAY_NAME into Epic Games Launcher..."
echo "    Install Location : $GAME_DIR"
echo "    Catalog Item ID  : $CATALOG_ID"
echo "    Target Binary    : $TARGET_EXE"

# 1. Copy trampoline into game install directory
cp -f "$TRAMPOLINE_SRC" "$GAME_DIR/bridgeplay-epic-trampoline"
chmod +x "$GAME_DIR/bridgeplay-epic-trampoline"

# 2. Record target executable
echo "$TARGET_EXE" > "$GAME_DIR/bridgeplay-target.txt"

# 3. Create synthetic .item manifest
MANIFEST_DIR="$HOME/Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests"
mkdir -p "$MANIFEST_DIR"

CATALOG_UPPER="$(echo "$CATALOG_ID" | tr '[:lower:]' '[:upper:]')"
MANIFEST_FILE="$MANIFEST_DIR/${CATALOG_UPPER}.item"

cat << JSON > "$MANIFEST_FILE"
{
  "FormatVersion": 0,
  "AppVersionString": "1.0.0",
  "LaunchExecutable": "bridgeplay-epic-trampoline",
  "LaunchCommand": "",
  "PrereqIds": [],
  "PrereqSHA": "",
  "PrereqName": "",
  "PrereqPath": "",
  "PrereqArgs": "",
  "CatalogItemId": "$CATALOG_ID",
  "CatalogNamespace": "rdr",
  "DisplayName": "$DISPLAY_NAME",
  "InstallLocation": "$GAME_DIR",
  "AppName": "$CATALOG_ID",
  "bIsManaged": false,
  "bNeedsValidation": false,
  "bRequiresAuth": true
}
JSON

echo "==> Successfully created synthetic manifest at:"
echo "    $MANIFEST_FILE"
echo "==> Restart Epic Games Launcher. $DISPLAY_NAME will now appear as 'Installed' with a 'Launch' button!"
