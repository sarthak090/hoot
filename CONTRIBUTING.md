# Contributing to Hoot

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting started

You need macOS 14+ and Apple's Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```sh
swift run HootTests               # the test suite (plain executable; XCTest needs full Xcode)
./scripts/build-app.sh            # builds and ad-hoc-signs build/Hoot.app
open build/Hoot.app
```

Code layout and how the pieces fit together are in the [README](README.md#how-it-works). Logic that can be tested lives in `Sources/HootCore`; the app (UI, server, notifications) is in `Sources/Hoot`.

## Guidelines

- **Keep it safe.** Hoot can approve commands. Changes to the hook server, the hook scripts, the `settings.json` installer or the previews get extra scrutiny. Never add a keyboard shortcut that approves anything, and never send data off the Mac.
- **Test what you change.** Add checks to `Tests/HootTests` for logic in `HootCore`. For behavior that involves Claude Code, say in the pull request how you verified it.
- **Match the surrounding code** in naming, comment style and structure.
- **Screenshots and the demo video** are generated from the real app with sample data: `build/Hoot.app/Contents/MacOS/Hoot --render-preview docs/screenshots/menu.png --demo` and `./scripts/make-demo-video.sh` (needs ffmpeg). Never commit screenshots that contain your own projects or usage.

## Reporting security problems

Please don't open a public issue. See [SECURITY.md](SECURITY.md).
