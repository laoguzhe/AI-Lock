<p align="center"><img src="icon.png" alt="AI Lock logo" width="128"></p>

<p align="center"><a href="README.md">简体中文</a> | <a href="README_EN.md">English</a></p>

# AI Lock

AI Lock is a free, native Swift/AppKit utility for macOS. It brings together system monitoring, network diagnostics, file and clipboard tools, quick launch, and multi-display utilities. It requires macOS 14 or later. Release builds support both Apple silicon and Intel Macs.

## Download and install

- [Download the latest DMG from GitHub Releases](https://github.com/laoguzhe/AI-Lock/releases/latest)
- [Download AI Lock DMG directly](https://github.com/laoguzhe/AI-Lock/releases/latest/download/AILock.dmg)

AI Lock is free and has no subscription or in-app purchases. Open the downloaded DMG, drag `AI Lock.app` to Applications, then launch it from Launchpad or Finder. macOS may ask for permissions when you first use screen recording, file search, or DockLock.

> This repository is currently Private, so only authorized GitHub users can access these links. Public downloads require making the repository public and creating a Release with the matching asset.

## Features

![AI Lock feature overview](docs/images/features-overview.png)

The image shows the main feature modules. Live system metrics were cropped out.

### System monitoring and maintenance

- **Resource overview and alerts:** Samples CPU, memory, disk, network, swap, battery, and thermal status. Configure thresholds and notifications. Alerts can continue in the background while the overview window is closed, with a cooldown for repeated alerts of the same type.
- **Process manager:** Inspect resource use, listening ports, and network rates; search, filter, or quit and force-quit processes. AI Lock rechecks process identity before acting. Batch quit applies only to ordinary apps belonging to the current user.
- **System health checks:** Run disk and memory performance checks and view device and OS information. Results depend on the current device load, storage, and network conditions.
- **Cache cleanup:** Review user caches managed by the app and confirm before cleanup. Quit the related app first when possible.
- **App uninstaller:** Review third-party apps installed for the user or on the Mac and their identifiable related items. Select items individually to move them to Trash. System apps are excluded.
- **Startup item inspection:** Review LaunchAgents, LaunchDaemons, and other startup configuration for possible issues. For a user configuration that cannot be parsed or points to a missing executable, inspect it and confirm before backing it up and moving it. Removing a configuration does not necessarily stop a service that is already running.
- **App logs:** View AI Lock's own macOS Unified Logging records. This is not a system-wide log viewer.

### Network activity and diagnostics

- **Network activity:** Observe current TCP/UDP connections and recent changes. Filter by app, PID, IP, port, protocol, or scope; inspect connection details and per-process rates; group by app and export CSV. Connections are sampled every five seconds, so short-lived connections can be missed. Changes during a pause cannot be reconstructed accurately.
- **Network diagnostics:** Run speed tests, compare endpoints and interfaces, query DNS, trace routes, measure ping loss and jitter, test TCP ports and IPv6 connectivity, and inspect local IP, gateway, routes, and proxy settings. Copy or export a report.
- **Network filtering preparation:** The project includes Network Extension content-filtering code and prototype configuration. System-wide filtering requires a signed extension, the relevant Apple capability, user approval, and testing on a real Mac. The default release does not claim to provide an enabled system-wide filter.

Network diagnostics connect to the test endpoints selected by the user. Speed tests transfer a limited amount of test data. CDN or VPN routing can affect the apparent location of a node, and an unresponsive probe does not always indicate a network failure. See the [network diagnostics notes](docs/network-latency-map.md) for methods and limitations.

### Files and AI tool activity

- **Unified floating search:** Search local apps, files and folders indexed by Spotlight, and AI Lock actions. Open a result or reveal it in Finder. The app also keeps a bounded local name cache for common folders.
- **Quick action bar:** Double-press Command to open it. Search apps, files, and actions; navigate with the keyboard and sort by recent use. Enter `> command` to explicitly choose running a command in Terminal. Ordinary search text is never executed automatically.
- **File activity audit:** Filter and inspect file-access events and export JSON. Endpoint Security reports metadata supplied by macOS: OPEN does not prove file contents were read, and CLOSE.modified does not capture every write call. Full-machine auditing requires Apple's approval for the Endpoint Security entitlement, a signed and activated system extension, and user authorization. **The default release does not include the extension and does not guarantee full-machine auditing.**
- **Agent Hooks:** Configure hooks for Claude Code, Codex, and Cursor to record sessions, tools, paths or commands, and completion, failure, or block status for calls that pass through those hooks. Rules can block some writes to sensitive paths or dangerous command patterns. Event metadata and rules stay on the Mac; file contents and tool output are not stored. Hooks cover only calls that trigger the configured hooks and are not a full-machine monitor.

See the [file activity notes](docs/文件活动.md) and [extension notes](extensions/README.md) for authorization states and limitations.

### Clipboard

- **Clipboard history:** Collection starts the first time the module is opened. Pause or resume collection, exclude selected apps, restore multiple copied items, add notes, search, and export or restore an encrypted backup.
- History is stored in a local SQLite database with per-record AES-GCM encryption and a key managed by Keychain. Retention is configurable from 1 to 30 days, with a maximum of 500 items or 64 MiB. A single copied item is limited to 8 MiB. Clipboard history is not uploaded by default.
- The app filters some common confidential/transient flags, but cannot identify every password or sensitive item and may not always identify the source app correctly. Set a retention period, exclude apps, or pause collection in Settings.

### Screen, displays, and menu bar

- **Screen recording:** Choose a display, resolution, and save folder to record screen video and system audio to a MOV file. View the elapsed time and stop a recording. macOS Screen & System Audio Recording permission is required. The shortcut is configurable in Settings.

  ![Screen recorder settings. The example path is generic; recording requires Screen & System Audio Recording permission.](docs/images/screen-recorder.png)

- **Display brightness:** An optional module that sends a unified brightness value to supported external DDC channels detected on some Apple silicon Macs. It does not read the current brightness. Intel Macs and some HDMI and dock setups are unsupported.
- **DockLock:** On multi-display setups, restrict the pointer from crossing an edge away from the target display and return the pointer to the Dock on that display when idle. Real mouse movement cancels a return in progress. Accessibility permission is required.
- **Menu bar organizer:** Fold less-used menu bar icons to the left of an arrow and expand them on demand. Configure automatic collapse after expansion. See the [menu bar organizer notes](docs/menu-bar-organizer.md).
- **Screen mask:** Show a black visual mask on selected displays while keeping at least one display visible. Press `⌘⌃⇧Esc` to remove all masks. A mask does not turn off a display or prevent macOS or other apps from reading its contents.

## Permissions and privacy

Most AI Lock data stays on the Mac. Clipboard history and Agent Hooks events are not uploaded by default. Network diagnostics connect to the test servers selected or configured by the user. Some features need explicit authorization:

- **Accessibility:** Required for DockLock and some global shortcut actions.
- **Input Monitoring:** Required for some global shortcut listeners. Open the authorization page from the shortcut settings in the app.
- **Full Disk Access:** Extends file search. App and action search remain available without it.
- **Screen & System Audio Recording:** Required for screen recording.
- **Endpoint Security / Network Extension:** Needed only for system-wide auditing or filtering. These features also depend on Apple's capability approval, extension signing, and system authorization; ordinary privacy permissions alone cannot enable them.

AI Lock does not represent an unauthorized feature as successfully collecting data. Clipboard history, file activity history, and Agent Hooks data can be deleted from their respective modules. Review each feature's description and choose an appropriate collection scope and retention period.

## Shortcuts and settings

Configure `⌘⌃1–9` to open modules. The quick action bar supports double-pressing Command or `⌘⌃⌥Space`. Unified floating search defaults to `⌥Space`. Settings include module visibility and order, alert thresholds, clipboard retention, startup behavior, and shortcuts.

DockLock also supports preferences for edge margin and target display, for example:

```bash
defaults write com.laogu.ailock edgeMargin -float 6.5
defaults write com.laogu.ailock autoSnap -bool true
defaults write com.laogu.ailock targetDisplay -string builtin # builtin | main | display ID
```

Settings normally reload within a few seconds. The app log is at `~/Library/Logs/AILock.log`.

## Build and create a DMG

Install Xcode Command Line Tools. For a development build and local DMG:

```bash
./build.sh
./package-dmg.sh
```

`package-dmg.sh` builds the app in `build/package/` and creates `AILock-<VERSION>-local.dmg`. This local package is not notarized and is intended for development or internal use, not public downloads.

To create a signed and notarized release build:

```bash
./package-dmg.sh --release
```

This invokes `release.sh`, which requires a Developer ID Application certificate and a configured `notarytool` profile. The DMG version comes from [`VERSION`](VERSION) and [`BUILD_NUM`](BUILD_NUM). The app bundle includes the project license and source attribution at `Contents/Resources/LICENSE.txt`.

Publishing a DMG requires Developer ID signing, notarization credentials, and GitHub CLI authentication. The GitHub Release asset uses the stable name `AILock.dmg`. While this repository is Private, only users with repository access can download it.

Other development checks are listed in [`tests/`](tests/). Real Endpoint Security authorization and system extension operation still require an approved entitlement and validation on an authorized Mac. A local prototype build does not replace that validation.

## License and attribution

This project uses a **modified MIT license with source attribution**. It permits free use, copying, modification, and redistribution, including commercial use. Redistributions must retain the license and credit AI Lock as the source. Modified versions must also describe their changes. This is not the unmodified standard MIT license; see [LICENSE](LICENSE) for the complete terms.

Attribution example:

> Based on AI Lock by 老谷: https://github.com/laoguzhe/AI-Lock

A modified version can add: `Modified by <name>; changes: <summary>.`

The code is primarily written in Swift and uses AppKit, SwiftUI, and macOS system frameworks. See [`docs/`](docs/) and [`extensions/README.md`](extensions/README.md) for background and implementation limits.
