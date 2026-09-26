# KeyScope · Shortcut Detective

[中文](README.md) | **English**

Find the app receiving a Mac keyboard shortcut and inspect configuration clues.

[Product website and downloads](https://keyscope.tianli.cyou/) · [Releases](https://github.com/zengtianli/KeyScope/releases) · [Issue tracker](https://github.com/zengtianli/KeyScope/issues)

KeyScope is a native shortcut diagnostic tool for recent macOS versions, designed for users who know a key combination is being intercepted but cannot tell which app receives it.

- Start detection, press a shortcut, and view the hotkey recipient process when it can be identified.
- Select a shortcut manually to search readable system settings and configurations from common tools.
- Get separate explanations for confirmed recipients, configuration matches, and processes that may be listening.
- Analysis stays on your Mac. Keystrokes and configuration contents are not transmitted; key combinations are observed only during detection.

Requires macOS 14 or later and Apple Silicon. The current verified environment is macOS 27; other system versions have not each been tested.

<!-- lightweight:start -->
## Lightweight (measured)

| Download | Idle memory | Idle CPU | Full shortcut lookup (same detector as GUI, including process start) |
|---|---|---|---|
| **1.2 MB** (installed 1.8 MB) | **24 MB** | **0.03%** | **33 ms** |

SwiftUI and system frameworks with no third-party dependencies; no background process, login item or scheduled job. A listen-only keyboard tap is set up only after you click Start Detection and is removed once a combination arrives; the 2-second permission self-check exists only during detection.

<sub>v1.0.1 · Mac16,12 / Apple M4 / macOS 27.2 · Signed and notarized installed 1.0.1; real local shortcut configuration, read-only lookup · measured 2026-09-26. Memory is phys_footprint (the Memory column in Activity Monitor); CPU is CPU time ÷ wall time over 60 idle seconds; sizes in decimal MB. Raw data: [perf/lightweight.json](perf/lightweight.json).</sub>
<!-- lightweight:end -->

## Installation and use

1. Download the DMG directly from the website and drag KeyScope into Applications.
2. Open KeyScope and follow the instructions to allow Input Monitoring.
3. Start detection and press the shortcut you want to investigate. Use manual lookup if the shortcut cannot be captured.
4. Review the evidence level and its explanation, then adjust the binding in the relevant app’s settings.

The current release is signed with an Apple Developer ID and notarized by Apple. First launch shows the normal confirmation for an internet download. See the website for complete permission instructions, common questions, and real demonstration videos.

## Detection scope

macOS does not provide a public API covering every form of event interception. KeyScope can identify recipients of some system-dispatched global hotkeys, but cannot guarantee a unique owner for every shortcut. A process having a keyboard listener also does not prove that it swallowed the current keystroke. When evidence is insufficient, the interface keeps the result marked “Unconfirmed.”

This repository provides product documentation and binary releases, not application source code. It is not affiliated with the original ShortcutDetective author. Please submit reproducible steps through Issues; do not attach private configurations, passwords, or personal data.
