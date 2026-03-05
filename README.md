# mas-legacyapps

A command-line tool for macOS that interactively installs the **last compatible version** of Apple's Pro and productivity apps for a given macOS release, using App External Version IDs bundled in this repository.

## What it does

Running `mas-legacyapps` walks you through three short menus, then downloads and installs each app automatically:

1. **Select a macOS release** — High Sierra, Mojave, Catalina, or Monterey
2. **Select a category** — Pro Apps, iWork & Media, or All
3. **Optionally include Xcode** — offered separately because of its size (7–12 GB)
4. **Toggle individual apps** on/off if you want a subset
5. **Confirm** and watch the installs run one by one

Apps you haven't purchased are automatically skipped with a clear message. If the App Store install step fails after a successful download (common with older app versions due to Gatekeeper), the `.pkg` is automatically rescued and extracted to `/Users/Shared/MASExtractedPkgs/`.

A log file is written to `~/.mas-legacyapps-<timestamp>.log` after each run.

### Example session

```
╔═══════════════════════════════════════════════════════════════════╗
║         mas-legacyapps — Apple Pro & Productivity Apps            ║
╚═══════════════════════════════════════════════════════════════════╝

Select a macOS version:

  1.    High Sierra (10.13)         10 Pro, 4 iWork
  2.    Mojave (10.14)              10 Pro, 4 iWork + Xcode
  3.    Catalina (10.15)            10 Pro, 4 iWork + Xcode
  4.    Monterey (12.0)             10 Pro, 4 iWork + Xcode

Enter a number (or 'q' to quit): 3

What would you like to install for Catalina (10.15)?

  1.    Pro Apps            Final Cut Pro, Compressor, Motion, Logic Pro, MainStage, GarageBand
  2.    iWork & Media       Keynote, Numbers, Pages, iMovie
  3.    All                 Pro Apps + iWork & Media

  (Xcode will be offered separately regardless of your choice.)

Enter a number (or 'q' to quit): 3

Xcode 12.4 is available (~11 GB).
Include it? [y/N]: n

  Catalina (10.15) — 10/10 selected  •  ~11.6 GB
  ...
  [✓] Keynote  11.1  ~0.3 GB
  ...

Proceed? [Y/n]: y

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
==> [1/10] Keynote  11.1
==> Downloading Keynote (11.1)
...
```

---

## Requirements

- **macOS 10.13 (High Sierra) or later** — the tool links against Apple's private `CommerceKit` and `StoreFoundation` frameworks, which are only present on macOS.
- **Signed into the Mac App Store** — open the App Store app and sign in with your Apple ID before running.
- **Apps must be purchased** under your Apple ID — apps you've never bought will be skipped.
- **Xcode Command Line Tools** — needed to build the tool (`xcode-select --install`).

---

## Installation

### Build from source

```bash
# Clone this repo
git clone https://github.com/handyandy87/mas-legacyapps.git
cd mas-legacyapps

# Build (release binary goes to .build/release/mas-legacyapps)
swift build --configuration release

# Optionally install to /usr/local/bin so it's on your PATH
sudo cp .build/release/mas-legacyapps /usr/local/bin/
```

Or use the convenience script:

```bash
script/build          # build only
script/install        # build + copy to /usr/local/bin
```

### Verify the install

```bash
mas-legacyapps --help
```

---

## Usage

### Fully interactive (recommended for first-time users)

```bash
mas-legacyapps
```

Walk through the menus for OS, category, Xcode, and app selection.

### Skip the OS selection menu

```bash
mas-legacyapps --os catalina
mas-legacyapps --os monterey
mas-legacyapps --os mojave
mas-legacyapps --os highsierra
```

### Skip the category menu

```bash
mas-legacyapps --os monterey --category pro
mas-legacyapps --os catalina --category iwork
mas-legacyapps --os mojave   --category all
```

### Include Xcode without being prompted

```bash
mas-legacyapps --os catalina --category all --xcode
```

### Skip the per-app toggle and install everything

```bash
mas-legacyapps --os monterey --category pro --all
```

### Fully automated (no prompts at all)

```bash
# Install all Pro Apps for Catalina, no delays between apps, no prompts
mas-legacyapps --os catalina --category pro --all --yes --delay 0

# Install everything for Monterey including Xcode
mas-legacyapps --os monterey --category all --xcode --all --yes
```

