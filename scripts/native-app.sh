#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$MODE" == "test" ]]; then
  swift test --package-path "$ROOT/Packages/WorkspaceCore"
  exec "$ROOT/scripts/native-prototype.sh" test
fi
export NATIVE_WORKSPACE_APP=1
if [[ "$MODE" == "smoke" ]]; then
  "$ROOT/scripts/native-prototype.sh" build
  OUTPUT="$("$ROOT/Prototypes/NativeShell/.build/BotWorkspace.app/Contents/MacOS/NativeShell" --verify-workspace "$@")"
  printf '%s\n' "$OUTPUT"
  grep -q '^NATIVE_PERSISTENCE_SMOKE=PASS ' <<< "$OUTPUT"
  exit
fi
exec "$ROOT/scripts/native-prototype.sh" "$MODE" --workspace "$@"
