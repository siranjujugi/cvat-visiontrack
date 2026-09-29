#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKBENCH="$SCRIPT_DIR/workbench"
INPUT_DIR="/Users/siranjeevi/Fork/visiontrack/data/eval/offline-080126"
START_AFTER_INSTALL=0

while (($#)); do
    case "$1" in
        --input-dir)
            INPUT_DIR=$2
            shift 2
            ;;
        --start)
            START_AFTER_INSTALL=1
            shift
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

"$WORKBENCH" install-deps
"$WORKBENCH" init "$INPUT_DIR"

APP_DIR="$HOME/Applications/VisionTrack Workbench.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
mkdir -p "$MACOS_DIR"

escaped_workbench=${WORKBENCH//\\/\\\\}
escaped_workbench=${escaped_workbench//\"/\\\"}
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    "\"$escaped_workbench\" start" \
    "\"$escaped_workbench\" open" \
    > "$MACOS_DIR/VisionTrackWorkbench"
chmod +x "$MACOS_DIR/VisionTrackWorkbench"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>VisionTrack Workbench</string>
    <key>CFBundleExecutable</key>
    <string>VisionTrackWorkbench</string>
    <key>CFBundleIdentifier</key>
    <string>ai.visiontrack.workbench</string>
    <key>CFBundleName</key>
    <string>VisionTrack Workbench</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

mkdir -p "$HOME/.local/bin"
ln -sfn "$WORKBENCH" "$HOME/.local/bin/visiontrack-workbench"

printf 'Installed: %s\n' "$APP_DIR"
printf 'CLI: %s\n' "$HOME/.local/bin/visiontrack-workbench"
printf 'Configuration: %s\n' "$HOME/VisionTrackWorkbench/config/workbench.env"

if ((START_AFTER_INSTALL)); then
    "$WORKBENCH" start
    "$WORKBENCH" import-comparison
    "$WORKBENCH" open
fi
