# Contributing to Recall

Recall is a small product with a strong point of view. Contributions are
welcome when they make the panel quieter, the search more honest, or the local
story stronger.

## Ground rules

- Be decent. Assume good faith and critique the work, not the person.
- Keep the app local-first. No accounts, telemetry, analytics, cloud sync, or
  hidden network calls.
- Do not add a third-party dependency without discussing it first. The current
  app has no external packages.
- Preserve the semantic authority invariant: when the vector search has
  results, keyword matches may reorder them but must not add unrelated items.
- Do not weaken the privacy gates in `ClipboardMonitor`.
- Do not commit build products, model weights, signing identities, or personal
  team identifiers.

## Requirements

- macOS 15 or later
- Xcode 26 or later
- Apple Silicon recommended for the full EmbeddingGemma path

## Setup

```sh
git clone <repository-url> recall
cd recall
open Recall.xcodeproj
```

Select your own signing team in **Signing & Capabilities**. The repository does
not provide a team or a provisioning profile.

### Build and test

```sh
make build
make test
```

Or directly:

```sh
xcodebuild \
  -project Recall.xcodeproj \
  -scheme Recall \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The unit suite uses Swift Testing. It covers storage, FTS parsing, content
classification, and rank fusion. The UI is not automated; visual changes are
checked with the debug snapshot harness.

## Debug tools

These are compiled only in `DEBUG`:

- `RECALL_DEBUG_DATA=1` uses a temporary SQLite database, so experiments do not
  touch your real clipboard history.
- `RECALL_MODEL_SELFTEST=1` loads the embedding model and prints a small
  cross-language similarity report.
- `RECALL_SNAPSHOT_MODE=panel|onboarding|settings` renders a window to
  `RECALL_SNAPSHOT_PATH`.
- `RECALL_SNAPSHOT_STEP=0|1|2` selects an onboarding step.
- `RECALL_SNAPSHOT_QUERY="..."` seeds the panel with a query.
- `RECALL_SNAPSHOT_LEGACY_GLASS=1` forces the pre-26 glass path for captures.

Example:

```sh
APP="$HOME/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Recall.app"
open -n \
  --env RECALL_SNAPSHOT_MODE=panel \
  --env RECALL_DEBUG_DATA=1 \
  --env RECALL_SNAPSHOT_QUERY='that SQL query from last week' \
  --env RECALL_SNAPSHOT_PATH=/tmp/recall-panel.png \
  "$APP"
```

Do not rely on these flags in production code.

## What to check before opening a pull request

### Privacy

- Does the change add a network request? If so, can it be optional, explicit,
  and pinned?
- Does it read the pasteboard outside the change counter path?
- Does it bypass a concealed, transient, secure-input, excluded-app, or
  self-write gate?
- Does it log clipboard text, embeddings, or source-app content?
- Does it write outside `~/Library/Application Support/Recall` without a clear
  reason?

### Search

- Does the keyword expression still require meaningful tokens?
- Does the semantic cutoff still use both the absolute floor and the
  top-relative margin?
- Are keyword-only items kept out when semantic results exist?
- Are provider IDs and dimensions still checked before vectors are compared or
  written?
- Did you test both English and Russian queries?

### UI

- Does the panel still work as a non-activating `NSPanel`?
- Do `↑`/`↓`/`↵`/`⌘↵`/`Tab`/`Esc` still behave?
- Does the empty, searching, permission, and no-results states still fit?
- Does it look right in light and dark appearance?
- Does it respect Reduce Motion?
- Are the onboarding steps still fixed-height and evenly paced?

### Model changes

If you change the pinned revision or assets:

1. Update `EmbeddingGemmaModelStore.repository`, `revision`, and `assets`.
2. Update the asset sizes and SHA-256 values.
3. Update `THIRD_PARTY_NOTICES.md` and `docs/MODEL.md`.
4. Re-run the calibration checklist in `docs/MODEL.md`.
5. Verify a fresh download, a resumed download, a checksum failure, and a
   compile/load failure path.

## Style

- Swift 6, strict concurrency, nonisolated default isolation.
- Actors for I/O and search; `@MainActor` for UI and app state.
- Prefer small value types and explicit dependencies.
- Keep user-facing copy in English, concise, and free of hype.
- Use the existing design tokens in `Recall/Design/Theme.swift`.
- No force unwraps in product code. Debug-only harness code may be pragmatic.

## Commits

Small, focused commits are easier to review. A reasonable shape:

```text
feat(panel): keep semantic results authoritative
fix(model): reject vectors from a retired provider
docs: explain the relative cutoff
```

## License

By contributing, you agree that your contribution is licensed under the MIT
License for application code, and that adapted third-party work remains under
its original license. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
