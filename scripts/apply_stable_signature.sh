#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/.build/DerivedData/Build/Products/Debug/Grammarless.app}"
FRAMEWORK="$APP/Contents/Frameworks/GrammarlessCore.framework"

if [[ ! -d "$APP" ]]; then
  echo "[grammarless-sign] missing app bundle: $APP" >&2
  exit 1
fi

if [[ -d "$FRAMEWORK" ]]; then
  codesign -f -s - -i local.yxp.grammarless.core '-r=designated => identifier "local.yxp.grammarless.core"' "$FRAMEWORK"
fi

codesign -f -s - -i local.yxp.grammarless '-r=designated => identifier "local.yxp.grammarless"' "$APP"

echo "[grammarless-sign] signed $APP with stable designated requirements"
