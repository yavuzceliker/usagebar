# Contributing to UsageBar

Thanks for helping out! Bug reports, ideas, translations and pull requests are all welcome.

## Ways to help

- **Report a bug**: [open an issue](https://github.com/yavuzceliker/usagebar/issues/new/choose) with your OS version, which provider (Cursor or Claude) and what you expected to see. On Windows, the output of `powershell -File UsageBar.ps1 -Probe` helps a lot. **Remove emails, tokens and amounts you do not want public before posting.**
- **Add a provider**: GitHub Copilot, Windsurf, OpenAI Codex, … Open an issue first so we can agree on where the numbers come from.
- **Add a language**: the strings live in [`macos/Sources/UsageBar/L10n.swift`](macos/Sources/UsageBar/L10n.swift) and at the top of [`windows/UsageBar.ps1`](windows/UsageBar.ps1).

## Project layout

```
macos/                     Swift Package, native menu bar app (macOS 13+)
  Sources/UsageBar/
    main.swift             status item, popover, timers
    AppModel.swift         accounts, polling, back-off, "last used" tracking
    AccountDiscovery.swift finds Cursor / Claude config folders
    CursorProvider.swift   Cursor API call + parser
    ClaudeProvider.swift   Claude API call + parser
    PopoverView.swift      the SwiftUI panel
    StatusRenderer.swift   draws the menu bar image (dot, tag, amount, bars)
    Heat.swift             blue → red color scale
    L10n.swift             English / Turkish strings
    Snapshotter.swift      --snapshot mode for screenshots
windows/                   single PowerShell script (WinForms) + installer
  UsageBar.ps1             same logic as the macOS app
  Kur.bat / Kaldir.bat     install / uninstall
docs/                      screenshots used by the README
```

Both versions share the same behavior: account discovery, polling intervals, rate-limit back-off, color scale and blink speeds. If you change one, please mirror it in the other (or say in the PR that you could not test it).

## Building and testing

**macOS**

```bash
cd macos
swift build                    # debug build
.build/debug/UsageBar          # run it
./build.sh                     # universal release .app in macos/build/
build/UsageBar.app/Contents/MacOS/UsageBar --snapshot /tmp/shots   # render the UI with your real accounts
build/UsageBar.app/Contents/MacOS/UsageBar --snapshot ../docs --demo   # README screenshots with fake data
```

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -File windows\UsageBar.ps1 -Probe   # accounts + numbers, no UI
powershell -ExecutionPolicy Bypass -File windows\UsageBar.ps1          # run the strip
powershell -ExecutionPolicy Bypass -File windows\UsageBar.ps1 -Snapshot $env:TEMP\shots   # render the UI with your real accounts
powershell -ExecutionPolicy Bypass -File windows\UsageBar.ps1 -Snapshot docs -Demo -Lang en   # README screenshots with fake data
```

Keep `UsageBar.ps1` saved as **UTF-8 with BOM** and compatible with Windows PowerShell 5.1 (no PowerShell 7-only syntax), so it runs on a stock Windows install.

## Ground rules

- **Never log, print, store or send tokens** anywhere other than the vendor's own API. Credentials are read-only: UsageBar must never refresh or rewrite a Claude or Cursor login.
- Do not commit screenshots that show real emails or spend. Use `--snapshot ... --demo` on macOS or `-Snapshot ... -Demo` on Windows.
- Keep it small: no new dependencies unless there is a strong reason.
- Match the surrounding code style. Keep PRs focused on one thing.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Make your change and test it on the platform(s) you touched.
3. Update the README if the behavior changes.
4. Open the PR and fill in the template.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
