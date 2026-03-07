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
Package.swift                          # Swift Package Manager manifest (Swift 5.7.1, macOS 10.13+)
Sources/
  mas-legacyapps/
    AppRestore.swift                   # @main entry point; CLI options, interactive menus, install loop
    LegacyAppCatalog.swift             # Static catalog of macOS releases + per-app version IDs
    AppID.swift                        # AppID type alias (UInt64) + NSNumber extension
    Downloader.swift                   # Sequential download orchestration with retry logic
    ISStoreAccount.swift               # Async primary-account lookup via StoreFoundation
    MASError.swift                     # Typed error enum covering all failure scenarios
    PkgRescuer.swift                   # App Store cache poller, .pkg extractor, receipt staging
    PurchaseDownloadObserver.swift     # CKDownloadQueueObserver: progress, version lookup, rescue
    SSPurchase.swift                   # Builds and fires SSPurchase requests with appExtVrsId
    Utilities.swift                    # TTY-aware terminal output (printInfo/Warning/Error, clearLine)
  PrivateFrameworks/
    CommerceKit/                       # class-dump header stubs (7 files)
    StoreFoundation/                   # class-dump header stubs (14 files)
script/
  build                                # Runs: swift build --configuration release
  install                              # Builds + sudo-copies binary to /usr/local/bin
