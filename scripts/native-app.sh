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
if [[ "$MODE" == "smoke" || "$MODE" == "provider-smoke" || "$MODE" == "codex-smoke" || "$MODE" == "codex-smoke-stdin" || "$MODE" == "profile-smoke" || "$MODE" == "reply-smoke" || "$MODE" == "export-smoke" || "$MODE" == "deletion-smoke" || "$MODE" == "routine-smoke" || "$MODE" == "attachment-smoke" ]]; then
  "$ROOT/scripts/native-prototype.sh" build
  VERIFY_ARGS=(--verify-workspace)
  VERIFY_MODELS=0
  if [[ "$MODE" == "routine-smoke" ]]; then VERIFY_ARGS+=(--verify-routines); fi
  if [[ "$MODE" == "attachment-smoke" ]]; then VERIFY_ARGS+=(--verify-attachments); fi
  if [[ "$MODE" == "deletion-smoke" ]]; then VERIFY_ARGS+=(--verify-deletion); fi
  if [[ "$MODE" == "export-smoke" ]]; then VERIFY_ARGS+=(--verify-export); fi
  if [[ "$MODE" == "reply-smoke" ]]; then VERIFY_ARGS+=(--verify-replies); fi
  if [[ "$MODE" == "profile-smoke" ]]; then VERIFY_ARGS+=(--verify-profiles); fi
  if [[ "$MODE" == "codex-smoke" ]]; then VERIFY_ARGS+=(--verify-codex-fixture); fi
  if [[ "$MODE" == "codex-smoke-stdin" ]]; then VERIFY_ARGS+=(--verify-codex-stdin); fi
  if [[ "$MODE" == "provider-smoke" ]]; then VERIFY_ARGS+=(--verify-provider); fi
  if [[ "$MODE" == "provider-smoke" && " $* " == *" --router-models "* ]]; then
    VERIFY_ARGS+=(--settings)
    VERIFY_MODELS=1
  fi
  OUTPUT="$("$ROOT/Prototypes/NativeShell/.build/BotWorkspace.app/Contents/MacOS/NativeShell" "${VERIFY_ARGS[@]}" "$@")"
  printf '%s\n' "$OUTPUT"
  grep -q '^NATIVE_PERSISTENCE_SMOKE=PASS ' <<< "$OUTPUT"
  if [[ "$MODE" == "provider-smoke" ]]; then grep -q '^NATIVE_PROVIDER_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$VERIFY_MODELS" == "1" ]]; then grep -q '^NATIVE_MODEL_CATALOG_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "codex-smoke" || "$MODE" == "codex-smoke-stdin" ]]; then grep -q '^NATIVE_CODEX_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "profile-smoke" ]]; then grep -q '^NATIVE_PROFILE_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "reply-smoke" ]]; then grep -q '^NATIVE_REPLY_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "export-smoke" ]]; then grep -q '^NATIVE_EXPORT_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "deletion-smoke" ]]; then grep -q '^NATIVE_DELETION_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "routine-smoke" ]]; then grep -q '^NATIVE_ROUTINE_SMOKE=PASS ' <<< "$OUTPUT"; fi
  if [[ "$MODE" == "attachment-smoke" ]]; then grep -q '^NATIVE_ATTACHMENT_SMOKE=PASS ' <<< "$OUTPUT"; fi
  exit
fi
exec "$ROOT/scripts/native-prototype.sh" "$MODE" --workspace "$@"
