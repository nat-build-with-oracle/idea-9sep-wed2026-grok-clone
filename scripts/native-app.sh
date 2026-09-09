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
if [[ "$MODE" == "smoke" || "$MODE" == "provider-smoke" ]]; then
  "$ROOT/scripts/native-prototype.sh" build
  VERIFY_ARGS=(--verify-workspace)
  if [[ "$MODE" == "provider-smoke" ]]; then VERIFY_ARGS+=(--verify-provider); fi
  OUTPUT="$("$ROOT/Prototypes/NativeShell/.build/BotWorkspace.app/Contents/MacOS/NativeShell" "${VERIFY_ARGS[@]}" "$@")"
  printf '%s\n' "$OUTPUT"
  grep -q '^NATIVE_PERSISTENCE_SMOKE=PASS ' <<< "$OUTPUT"
  if [[ "$MODE" == "provider-smoke" ]]; then grep -q '^NATIVE_PROVIDER_SMOKE=PASS ' <<< "$OUTPUT"; fi
  exit
fi
exec "$ROOT/scripts/native-prototype.sh" "$MODE" --workspace "$@"