```

## Dependencies

- **[swift-argument-parser](https://github.com/apple/swift-argument-parser)** >= 1.5.0 — CLI argument parsing
- **[PromiseKit](https://github.com/mxcl/PromiseKit)** >= 8.1.2 — async download chaining
- **CommerceKit** (private Apple framework, `/System/Library/PrivateFrameworks`) — App Store purchase & download
- **StoreFoundation** (private Apple framework, `/System/Library/PrivateFrameworks`) — App Store account & asset management

Private frameworks are linked via `unsafeFlags` in Package.swift with `-I Sources/PrivateFrameworks/<name>` include paths and `-framework CommerceKit -framework StoreFoundation -F /System/Library/PrivateFrameworks` linker flags.

## Key Concepts

- **App External Version ID (`appExtVrsId`)**: An integer passed to the App Store daemon to request a specific historical app version instead of the current one. A value of `0` means "latest version".
- **Package rescue**: When Gatekeeper rejects an older app's `.pkg`, the tool rescues the file from the App Store cache (`~/Library/Caches/com.apple.AppStore/<appid>/`) and extracts it to `/Users/Shared/MASExtractedPkgs/<appid>/<timestamp>-<appname>/`.
- **Log files**: Written to `~/.mas-legacyapps-<timestamp>.log` after each run.
- **Lookup-only mode**: Download is cancelled immediately after reading version metadata from the queue — useful for resolving `appExtVrsId` values without transferring bytes.

## Supported macOS Targets

| macOS Release | shortName   | Version | iWork+iMovie | Pro Apps | Xcode  |
|---------------|-------------|---------|--------------|----------|--------|
| High Sierra   | highsierra  | 10.13   | 4            | 6        | —      |
| Mojave        | mojave      | 10.14   | 4            | 6        | 11.3.1 |
| Catalina      | catalina    | 10.15   | 4            | 6        | 12.4   |
| Monterey      | monterey    | 12.0    | 4            | 6        | 14.2   |

Apps within each release are ordered smallest-to-largest estimated download size to give users quick wins early in an install session.

## CLI Options (AppRestore.swift)

| Flag | Type | Default | Purpose |
|------|------|---------|---------|
| `--os <version>` | String? | nil (interactive) | Skip OS selection; use `shortName` from table above |
| `--category <type>` | String? | nil (interactive) | `pro`, `iwork`, or `all` |
| `--xcode` | Bool flag | false | Include Xcode without prompting |
| `--delay <seconds>` | Int | 15 | Rate-limit sleep between installs; `0` disables |
| `--all` | Bool flag | false | Skip per-app selection; install all filtered apps |
| `-y` / `--yes` | Bool flag | false | Skip final confirmation prompt |

Fully automated example:
```bash
mas-legacyapps --os monterey --category pro --all --yes --delay 0
```

## Execution Flow

```
AppRestore.run()
├─ printBanner()
├─ resolveRelease()          # --os flag or promptForRelease() menu
├─ printReleaseAppPreview()  # shows apps + sizes for selected OS
├─ resolveCategorySelection() # --category flag or promptForCategory() menu
├─ resolveXcode()            # --xcode flag, or interactive prompt (skipped with --all/--yes)
├─ applyFilter()             # filter apps by category
├─ promptForApps()           # per-app toggle menu (skipped with --all)
├─ confirmInstall()          # final confirmation (skipped with --yes)
├─ performInstalls()
│  └─ for each app (with --delay sleep between):
│     ├─ Downloader.downloadApps()
│     │  └─ SSPurchase.perform(appID:purchasing:appExtVrsId:lookupOnly:)
│     │     └─ CKPurchaseController.shared().perform()
│     │        └─ PurchaseDownloadObserver.observeDownloadQueue()
│     │           ├─ changedWithAddition → start PkgRescuer monitoring
│     │           ├─ statusChangedFor   → render progress bar
│     │           └─ changedWithRemoval → handle outcome / rescue / receipt embed
│     └─ record InstallOutcome (.installed / .skippedNotPurchased / .failed)
├─ printSummary()            # per-app results + counts
└─ writeLog()                # ~/.mas-legacyapps-<timestamp>.log
```

## Source File Responsibilities

### AppRestore.swift — Entry Point & UI
- `@main` ParsableCommand struct
- `CategorySelection` enum: `.pro`, `.iWork`, `.all`
- `InstallOutcome` enum: `.installed`, `.skippedNotPurchased`, `.failed`
- All interactive menus (numbered selection, per-app toggles)
- `performInstalls()` — sequential install loop with PromiseKit `.reduce` pattern
- `writeLog()` — timestamped log with final summary

### LegacyAppCatalog.swift — Static Data
- `AppCategory` enum: `.pro`, `.iWork`, `.xcode`
- `LegacyApp` struct: `name`, `appID: UInt64`, `appExtVrsId: Int`, `version`, `category`, `estimatedSizeGB`
- `MacOSRelease` struct: `name`, `shortName`, `displayVersion`, `apps: [LegacyApp]`
- Top-level `let catalog: [MacOSRelease]` — the canonical data source

### Downloader.swift — Sequential Downloads
- Public entry: `downloadApps(withAppIDs:purchasing:appExtVrsId:lookupOnly:)` — chains downloads via PromiseKit reduce
- Network retry logic: up to 3 attempts for `NSURLErrorDomain` failures; non-network errors fail immediately
- `appExtVrsId: 0` = latest version; any other value = specific historical version

### SSPurchase.swift — Purchase Request Construction
- Extends StoreFoundation's `SSPurchase` class
- Constructs `buyParameters` URL-encoded string: `productType=C&price=0&salableAdamId=<id>&appExtVrsId=<id>&pricingParameters=STDQ|STDRDL&...`
- **Monterey+ (macOS 12+)**: skips setting `accountIdentifier`/`appleID` (Apple privacy change)
- **Pre-Monterey**: fetches primary account via `ISStoreAccount.primaryAccount`

### PurchaseDownloadObserver.swift — Download Monitoring
Implements `CKDownloadQueueObserver`. Three integrated capabilities:

1. **Progress display**: renders `[####----] 45.3% Downloading` progress bar (TTY-aware)
2. **Version lookup** (`lookupOnly=true`): intercepts `changedWithAddition`, reads `bundleVersion` from metadata, then immediately cancels — no bytes transferred
3. **Package rescue**: on install failure, delegates to `PkgRescuer`; suppresses upstream error if rescue succeeds; optionally prompts user to embed receipt into extracted `.app/Contents/_MASReceipt/receipt`

Phase constants: `downloadingPhase=0`, `installingPhase=1`, `downloadedPhase=5`

### PkgRescuer.swift — Cache Polling & Extraction
- Polls `~/Library/Caches/com.apple.AppStore/<appid>/` every 100ms (up to 60s) via `DispatchSourceTimer`
- Stages `.pkg` + receipt via hard-link (or copy fallback) to `/Users/Shared/MASExtractedPkgs/.staging/<appid>/`
- `rescueAndExtract()` runs `/usr/bin/xar -xf <pkg> -C <tmpdir>` then `/usr/bin/ditto -x Payload <outdir>`
- Output: `/Users/Shared/MASExtractedPkgs/<appid>/<yyyyMMdd-HHmmss>-<appname>/`
- `StagedPaths` struct holds all relevant path URLs

### ISStoreAccount.swift — Account Lookup
- `static var primaryAccount: Promise<ISStoreAccount>` — 30-second timeout race via `ISServiceProxy.genericShared().accountService.primaryAccount()`
- `signIn()` intentionally unsupported — App Store sign-in via private API was removed in High Sierra

### MASError.swift — Typed Errors
Key cases: `.notSignedIn`, `.purchaseFailed(error:)`, `.downloadFailed(error:)`, `.cancelled`, `.unknownAppID(AppID)`, `.notSupported`
Implements `Error`, `Equatable`, `CustomStringConvertible`.

### Utilities.swift — Terminal Output
- `printInfo(_:)` — stdout with blue bold `==>` prefix
- `printWarning(_:)` — stderr with yellow underlined `Warning:` prefix
- `printError(_:)` — stderr with red underlined `Error:` prefix
- `clearLine()` — overwrites current line (TTY only)
- All functions use `isatty()` to detect TTY; non-TTY output is plain text

### AppID.swift
- `typealias AppID = UInt64`
- `extension NSNumber { var appIDValue: AppID }` — extracts `uint64Value`

## Private Framework Headers

Header stubs in `Sources/PrivateFrameworks/` were generated with `class-dump` and must not be edited manually. They expose Objective-C interfaces to Swift via the SPM include-path compiler flags.

**CommerceKit** (7 headers): `CKDownloadQueue`, `CKDownloadQueueObserver`, `CKPurchaseController`, `CKDownloadDirectory`, `CKAccountStore`, `CKServiceInterface`, `CKSoftwareMap`

**StoreFoundation** (14 headers): `SSPurchase`, `SSPurchaseResponse`, `SSDownload`, `SSDownloadMetadata`, `SSDownloadStatus`, `SSDownloadPhase`, `ISStoreAccount`, `ISAccountService`, `ISServiceProxy`, `ISAuthenticationContext`, `ISAuthenticationResponse`, `ISServiceRemoteObject`, `ISStoreClient`, `CKSoftwareProduct`, `CKUpdate`

## Adding New macOS Version Data

Edit `Sources/mas-legacyapps/LegacyAppCatalog.swift` and add a new `MacOSRelease` entry to the `catalog` array:

```swift
MacOSRelease(
    name: "Big Sur",
    shortName: "bigsur",       // used for --os flag; lowercase, no spaces
    displayVersion: "11.0",
    apps: [
        // Order apps smallest-to-largest by estimatedSizeGB
        LegacyApp(name: "Keynote", appID: 409183694, appExtVrsId: <id>, version: "<ver>", category: .iWork, estimatedSizeGB: 0.3),
        LegacyApp(name: "Xcode",   appID: 497799835, appExtVrsId: <id>, version: "12.5.1", category: .xcode, estimatedSizeGB: 11.0),
        // ...
    ]
),
```

Obtain `appExtVrsId` values by running the tool in lookup-only mode or by inspecting App Store purchase responses for the target version. Then rebuild with `swift build --configuration release`.

## Testing

There is no automated test suite. Manual testing requires a macOS machine with the relevant apps purchased on the signed-in Apple ID. Validate changes by:

1. Running with `--os <target> --category all --all --yes --delay 0` in a clean environment
2. Verifying the interactive menus render correctly in terminal
3. Checking log output in `~/.mas-legacyapps-*.log`
