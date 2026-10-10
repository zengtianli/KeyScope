# KeyScope · Shortcut Detective

[中文](README.md) | **English**

Find the app receiving a Mac keyboard shortcut and inspect configuration clues.

[Product website](https://keyscope.tianli.cyou/) · [Download DMG](https://github.com/zengtianli/KeyScope/releases/download/v1.0.5/KeyScope-1.0.5-arm64.dmg) · [Releases](https://github.com/zengtianli/KeyScope/releases) · [Issue tracker](https://github.com/zengtianli/KeyScope/issues)

KeyScope is a native shortcut diagnostic tool for recent macOS versions, designed for users who know a key combination is being intercepted but cannot tell which app receives it.

- Start detection, press a shortcut, and view the hotkey recipient process when it can be identified.
- Select a shortcut manually to search readable system settings and configurations from common tools.
- Get separate explanations for confirmed recipients, configuration matches, and processes that may be listening.
- Analysis stays on your Mac. Keystrokes and configuration contents are not transmitted; key combinations are observed only during detection.

Requires macOS 14 or later and Apple Silicon. The current verified environment is macOS 27; other system versions have not each been tested.

<!-- lightweight:start -->
## Resource use (historical reference: 1.0.4)

| Download | Idle memory | Idle CPU | Speed |
|---|---|---|---|
| **1.4 MB** (installed 2.3 MB) | **25.2 MB** | **0%** | **336 ms** |

SwiftUI and system frameworks with no third-party dependencies; no background process, login item or scheduled job. A listen-only keyboard tap is set up only after you click Start Detection and is removed once a combination arrives; the 2-second permission self-check exists only during detection.

<sub>v1.0.4 (8) · Mac16,12 / Apple M4 / macOS 27.2 · The installed local acceptance build 1.0.4 (8) (Developer ID signed, not notarized or released) is launched quietly until the first screen is laid out, with no keyboard listener; the full lookup reads the real local shortcut configuration, read-only. Download size is the public 1.0.4 (5) DMG. · measured 2026-10-07. Measured on the listed device; re-measured for each version. Memory uses phys_footprint; CPU is CPU time ÷ wall time over a 60-second sampling window; sizes in decimal MB. Measurement details: [website resource use](https://keyscope.tianli.cyou/#light).</sub>
<!-- lightweight:end -->

Historical measurements of 1.0.4 (8), with download size from public 1.0.4 (5); these are not new measurements of 1.0.5.

## Installation and use

1. Download the DMG directly from the website and drag KeyScope into Applications.
2. Open KeyScope and follow the instructions to allow Input Monitoring.
3. Start detection and press the shortcut you want to investigate. Use manual lookup if the shortcut cannot be captured.
4. Review the evidence level and its explanation, then adjust the binding in the relevant app’s settings.

The current release is signed with an Apple Developer ID and notarized by Apple. First launch shows the normal confirmation for an internet download. See the website for complete permission instructions, common questions, and real demonstration videos.

## Command line

Since 1.0.3 the app includes the command `keyscope`, the same program as the window, for terminals, scripts and agents:

```bash
ln -s /Applications/KeyScope.app/Contents/Resources/bin/keyscope ~/.local/bin/keyscope   # optional: put it on PATH
keyscope scan ctrl+g --json        # read-only lookup of ⌃G in system bindings and app configuration
keyscope detect --timeout 20       # wait for you to press a combination; report the app that received it
keyscope status --json             # version, caller and window Input Monitoring, Secure Input
keyscope update check --json       # latest public release and upgrade options
keyscope update install --dry-run --json  # preview only; installation requires explicit --yes
keyscope help
```

Commands are read-only except `update install --yes`. No command requests permissions or sends or synthesizes key events. Update checks and installation anonymously read public GitHub release information; installation also downloads the package. `detect` needs Input Monitoring for the terminal; without it, it exits at once with code 77.

## Detection scope

macOS does not provide a public API covering every form of event interception. KeyScope can identify recipients of some system-dispatched global hotkeys, but cannot guarantee a unique owner for every shortcut. A process having a keyboard listener also does not prove that it swallowed the current keystroke. When evidence is insufficient, the interface keeps the result marked “Unconfirmed.”

## Configuration and updates

The [latest Release](https://github.com/zengtianli/KeyScope/releases/latest) is authoritative for the current official version. Check for Updates reads the latest public release; the window and command line share the same installer. `keyscope update install --yes` verifies the package hash and developer signature before replacing KeyScope, then moves the previous app to the Trash after success. KeyScope has no settings to migrate, so it offers no iCloud configuration sync, import or export. `status` queries the running window's listening state and Input Monitoring permission, or explicitly reports unknown when it is absent.

## Build from source

Install Xcode or Command Line Tools with Swift and the macOS SDK, select a working toolchain, then run:

```bash
git clone https://github.com/zengtianli/KeyScope.git
cd KeyScope
bash build.sh
bash scripts/test.sh
```

The self-contained result is `build/KeyScope.app`; the author's shared tools are not required. Local builds default to ad-hoc signing and are not notarized official releases. To distribute your own build, set `CODESIGN_IDENTITY` to your Developer ID Application identity and complete Apple notarization and stapling. `BUILD_JOBS` controls compiler parallelism; `BUILD_OUT=build/preview` preserves an existing build. After quitting KeyScope, `bash scripts/install.sh` installs the build and links the command, retaining the previous installation for rollback.

Offline tests use synthetic snapshots to cover parsing, evidence rules and automatic stopping. They send no keystrokes, observe no actual input and request no permissions; actual shortcut detection needs a person to verify it. The [detection core notes](Sources/Detection/README.md) describe evidence levels and limits. Source snapshots may contain unreleased changes; Releases are authoritative for official binaries and hashes. Unused private-channel directories in shared code use generic example names; KeyScope's active update channel remains the public GitHub Release.

## License and feedback

Source, resources and binary releases are provided under the [MIT License](LICENSE). System frameworks are used; no third-party source is bundled. This product is not affiliated with the original ShortcutDetective author. Please submit reproducible steps through Issues; do not attach private configurations, passwords, or personal data.
