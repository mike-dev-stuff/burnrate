<p align="center">
  <img src="Resources/icon.png" alt="Burnrate" width="128" height="128">
</p>

<p align="center">
  <a href="https://github.com/mike-dev-stuff/burnrate/releases">
    <img src="https://img.shields.io/badge/Download-Latest%20Release-blue?style=for-the-badge&logo=apple" alt="Download">
  </a>
</p>

# Burnrate

A macOS menubar app that displays your Claude Code and Codex usage statistics in real time.

This is a customized fork of [wrnsnng/burnrate](https://github.com/wrnsnng/burnrate), originally created by [Common Tools Co.](https://common-tools.co) and [Rich Sison](https://www.richardsison.com/). Their work provides the app's foundation, design, and usage tracking. See [CREDITS.md](CREDITS.md) for attribution.

Version **0.2.1-beta** simplifies the provider menu to Claude and Codex and uses a flame menu bar icon. See the [release notes](_releasenotes/v0.2.1-beta.md).

## Features

- **Real-time Usage Tracking**: Monitor your 5-hour, 7-day, and Opus utilization with visual progress bars
- **Current Session Info**: See token count and message count for your active session
- **Recent Sessions**: Quick access to your 8 most recent sessions with one-click resume
- **Usage Alerts**: Get notified when usage crosses 80% or 90% thresholds
- **Analytics Dashboard**: View historical usage trends with charts (24h, 7d, 30d)
- **Customizable Menubar**: Choose what to display (5-hour %, 7-day %, both, or icon only)
- **Settings Window**: Tabbed interface for General, Alerts, and About settings
- **Auto-refresh**: Data updates every 60 seconds automatically

## Prerequisites

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://claude.ai/code) installed and logged in (the app reads your OAuth token from Claude Code's keychain)

## Installation

### Option 1: Download Release (Recommended)

Download a build from this fork's [Releases](https://github.com/mike-dev-stuff/burnrate/releases), when available, unzip, and move Burnrate to Applications. Local builds are signed for local use and are not notarized.

Automatic updates are disabled until this fork has its own signed update feed.

### Option 2: Build from Source

```bash
# Clone the repository
git clone https://github.com/mike-dev-stuff/burnrate.git
cd burnrate

# Build and run a release (works with the Swift command-line tools)
swift build -c release
swift run -c release
```

To create a distributable .app bundle:

```bash
# Build release
swift build -c release

# Create app bundle, including the icon and Sparkle framework
mkdir -p dist/Burnrate.app/Contents/{MacOS,Resources,Frameworks}
cp .build/release/Burnrate dist/Burnrate.app/Contents/MacOS/
cp Resources/Info.plist dist/Burnrate.app/Contents/
cp Resources/AppIcon.icns dist/Burnrate.app/Contents/Resources/
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework dist/Burnrate.app/Contents/Frameworks/Sparkle.framework
install_name_tool -add_rpath @executable_path/../Frameworks dist/Burnrate.app/Contents/MacOS/Burnrate

# Sign for local use and package
codesign --force --sign - --entitlements Resources/Burnrate.entitlements dist/Burnrate.app
codesign --verify --deep --strict dist/Burnrate.app
ditto -c -k --keepParent dist/Burnrate.app dist/Burnrate-0.2.1-beta.zip
```

## Project Structure

```
burnrate/
├── Package.swift
├── Resources/
│   └── Info.plist                  # App bundle config
├── Sources/Burnrate/
│   ├── BurnrateApp.swift          # App entry point
│   ├── AppDelegate.swift           # Menubar & window management
│   ├── ContentView.swift           # Main popover UI
│   ├── UsageViewModel.swift        # Data fetching & state
│   ├── Models/
│   │   ├── SessionInfo.swift       # Session data
│   │   ├── UsageLimits.swift       # API usage data
│   │   └── AccountInfo.swift       # Account settings
│   ├── Services/
│   │   ├── SessionParser.swift     # Streaming JSONL parser
│   │   ├── AccountParser.swift     # Reads ~/.claude.json
│   │   ├── UsageAPIClient.swift    # Anthropic API client
│   │   ├── KeychainService.swift   # OAuth token access
│   │   ├── NotificationService.swift  # Usage alerts
│   │   ├── AnalyticsStore.swift    # Historical data storage
│   │   └── SettingsService.swift   # User preferences
│   └── Views/
│       ├── CurrentSessionView.swift
│       ├── UsageLimitsView.swift
│       ├── ExtraUsageView.swift
│       ├── RecentSessionsView.swift
│       ├── AnalyticsView.swift     # Charts & trends
│       ├── SettingsView.swift      # Tabbed settings
│       ├── AlertSettingsView.swift
│       └── ProgressBarView.swift
├── CLAUDE.md
└── README.md
```

## How It Works

The app reads data from three sources:

1. **Session Files** (`~/.claude/projects/`): JSONL files containing your conversation history with token usage
2. **Account Config** (`~/.claude.json`): Your account settings including extra usage status
3. **Anthropic API**: Real-time usage limits fetched using your OAuth token from the macOS Keychain

Analytics data is stored locally in `~/.burnrate/analytics.json`.

## Development

Key files:

- `UsageViewModel.swift` - Central state management with `@Observable`
- `Services/SessionParser.swift` - Streaming JSONL parser (handles large files efficiently)
- `Services/KeychainService.swift` - Reads OAuth token via `security` CLI
- `Services/UsageAPIClient.swift` - Fetches usage from Anthropic API
- `Services/AnalyticsStore.swift` - Persists usage snapshots and daily stats
- `Services/NotificationService.swift` - Handles macOS notifications for alerts

To modify the UI, edit files in `Views/`. The app uses standard SwiftUI components. Debug builds include design-time previews and require the full Xcode toolchain; release builds can use the Swift command-line tools.

### Debugging

Run with debug output:
```bash
swift build && .build/debug/Burnrate
```

Logs are printed to stderr with `[DEBUG]` prefix.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## Known Issues

- Requires Claude Code to be installed and logged in for OAuth token access

## License

MIT License - feel free to use and modify as needed.

## Acknowledgments

Thanks to [Common Tools Co.](https://common-tools.co), [Rich Sison](https://www.richardsison.com/), and the [upstream contributors](https://github.com/wrnsnng/burnrate/graphs/contributors) for creating and maintaining the original Burnrate project. Upstream Git history and author credits are preserved in this fork.

Built with [Claude Code](https://claude.ai/code) assistance.