> **Note:** In automated mode (`--yes`), Xcode is only included when `--xcode` is explicitly passed. This prevents accidentally queuing a 12 GB download in scripts.

### Adjust the rate-limit delay

Apple's servers can throttle rapid sequential downloads. The default delay between apps is **15 seconds**. Adjust with `--delay`:

```bash
mas-legacyapps --delay 30   # 30 seconds between apps
mas-legacyapps --delay 0    # no delay (use only for 1–2 apps)
```

---

## App coverage

| macOS Release | Version | Pro Apps | iWork & Media | Xcode |
|---|---|---|---|---|
| High Sierra | 10.13 | FCP 10.4.6, Compressor 4.4.4, Motion 5.4.3, Logic Pro 10.4.8, MainStage 3.4.4, GarageBand 10.3.5 | Keynote 9.1, Numbers 6.1, Pages 8.1, iMovie 10.1.12 | — |
| Mojave | 10.14 | FCP 10.4.10, Compressor 4.4.8, Motion 5.4.7, Logic Pro 10.5.1, MainStage 3.4.4, GarageBand 10.3.5 | Keynote 10.1, Numbers 10.1, Pages 10.1, iMovie 10.1.14 | 11.3.1 |
| Catalina | 10.15 | FCP 10.5.4, Compressor 4.5.4, Motion 5.5.3, Logic Pro 10.6.3, MainStage 3.5.3, GarageBand 10.3.5 | Keynote 11.1, Numbers 11.1, Pages 11.1, iMovie 10.2.5 | 12.4 |
| Monterey | 12.0 | FCP 10.6.8, Compressor 4.6.5, Motion 5.6.5, Logic Pro 10.7.9, MainStage 3.6.4, GarageBand 10.4.8 | Keynote 13.1, Numbers 13.1, Pages 13.1, iMovie 10.3.8 | 14.2 |

> Big Sur (11), Ventura (13), Sonoma (14), and Sequoia (15) data is not yet available.
> Contributions welcome — see the App External IDs tables in this repository.

---

## Package rescue and Gatekeeper

Older app versions frequently fail at the **install** step even after a successful download, because Gatekeeper rejects the signature on the app's `.pkg`. When this happens, `mas-legacyapps` automatically:

1. Rescues the `.pkg` from the App Store cache before it disappears
2. Extracts it to `/Users/Shared/MASExtractedPkgs/<appID>/<timestamp>-<AppName>/`
3. Offers to embed the App Store receipt into the extracted `.app` bundle (interactive only)

After extraction, copy the `.app` to `/Applications`. If macOS still blocks it, run:

```bash
xattr -cr "/Applications/Final Cut Pro.app"
```

then right-click the `.app` and choose **Open**.

---

## Log files

A log is written to `~/.mas-legacyapps-<timestamp>.log` after each run, recording which apps were installed, skipped (not purchased), or failed.

---

## How the version IDs work

Each entry in `LegacyAppCatalog.swift` uses an **App External Version ID** (`appExtVrsId`) — an integer that Apple's App Store daemon uses to select a specific historical version of an app. These IDs were collected and catalogued in this repository.

The IDs are passed as a query parameter in the App Store purchase request, causing the daemon to download that exact version instead of the current one.

The IDs are catalogued in `Sources/mas-legacyapps/LegacyAppCatalog.swift`. See the project README for the full dataset and guidance on finding missing IDs.

---

## Updating the catalog

To add support for a new macOS version, update `Sources/mas-legacyapps/LegacyAppCatalog.swift` with the new entries:

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

Then rebuild: `swift build --configuration release`.

---

## Credits

- **[mas-cli](https://github.com/mas-cli/mas)** — the upstream Mac App Store command-line tool this is built on
- **[mas-cli-appExtVrsId-patcher](https://github.com/handyandy87/mas-cli-appExtVrsId-patcher)** — the patched fork adding `--ver`, `--lookup`, and package rescue
---

## Disclaimer

This tool interacts with Apple's private `CommerceKit` and `StoreFoundation` frameworks. It only installs apps you have legitimately purchased from the Mac App Store. Use responsibly.
