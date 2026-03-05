# CLAUDE.md

## Project Overview

`mas-legacyapps` is a Swift command-line tool for macOS that installs the last compatible version of Apple Pro and productivity apps for a given macOS release, using App External Version IDs.

## Platform Requirement

**macOS only.** This tool links against Apple's private `CommerceKit` and `StoreFoundation` frameworks, which are only present on macOS 10.13 (High Sierra) or later. It cannot be built or run on Linux or Windows.

## Build Commands

```bash
# Build release binary (.build/release/mas-legacyapps)
swift build --configuration release

# Or use the convenience scripts
script/build      # build only
script/install    # build + copy to /usr/local/bin
```

## Project Structure

```
Package.swift                          # Swift Package Manager manifest
Sources/
  mas-legacyapps/
    LegacyAppCatalog.swift             # App catalog: macOS versions + app IDs
    AppID.swift                        # App identity model
    AppRestore.swift                   # Core install/restore logic
    Downloader.swift                   # Download orchestration
    ISStoreAccount.swift               # App Store account interface
    MASError.swift                     # Error types
    PkgRescuer.swift                   # Gatekeeper rescue / .pkg extraction
    PurchaseDownloadObserver.swift     # Progress tracking
    SSPurchase.swift                   # Purchase request model
    Utilities.swift                    # Shared helpers
  PrivateFrameworks/                   # Header stubs for CommerceKit & StoreFoundation
script/
  build                                # Release build script
  install                              # Build + install to /usr/local/bin
```

## Dependencies

- **[swift-argument-parser](https://github.com/apple/swift-argument-parser)** >= 1.5.0 — CLI argument parsing
- **[PromiseKit](https://github.com/mxcl/PromiseKit)** >= 8.1.2 — async download chaining
- **CommerceKit** (private Apple framework) — App Store purchase & download
- **StoreFoundation** (private Apple framework) — App Store account & asset management

## Key Concepts

- **App External Version ID (`appExtVrsId`)**: An integer passed to the App Store daemon to request a specific historical app version instead of the current one.
- **Package rescue**: When Gatekeeper rejects an older app's `.pkg`, the tool rescues the file from the App Store cache and extracts it to `/Users/Shared/MASExtractedPkgs/`.
- **Log files**: Written to `~/.mas-legacyapps-<timestamp>.log` after each run.

## Adding New macOS Version Data

Edit `Sources/mas-legacyapps/LegacyAppCatalog.swift` and add a new `MacOSRelease` entry:

```swift
MacOSRelease(
    name: "Big Sur",
    shortName: "bigsur",
    displayVersion: "11.0",
    apps: [
        LegacyApp(name: "Keynote", appID: 409183694, appExtVrsId: <id>, version: "<ver>", category: .iWork, estimatedSizeGB: 0.3),
        // ...
    ]
),
```

Then rebuild with `swift build --configuration release`.

## Supported macOS Targets

| macOS Release   | Version | Pro Apps | iWork | Xcode |
|----------------|---------|----------|-------|-------|
| High Sierra    | 10.13   | 6        | 4     | —     |
| Mojave         | 10.14   | 6        | 4     | 11.3.1 |
| Catalina       | 10.15   | 6        | 4     | 12.4  |
| Monterey       | 12.0    | 6        | 4     | 14.2  |
