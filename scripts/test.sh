#!/usr/bin/env bash
# All test layers: the core against a fake provider, then the view rendered offscreen with a mock core.
# Needs g++, Qt6 (Core, Network, Quick), nlohmann-json, python3, curl; the view needs the Logos design
# system (cloned once into $AIGW_TMP, or WB_DS=<logos-design-system>/src/qml).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIGW_TMP="${AIGW_TMP:-/tmp/aigw-test}"; mkdir -p "$AIGW_TMP"
fail=0
echo "== 1/2 core (fake OpenAI provider) =="
AIGW_TEST_OUT="$AIGW_TMP/core" "$ROOT/ai_gateway_core/test/run-tests.sh" | grep -vE '^  ok' || fail=1
echo "== 2/2 view (QML render, intent round trip, events) =="
if [ -z "${WB_DS:-}" ]; then
    [ -d "$AIGW_TMP/logos-design-system" ] || git clone -q --depth 1 https://github.com/logos-co/logos-design-system "$AIGW_TMP/logos-design-system"
    export WB_DS="$AIGW_TMP/logos-design-system/src/qml"
fi
AIGW_HARNESS_OUT="$AIGW_TMP/render" "$ROOT/tools/qml-harness/render.sh" | grep -E "QML errors|event delta|screenshots" || fail=1
grep -q "QML errors: 0, intent answered: yes" <(AIGW_HARNESS_OUT="$AIGW_TMP/render" "$ROOT/tools/qml-harness/render.sh" 2>&1) || fail=1
[ $fail = 0 ] && echo "ALL LAYERS GREEN" || { echo "SOMETHING FAILED"; exit 1; }
