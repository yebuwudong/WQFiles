#!/usr/bin/env bash
# Runtime localization checks against the shipped .lproj tables, one process
# per language (the main bundle picks its language at launch).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/wq-localization-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. WQLocalization.m tests/WQLocalizationTests.m \
    -framework Foundation -o "$OUT/WQLocalizationTests"
for lproj in ./*.lproj; do
    cp -R "$lproj" "$OUT/"
done
for language in en de it es pt-BR pl ru ko zh-Hans ar; do
    "$OUT/WQLocalizationTests" "$language" -AppleLanguages "($language)"
done
