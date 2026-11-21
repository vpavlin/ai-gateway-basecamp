#!/usr/bin/env bash
# Build + run the core test against the fake provider (system Qt6 Core/Network, nlohmann-json, no nix).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${AIGW_TEST_OUT:-${TMPDIR:-/tmp}/aigw-test-build}"
mkdir -p "$OUT"
QT=$(pkg-config --cflags --libs Qt6Core Qt6Network)
MOC=$(pkg-config --variable=libexecdir Qt6Core)/moc
g++ -std=c++20 -O1 -g -fPIC -Wall -Wno-deprecated-declarations \
    -I"$HERE/fakesdk" -I"$HERE/../src" \
    "$HERE/core_test.cpp" "$HERE/../src/ai_gateway_core_impl.cpp" "$HERE/../src/aigw_server.cpp" \
    $QT -o "$OUT/core_test"
AIGW_TEST_TMP="$OUT" "$OUT/core_test" "$HERE"
