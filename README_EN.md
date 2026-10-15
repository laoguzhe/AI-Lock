<p align="center"><img src="icon.png" alt="AI Lock logo" width="128"></p>

<p align="center"><a href="README.md">简体中文</a> | <a href="README_EN.md">English</a></p>

# AI Lock

AI Lock is a free, native Swift/AppKit utility for macOS. It is primarily designed to monitor AI tools and ensure they don't misbehave. (Endpoint Security permissions were not granted, so functionality is temporarily limited.) It also integrates system monitoring, network diagnostics, clipboard management, quick launch, Dock locking during multi-display collaboration, menu bar icon crowding solutions, screen recording, and multi-display assistance features. It requires macOS 14 or later. Only Apple Silicon Macs (M-series chips, arm64) are supported.

Local files, app settings, and clipboard history stay on your Mac. At launch, the app attempts to refresh the public speed-test node catalog from GitHub; other diagnostics and online lookups connect to external services when used.

# If you're interested in cross-model permanent memory, check out my other project [DAOSHI](https://daoshi.me)

## Download and install

- [Download the latest DMG from GitHub Releases](https://github.com/laoguzhe/AI-Lock/releases/latest)
- [Download AI Lock DMG directly](https://github.com/laoguzhe/AI-Lock/releases/latest/download/AILock.dmg)

AI Lock is free and has no subscription or in-app purchases. Open the downloaded DMG, drag `AI Lock.app` to Applications, then launch it from Launchpad or Finder. macOS may ask for permissions when you first use screen recording, file search, or DockLock.

> The repository must be Public for these links and in-app updates to work without GitHub credentials.

## Features

![AI Lock menu bar overview with live metrics, feature modules, and quick search](screenshots/features-overview.png)

The overview brings CPU, memory, disk, and network status together with the module shortcuts and search. Metrics shown are live values from the capture.

### System monitoring and maintenance

- **Resource overview and alerts:** Samples CPU, memory, disk, network, swap, battery, and thermal status. Configure thresholds and notifications. Alerts can continue in the background while the overview window is closed, with a cooldown for repeated alerts of the same type.
- **Process manager:** Inspect resource use, listening ports, and network rates; search, filter, or quit and force-quit processes. AI Lock rechecks process identity before acting. Batch quit applies only to ordinary apps belonging to the current user.
- **System health checks:** Run disk and memory performance checks and view device and OS information, fan speeds, and names and usage for internal and external disks. Results depend on the current device load, storage, and network conditions.
- **Cache cleanup:** Review user caches managed by the app and confirm before cleanup. Quit the related app first when possible.
- **App uninstaller:** Review third-party apps installed for the user or on the Mac and their identifiable related items. Select items individually to move them to Trash. System apps are excluded.
- **Startup item inspection:** Review LaunchAgents, LaunchDaemons, and other startup configuration for issues such as a missing Label or a missing or non-executable program. A current-user LaunchAgent that cannot be parsed or is otherwise invalid can be backed up before removal. System-level items must be handled through the owning app or an administrator. Removing a configuration does not necessarily stop a service that is already running.
- **App logs:** View AI Lock's own macOS Unified Logging records. This is not a system-wide log viewer.

| Process manager | App uninstaller |
| --- | --- |
| ![Process manager module](screenshots/processes.png) | ![App uninstaller module](screenshots/uninstaller.png) |
| Startup items |  |
| ![Startup item inspection module](screenshots/startup-items.png) |  |
| App logs |  |
| ![Application log module](screenshots/logs.png) |  |

### Network activity and diagnostics

- **Network activity:** Observe current TCP/UDP connections and recent changes. Filter by app, PID, IP, port, protocol, or scope; inspect connection details and per-process rates; group by app and export CSV. Connections are sampled every five seconds, so short-lived connections can be missed. Changes during a pause cannot be reconstructed accurately.
- **Network diagnostics:** Run speed tests, compare endpoints and interfaces, query DNS, trace routes with ICMP, measure ping loss and jitter, test TCP ports and IPv6 connectivity, and inspect local IP, gateway, routes, and proxy settings. Copy or export a report.
- **Automatic speed-test fallback:** If macOS `networkQuality` does not return a valid result, AI Lock tries the selected backup nodes, preferring Shanghai Telecom and Cloudflare. It reports a successful download separately when upload is unavailable or fails rather than presenting a one-way result as a complete test. At launch, it attempts to update China Telecom, Unicom, and Mobile node metadata from public GitHub CSV files. If that request fails, it keeps the last successful catalog and built-in nodes.
- **Network filtering preparation:** The project includes Network Extension content-filtering code and prototype configuration. System-wide filtering requires a signed extension, the relevant Apple capability, user approval, and testing on a real Mac. The default release does not claim to provide an enabled system-wide filter.

![Network activity summary with connection counts, rates, and filters](screenshots/network-activity.png)

Connection rows are cropped from the screenshot to protect privacy.

![Network diagnostics dashboard with latency, speed, DNS, ping, route, and local-configuration panels](screenshots/network-diagnostics.png)

This screenshot shows the idle dashboard before diagnostics have run; it contains no local addresses or test results.

Network diagnostics connect to the selected test endpoints. The launch-time GitHub request updates only public speed-test catalog metadata. Each fallback node downloads at most a 4 MiB sample; nodes that support upload testing receive a 2 MiB test payload. These tests do not upload user files or clipboard contents. The transport protocol depends on the selected node; some backup nodes use unencrypted HTTP and can observe connection metadata and test payloads. CDN or VPN routing can affect the apparent location of a node, and an unresponsive probe does not always indicate a network failure.

### Files and AI tool activity

The supplemental local index includes hidden files and folders. The quick-action window is 95% opaque and uses a thin divider between input and results.

- **Unified floating search:** Search local apps, files and folders indexed by Spotlight, and AI Lock actions. Open a result or reveal it in Finder. The app also keeps a bounded local name cache for common folders.
- **Quick action bar:** Double-press Command to open it. Search apps, files, and actions; navigate with the keyboard and sort by recent use. Enter `> command` to explicitly choose running a command in Terminal. Ordinary search text is never executed automatically.
- **File activity audit:** Filter and inspect file-access events and export JSON. Endpoint Security reports metadata supplied by macOS: OPEN does not prove file contents were read, and CLOSE.modified does not capture every write call. Full-machine auditing requires Apple's approval for the Endpoint Security entitlement, a signed and activated system extension, and user authorization. **The default release does not include the extension and does not guarantee full-machine auditing.**
- **Agent Hooks:** Configure hooks for Claude Code, Codex, and Cursor to record sessions, tools, paths or commands, and completion, failure, or block status for calls that pass through those hooks. Rules can block some writes to sensitive paths or dangerous command patterns. Event metadata and rules stay on the Mac; file contents and tool output are not stored. Hooks cover only calls that trigger the configured hooks and are not a full-machine monitor.

![Quick action bar showing Network Activity and Network Diagnostics for the “network” query](screenshots/quick-search.png)

The screenshot shows suggestions only; it does not open a module or run a command.

![Security Activity view with File Activity status and Agent Hooks connections](screenshots/file-activity.png)

The screenshot shows File Activity before Endpoint Security is connected and Agent Hooks connection status; event details are omitted.

File activity requires the relevant permissions. See the [extension notes](extensions/README.md) for extension status and limitations.

### Clipboard

If no content appears, click Check Clipboard Access to retry and allow access when macOS asks.

- **Clipboard history:** Collection starts the first time the module is opened. Pause or resume collection, exclude selected apps, restore multiple copied items, add notes, search, and export or restore an encrypted backup.
- History is stored in a local SQLite database with per-record AES-GCM encryption and a key managed by Keychain. Retention is configurable from 1 to 30 days, with a maximum of 500 items or 64 MiB. A single copied item is limited to 8 MiB. Clipboard history is not uploaded by default.
- The app filters some common confidential/transient flags, but cannot identify every password or sensitive item and may not always identify the source app correctly. Set a retention period, exclude apps, or pause collection in Settings.

### Screen, displays, and menu bar

- **Screen recording:** A flashing border identifies the selected display. Choose a resolution and save folder to record screen video and system audio to a MOV file. View the elapsed time and stop a recording. macOS Screen & System Audio Recording permission is required. The shortcut is configurable in Settings.

![Screen recorder settings for display, resolution, output folder, shortcut, and system audio](screenshots/screen-recorder.png)

For privacy, the screenshot crops out recording history and hides the local output path. Recording requires Screen & System Audio Recording permission.

- **Display controls:** Select one or more external displays, or select all, to adjust brightness and speaker volume. Displays must support and enable DDC/CI; some HDMI and dock setups are unsupported. Unidentified control channels are reported as failures.
- **DockLock:** On multi-display setups, restrict the pointer from crossing an edge away from the target display and return the pointer to the Dock on that display when idle. Real mouse movement cancels a return in progress. Accessibility permission is required.
- **Menu bar organizer:** Fold less-used menu bar icons to the left of an arrow and expand them on demand. Configure automatic collapse after expansion.
- **Screen mask:** Show a black visual mask on selected displays while keeping at least one display visible. Press `⌘⌃⇧Esc` to remove all masks. A mask does not turn off a display or prevent macOS or other apps from reading its contents.

| Display controls | DockLock |
| --- | --- |
| ![Display controls module](screenshots/displays.png) | ![DockLock and screen mask controls](screenshots/docklock.png) |
| Menu bar organizer |  |
| ![Menu bar organizer module](screenshots/menu-bar.png) |  |

## Permissions and privacy

Most AI Lock data stays on the Mac. Clipboard history and Agent Hooks events are not uploaded by default. Network diagnostics connect to the test servers selected or configured by the user. Some features need explicit authorization:

- **Accessibility:** Required for DockLock and some global shortcut actions.
- **Input Monitoring:** Required for some global shortcut listeners. Open the authorization page from the shortcut settings in the app.
- **Full Disk Access:** Extends file search. App and action search remain available without it.
- **Screen & System Audio Recording:** Required for screen recording.
- **Endpoint Security / Network Extension:** Needed only for system-wide auditing or filtering. These features also depend on Apple's capability approval, extension signing, and system authorization; ordinary privacy permissions alone cannot enable them.

AI Lock does not represent an unauthorized feature as successfully collecting data. Clipboard history, file activity history, and Agent Hooks data can be deleted from their respective modules. Review each feature's description and choose an appropriate collection scope and retention period.

Save Thresholds is gray until a setting changes, disabled while saving, and disabled again after saving. Switching modules reuses the same window and preserves its position and size.

## Shortcuts and settings

Configure `⌘⌃1–9` to open modules. The quick action bar supports double-pressing Command or `⌘⌃⌥Space`. Unified floating search defaults to `⌥Space`. Settings include module visibility and order, alert thresholds, clipboard retention, startup behavior, and shortcuts.

![Settings page with appearance, text size, language, clipboard retention, and login options](screenshots/settings.png)

The screenshot illustrates the settings layout; specific options and values reflect each user's preferences.

![Alerts page with resource thresholds and device activity reminders](screenshots/alerts.png)

DockLock also supports preferences for edge margin and target display, for example:

```bash
defaults write com.laogu.ailock edgeMargin -float 6.5
defaults write com.laogu.ailock autoSnap -bool true
defaults write com.laogu.ailock targetDisplay -string builtin # builtin | main | display ID
```

Settings normally reload within a few seconds. The app log is at `~/Library/Logs/AILock.log`.

## Build and create a DMG

Install Xcode Command Line Tools. Build the development app with:

```bash
./build.sh
```

With a Developer ID Application certificate and configured `notarytool` profile, `release.sh` creates a signed, notarized DMG that passes Gatekeeper validation:

```bash
VERSION="$(cat VERSION)" BUILD_NUM="$(cat BUILD_NUM)" ./release.sh
```

This script creates a local DMG and does not create a GitHub Release. Public releases commit and push the source before building, notarizing, and uploading the DMG, SHA-256 checksum, and `AILock-update.json` manifest. The repository must be public so the app can check for and download updates without GitHub credentials. At launch, the app checks the update manifest; when a newer version is available, it prompts the user, verifies the downloaded file, installs the update, and relaunches.

The repository does not include the automated publishing script; maintainers manage release credentials and publishing locally.

Other development checks are listed in [`tests/`](tests/). Real Endpoint Security authorization and system extension operation still require an approved entitlement and validation on an authorized Mac. A local prototype build does not replace that validation.

## License and attribution

This project uses a **modified MIT license with source attribution**. It permits free use, copying, modification, and redistribution, including commercial use. Redistributions must retain the license and credit AI Lock as the source. Modified versions must also describe their changes. This is not the unmodified standard MIT license; see [LICENSE](LICENSE) for the complete terms.

Attribution example:

> Based on AI Lock by 老谷: https://github.com/laoguzhe/AI-Lock

A modified version can add: `Modified by <name>; changes: <summary>.`

The code is primarily written in Swift and uses AppKit, SwiftUI, and macOS system frameworks. See [`extensions/README.md`](extensions/README.md) for extension implementation limits.
