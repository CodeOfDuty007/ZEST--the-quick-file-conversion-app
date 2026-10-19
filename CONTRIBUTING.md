# Contributing to Zest

Thanks for helping. Zest is a small, focused app and the bar is "does it behave
correctly on a real Mac".

## Set up

```sh
git clone https://github.com/CodeOfDuty007/ZEST--the-quick-file-conversion-app.git
cd ZEST--the-quick-file-conversion-app
make bootstrap   # xcodegen, ffmpeg, webp via Homebrew
make test        # builds and runs every test target
make install     # copies Zest.app to ~/Applications and launches it
```

Zest needs **Accessibility** and **Input Monitoring** to see a drag and a Shift tap. Run
`make cert` once so those grants survive rebuilds (see `docs/PHASE0-SPIKE.md`).

## Ground rules

- **Engine code stays UI-free.** `ZestCore` must not import AppKit or SwiftUI. Anything
  with logic (routing, wheel geometry, navigation) is a pure function with a unit test.
- **Honest results.** A tool either does what its label says or is shown as unavailable
  with a reason. Never write an output that silently differs from what was asked.
- **Atomic outputs.** Write to a temp file, validate, then rename. No half-written files.
- **Swift 6 strict concurrency** is on; keep it warning-free.
- Two-space indentation, match the surrounding code.

## Pull requests

1. Open an issue first for anything bigger than a bug fix.
2. Add or update tests; `make test` must pass.
3. Describe what you tried on a real drag, not just that tests pass.

By contributing you agree your work is licensed under GPL-3.0-or-later.
