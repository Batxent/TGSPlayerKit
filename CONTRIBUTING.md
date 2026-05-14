# Contributing

TGSPlayerKit is early alpha. Keep changes small and evidence-backed.

## Local Checks

Before opening a pull request:

```bash
swift test
git diff --check
```

## Pull Request Expectations

- Keep public API changes intentional and documented in `README.md`.
- Add or update XCTest coverage for behavior changes.
- Do not vendor `rlottie` binaries without updating `NOTICE` and documenting the build process.
- Do not mix native bridge work with unrelated README, formatting, or example-app cleanup.
- Preserve the design boundary in `rlottie-tgs-player-design.md`: UIKit player, Swift core, native renderer bridge, no business-specific sticker pack logic.

## Commit Style

Use conventional commit prefixes when practical:

- `feat:` for new user-facing capability.
- `fix:` for bug fixes.
- `test:` for test-only changes.
- `docs:` for documentation.
- `ci:` for automation.
