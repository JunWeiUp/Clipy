#!/usr/bin/env bash
# Builds an isolated experimental app. Never installs or replaces ClipyClone.
set -euo pipefail
command -v proxy >/dev/null 2>&1 && proxy || true
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$TASK_ROOT/scripts/runtime_env.sh"
CACHE_ROOT="${CLIPY_NSH_CACHE:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/clipy-nsh}"
OUTPUT="${CLIPY_NSH_OUTPUT:-$CACHE_ROOT/packages}"
HELPER="$("$TASK_ROOT/scripts/build_native.sh")"
mkdir -p "$OUTPUT"
"$CLIPY_NSH_BIN" package "$TASK_ROOT" --target macos --out "$OUTPUT" --name "Clipy TSX Preview" --id dev.clipy.tsx.macos
APP="$OUTPUT/Clipy TSX Preview.app"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$OUTPUT" -maxdepth 1 -type d -name '*.app' -print -quit)"
fi
[[ -n "$APP" && -d "$APP" ]] || { echo 'NSH app package not found' >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
MACOS="$APP/Contents/MacOS"
[[ "$(stat -f %z "$MACOS/$EXECUTABLE")" -gt 1048576 ]] || { echo "NSH did not produce a fresh runtime executable" >&2; exit 1; }
mv -f "$MACOS/$EXECUTABLE" "$MACOS/$EXECUTABLE.runtime"
cp "$HELPER" "$MACOS/clipy-native"
swiftc -O -target "$(uname -m)-apple-macos14.0" "$TASK_ROOT/host/macos/Launcher.swift" -o "$MACOS/$EXECUTABLE"
python3 - "$TASK_ROOT" "$APP" "$clipy_runtime_version" <<'PYMETA'
import hashlib,json,sys
from pathlib import Path
source,app=map(Path,sys.argv[1:3]);files=[source/'App.tsx',source/'nsh.json',source/'theme.json',source/'tsconfig.json']
files+=sorted((source/'src').rglob('*.ts'))+sorted((source/'src').rglob('*.tsx'))+sorted((source/'src').rglob('*.json'))+sorted((source/'assets').rglob('*'))+sorted((source/'host').rglob('*.swift'))
files=[file for file in files if not {'.nsh','.build','__pycache__','node_modules'}.intersection(file.relative_to(source).parts)]
metadata={'runtime':sys.argv[3],'sourceHashes':{str(file.relative_to(source)):hashlib.sha256(file.read_bytes()).hexdigest() for file in files if file.is_file()},'rustWorkspace':False,'macOSMinimum':'14.0'}
(app/'Contents/Resources/nsh/source-inputs.json').write_text(json.dumps(metadata,indent=2)+'\n')
PYMETA
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$TASK_ROOT/../LICENSE" "$APP/Contents/Resources/Licenses/Clipy.txt"
if [[ -f "$TASK_ROOT/../LICENSE.GPL-3.0" ]]; then cp "$TASK_ROOT/../LICENSE.GPL-3.0" "$APP/Contents/Resources/Licenses/GPL-3.0.txt"; fi
python3 - "$CLIPY_NSH_BIN" "$TASK_ROOT" "$APP" <<'PYLICENSE'
import os,shutil,sys
from pathlib import Path
binary,source,app=sys.argv[1],Path(sys.argv[2]),Path(sys.argv[3])
cli=Path(shutil.which(binary) or binary).resolve()
license_file=cli.parent.parent/'LICENSE-APACHE'
if license_file.is_file():shutil.copyfile(license_file,app/'Contents/Resources/Licenses/NSH-Apache-2.0.txt')
relay=Path(os.environ.get('COMMON_RELAY_PATH',str(source.parents[2]/'code/common-relay/sdk/swift')))
relay_license=relay.parent.parent/'LICENSE'
if relay_license.is_file():shutil.copyfile(relay_license,app/'Contents/Resources/Licenses/CommonRelay.txt')
PYLICENSE
# A local installation should supply a stable certificate. Keep the same
# identifier/requirement on every executable that accesses protected services.
CLIPY_SIGNER="${CLIPY_NSH_SIGN_IDENTITY:--}"
CLIPY_SIGNING_ID="dev.clipy.tsx.macos"
codesign --force --sign "$CLIPY_SIGNER" --identifier "$CLIPY_SIGNING_ID" "$MACOS/clipy-native"
codesign --force --sign "$CLIPY_SIGNER" --identifier "$CLIPY_SIGNING_ID" "$MACOS/$EXECUTABLE.runtime"
codesign --force --sign "$CLIPY_SIGNER" --identifier "$CLIPY_SIGNING_ID" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
du -sk "$APP" "$CACHE_ROOT/swift" >&2
