#!/usr/bin/env bash
# Render module/qml/Main.qml offscreen with a mock core (system Qt6 + the Logos design system).
# WB_DS=<logos-design-system>/src/qml overrides where Logos.Theme comes from.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${AIGW_HARNESS_OUT:-/tmp/aigw-harness}"; mkdir -p "$OUT"
MOC="$(pkg-config --variable=libexecdir Qt6Core)/moc"
"$MOC" "$HERE/harness.cpp" -o "$HERE/harness.moc"
g++ -std=c++17 -fPIC -O1 $(pkg-config --cflags Qt6Quick Qt6Qml Qt6Gui Qt6Core) -I"$HERE" -I"$ROOT/ai_gateway_core/src" "$HERE/harness.cpp" -o "$OUT/harness" $(pkg-config --libs Qt6Quick Qt6Qml Qt6Gui Qt6Core) || exit 2
DS="${WB_DS:-}"
if [ -z "$DS" ]; then for d in /nix/store/*-logos-design-system-*/lib; do [ -f "$d/Logos/Theme/qmldir" ] && { DS="$d"; break; }; done; fi
export QML_IMPORT_PATH="${DS}${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
QT_QPA_PLATFORM=offscreen "$OUT/harness" "$ROOT/module/qml/Main.qml" "$HERE/fixture.json" "$OUT" 2>&1 | grep -v "^CALL" | tail -25
echo "screenshots: $OUT"
