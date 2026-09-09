# Contributing

BotWorkspace is an experimental native macOS app. Read the
[product contract](docs/NATIVE-REWRITE-CONTRACT.md) and
[implementation checkpoint](docs/DURABLE-WORKSPACE.md) before changing behavior.
The original source and documentation are licensed under [MIT](LICENSE).

## Development

Use macOS with the Xcode Swift 6 toolchain selected. No third-party packages or
API credentials are needed to build or run the tests.

```sh
scripts/native-app.sh build
scripts/native-app.sh test
scripts/native-app.sh smoke
scripts/native-app.sh smoke --small
scripts/native-app.sh provider-smoke
scripts/native-app.sh provider-smoke --settings
scripts/native-app.sh provider-smoke --router-models
xcrun swift-format lint --strict --recursive \
  Packages/WorkspaceCore/Sources Packages/WorkspaceCore/Tests \
  Prototypes/NativeShell/Sources Prototypes/NativeShell/Tests
bash -n scripts/native-app.sh scripts/native-prototype.sh
git diff --check
```

If SwiftPM caches a local dependency's old source list after new files are added,
run `swift package --package-path Prototypes/NativeShell clean` and rebuild.
This removes generated build output, not the application's workspace data.

## Contribution boundaries

- Keep changes focused; add regression tests for changed behavior.
- Use original code and assets. Do not submit extracted Grok Bot/Cursor code,
  private endpoints, third-party screenshots, or credentials.
- Never commit workspace databases, Keychain exports, personal conversations,
  `.env` files, runtime logs, or `.omx` state. Use temporary synthetic fixtures.
- Keep provider tests offline with `URLProtocol`/protocol fixtures. Do not require
  contributor secrets or make billable live requests in tests.
- Preserve draft/save-failure behavior. Do not simulate successful model replies
  or scheduled work in the durable app when those services are disconnected.
- Document verification gaps. Local ad-hoc signing is not notarized distribution.

Private design references are intentionally absent from this repository. Build,
test and smoke commands do not need them. The `ψ/` placeholder directories and
`PROPOSAL.md` preserve the original idea capsule; they are not app runtime data.
