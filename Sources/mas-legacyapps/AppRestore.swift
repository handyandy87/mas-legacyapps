//
//  AppRestore.swift
//  mas-legacyapps
//
//  Adapted from mas-cli-appExtVrsId-patcher by github.com/handyandy87.
//  Original mas-cli Copyright © 2015 Andrew Naylor. All rights reserved.
//

import ArgumentParser
import Foundation
import PromiseKit

/// Entry point for mas-legacyapps.
///
/// Interactively installs the last compatible versions of Apple Pro and
/// productivity apps for a chosen macOS release, using App External Version
/// IDs from https://github.com/handyandy87/Pro-Apps-App-External-IDs.
@main
struct AppRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mas-legacyapps",
        abstract: "Install last-compatible Apple Pro & productivity apps for a macOS release",
        discussion: """
        Presents a menu to select a macOS release and an app category, then
        installs the last compatible version of each app from the App Store.

        App categories:
          pro    — Final Cut Pro, Compressor, Motion, Logic Pro, MainStage, GarageBand
          iwork  — Keynote, Numbers, Pages, iMovie
          all    — Both groups above

        Xcode is always offered as a separate optional install because of its size.

        Apps not in your purchase history are skipped automatically with a message.
        If the App Store install step fails after a successful download, the .pkg is
        rescued and extracted to /Users/Shared/MASExtractedPkgs/.

        Currently covers: High Sierra (10.13), Mojave (10.14), Catalina (10.15), Monterey (12).
        Big Sur, Ventura, Sonoma, and Sequoia data is not yet available.

        Examples:
          mas-legacyapps                                      # fully interactive
          mas-legacyapps --os catalina                        # skip OS selection
          mas-legacyapps --os monterey --category pro         # skip OS + category
          mas-legacyapps --os mojave --category all --xcode --all --yes  # automated
          mas-legacyapps --delay 30                           # 30-second inter-app delay
        """
    )

    @Option(
        name: .customLong("os"),
        help: "macOS version to target, e.g. 'monterey', 'catalina'. Skips the interactive OS menu."
    )
    var targetOS: String?

    @Option(
        name: .customLong("category"),
        help: "App category: 'pro', 'iwork', or 'all'. Skips the interactive category menu."
    )
    var targetCategory: String?

    @Flag(
        name: .customLong("xcode"),
        help: "Include Xcode without prompting. Only relevant when Xcode is available for the selected OS."
    )
    var includeXcode = false

    @Option(
        name: .customLong("delay"),
        help: "Seconds to wait between app installs to avoid Apple's rate limiter (default: 15, use 0 to disable)."
    )
    var delay: Int = 15

    @Flag(
        name: .customLong("all"),
        help: "Skip the per-app toggle menu and install everything in the selected category."
    )
    var installAll = false

    @Flag(
        name: [.customShort("y"), .customLong("yes")],
        help: "Skip the final confirmation prompt. Useful for unattended or scripted runs."
    )
    var skipConfirmation = false

    // MARK: - PromiseKit setup

    func validate() throws {
        PromiseKit.conf.Q.map = .global()
        PromiseKit.conf.Q.return = .global()
        PromiseKit.conf.logHandler = { event in
            switch event {
            case .waitOnMainThread:
                // Expected: this is a console app that blocks the main thread while
                // PromiseKit resolves on the global DispatchQueue.
                break
            default:
                fatalError("PromiseKit event: \(event)")
            }
        }
    }

    // MARK: - Category model

    private enum CategorySelection {
        case pro, iWork, all

        var displayName: String {
            switch self {
            case .pro:   return "Pro Apps"
            case .iWork: return "iWork & Media"
            case .all:   return "All"
            }
        }

        var appSummary: String {
            switch self {
            case .pro:   return "Final Cut Pro, Compressor, Motion, Logic Pro, MainStage, GarageBand"
            case .iWork: return "Keynote, Numbers, Pages, iMovie"
            case .all:   return "Pro Apps + iWork & Media"
            }
        }

        func matches(_ category: AppCategory) -> Bool {
            switch self {
            case .pro:   return category == .pro
            case .iWork: return category == .iWork
            case .all:   return category == .pro || category == .iWork
            }
        }
    }

    // MARK: - Entry point

    func run() throws {
        printBanner()

        let release = try resolveRelease()
        printReleaseAppPreview(release)
        let categorySelection = try resolveCategorySelection(for: release)
        let xcodeIncluded = try resolveXcode(for: release)
        let candidateApps = applyFilter(release.apps, category: categorySelection, includeXcode: xcodeIncluded)

        guard !candidateApps.isEmpty else {
            printInfo("No apps match the selected options. Exiting.")
            return
        }

        let selectedApps = installAll ? candidateApps : try promptForApps(candidateApps, release: release)

        guard !selectedApps.isEmpty else {
            printInfo("No apps selected. Exiting.")
            return
        }

        if !skipConfirmation {
            try confirmInstall(apps: selectedApps, release: release)
        }

        let outcomes = performInstalls(apps: selectedApps)
        printSummary(outcomes: outcomes, release: release)
        writeLog(outcomes: outcomes, release: release)
    }

    // MARK: - Release selection

    private func resolveRelease() throws -> MacOSRelease {
        guard let targetOS else {
            return try promptForRelease()
        }

        let key = targetOS.lowercased().replacingOccurrences(of: " ", with: "")
        guard let match = LegacyAppCatalog.releases.first(where: { $0.shortName == key }) else {
            let valid = LegacyAppCatalog.releases.map { "'\($0.shortName)'" }.joined(separator: ", ")
            throw MASError.runtimeError("Unknown macOS version '\(targetOS)'. Valid options: \(valid)")
        }

        printInfo("Targeting \(match.name) (\(match.displayVersion))")
        return match
    }

    private func promptForRelease() throws -> MacOSRelease {
        print("Select a macOS version:\n")

        for (index, release) in LegacyAppCatalog.releases.enumerated() {
            let num = "\(index + 1).".padding(toLength: 4, withPad: " ", startingAt: 0)
            let displayName = "\(release.name) (\(release.displayVersion))"
                .padding(toLength: 24, withPad: " ", startingAt: 0)
            let xcodeNote = release.hasXcode ? " + Xcode" : ""
            let proCount = release.apps.filter { $0.category == .pro }.count
            let iWorkCount = release.apps.filter { $0.category == .iWork }.count
            print("  \(num)  \(displayName)  \(proCount) Pro, \(iWorkCount) iWork\(xcodeNote)")
        }

        print()

        while true {
            print("Enter a number (or 'q' to quit): ", terminator: "")
            fflush(stdout)

            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)

            if raw.lowercased() == "q" {
                throw MASError.runtimeError("Cancelled by user.")
            }
            if let choice = Int(raw), choice >= 1, choice <= LegacyAppCatalog.releases.count {
                return LegacyAppCatalog.releases[choice - 1]
            }

            print("  Please enter a number from 1 to \(LegacyAppCatalog.releases.count).\n")
        }
    }

    // MARK: - Release app preview

    private func printReleaseAppPreview(_ release: MacOSRelease) {
        let proApps   = release.apps.filter { $0.category == .pro }
        let iWorkApps = release.apps.filter { $0.category == .iWork }
        let xcodeApp  = release.apps.first  { $0.category == .xcode }

        print()
        print("  Apps available for \(release.name) (\(release.displayVersion)):")
        print()

        if !proApps.isEmpty {
            print("  Pro Apps:")
            for app in proApps {
                let name = app.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("    \(name)  \(app.version)")
            }
            print()
        }

        if !iWorkApps.isEmpty {
            print("  iWork & Media:")
            for app in iWorkApps {
                let name = app.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("    \(name)  \(app.version)")
            }
            print()
        }

        if let xcode = xcodeApp {
            print("  Xcode:  \(xcode.version)  (~\(String(format: "%.0f", xcode.estimatedSizeGB)) GB, offered separately)")
            print()
        }
    }

    // MARK: - Category selection

    private func resolveCategorySelection(for release: MacOSRelease) throws -> CategorySelection {
        if let targetCategory {
            switch targetCategory.lowercased() {
            case "pro":   return .pro
            case "iwork": return .iWork
            case "all":   return .all
            default:
                throw MASError.runtimeError(
                    "Unknown category '\(targetCategory)'. Valid options: 'pro', 'iwork', 'all'."
                )
            }
        }

        return try promptForCategory(release: release)
    }

    private func promptForCategory(release: MacOSRelease) throws -> CategorySelection {
        let allOptions: [CategorySelection] = [.pro, .iWork, .all]

        print()
        print("What would you like to install for \(release.name) (\(release.displayVersion))?\n")

        for (index, option) in allOptions.enumerated() {
            let num = "\(index + 1).".padding(toLength: 4, withPad: " ", startingAt: 0)
            let label = option.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("  \(num)  \(label)  \(option.appSummary)")
        }

        print()
        print("  (Xcode will be offered separately regardless of your choice.)")
        print()

        while true {
            print("Enter a number (or 'q' to quit): ", terminator: "")
            fflush(stdout)

            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)

            if raw.lowercased() == "q" {
                throw MASError.runtimeError("Cancelled by user.")
            }
            if let choice = Int(raw), choice >= 1, choice <= allOptions.count {
                let selected = allOptions[choice - 1]
                printInfo("Category: \(selected.displayName)")
                return selected
            }

            print("  Please enter a number from 1 to \(allOptions.count).\n")
        }
    }

    // MARK: - Xcode selection

    private func resolveXcode(for release: MacOSRelease) throws -> Bool {
        guard release.hasXcode else { return false }

        if includeXcode { return true }
        // In automated mode (--yes), don't include Xcode unless --xcode was explicit.
        if skipConfirmation { return false }

        guard let xcodeEntry = release.apps.first(where: { $0.category == .xcode }) else {
            return false
        }

        print()
        print("Xcode \(xcodeEntry.version) is available (~\(String(format: "%.0f", xcodeEntry.estimatedSizeGB)) GB).")
        print("Include it? [y/N]: ", terminator: "")
        fflush(stdout)

        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    // MARK: - App filtering

    private func applyFilter(_ apps: [LegacyApp], category: CategorySelection, includeXcode: Bool) -> [LegacyApp] {
        apps.filter { app in
            if app.category == .xcode { return includeXcode }
            return category.matches(app.category)
        }
    }

    // MARK: - Per-app toggle

    private func promptForApps(_ candidates: [LegacyApp], release: MacOSRelease) throws -> [LegacyApp] {
        var deselected = Set<Int>()

        while true {
            printAppTable(candidates, release: release, deselected: deselected)

            print("  Enter a number to toggle on/off, 'a' for all, Enter to proceed, 'q' to quit")
            print()
            print("  > ", terminator: "")
            fflush(stdout)

            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)

            switch raw.lowercased() {
            case "":
                return candidates.enumerated()
                    .filter { !deselected.contains($0.offset) }
                    .map { $0.element }
            case "q":
                throw MASError.runtimeError("Cancelled by user.")
            case "a":
                deselected.removeAll()
            default:
                if let num = Int(raw), num >= 1, num <= candidates.count {
                    let idx = num - 1
                    if deselected.contains(idx) {
                        deselected.remove(idx)
                    } else {
                        deselected.insert(idx)
                    }
                } else {
                    print("  Invalid input — enter a number, 'a', Enter, or 'q'.\n")
                }
            }
        }
    }

    private func printAppTable(_ candidates: [LegacyApp], release: MacOSRelease, deselected: Set<Int>) {
        let selectedCount = candidates.count - deselected.count
        let totalGB = candidates.enumerated()
            .filter { !deselected.contains($0.offset) }
            .reduce(0.0) { $0 + $1.element.estimatedSizeGB }

        print()
        print("  \(release.name) (\(release.displayVersion)) — \(selectedCount)/\(candidates.count) selected  •  ~\(String(format: "%.1f", totalGB)) GB")
        print()
        print("  #    On    \("App".padding(toLength: 16, withPad: " ", startingAt: 0))  \("Version".padding(toLength: 10, withPad: " ", startingAt: 0))  Size")
        print("  \(String(repeating: "─", count: 56))")

        var lastCategory: AppCategory?
        for (idx, app) in candidates.enumerated() {
            if let last = lastCategory, last != app.category {
                print()
            }
            lastCategory = app.category

            let toggle = deselected.contains(idx) ? "[ ]" : "[✓]"
            let numStr = "\(idx + 1)".padding(toLength: 4, withPad: " ", startingAt: 0)
            let name = app.name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let version = app.version.padding(toLength: 10, withPad: " ", startingAt: 0)
            let size = String(format: "~%.1f GB", app.estimatedSizeGB)
            print("  \(numStr) \(toggle)  \(name)  \(version)  \(size)")
        }

        print()
    }

    // MARK: - Confirmation

    private func confirmInstall(apps: [LegacyApp], release: MacOSRelease) throws {
        let totalGB = apps.reduce(0.0) { $0 + $1.estimatedSizeGB }

        print()
        print("Ready to install \(apps.count) app\(apps.count == 1 ? "" : "s") for \(release.name) (\(release.displayVersion)).")
        print()
        print("  • Estimated download         ~\(String(format: "%.1f", totalGB)) GB")
        print("  • Delay between apps         \(delay > 0 ? "\(delay)s (rate limit protection)" : "none")")
        print("  • Apps not purchased         skipped with a message")
        print("  • Install failures           .pkg rescued → /Users/Shared/MASExtractedPkgs/")
        print()
        print("Proceed? [Y/n]: ", terminator: "")
        fflush(stdout)

        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer.isEmpty || answer == "y" || answer == "yes" else {
            throw MASError.runtimeError("Aborted by user.")
        }
    }

    // MARK: - Install loop

    private enum InstallOutcome {
        case installed
        case skippedNotPurchased(String)
        case failed(String)
    }

    private struct AppOutcome {
        let app: LegacyApp
        let outcome: InstallOutcome
    }

    private func performInstalls(apps: [LegacyApp]) -> [AppOutcome] {
        var results: [AppOutcome] = []

        for (index, app) in apps.enumerated() {
            print()
            print(String(repeating: "━", count: 66))
            printInfo("[\(index + 1)/\(apps.count)] \(app.name)  \(app.version)")

            do {
                try downloadApps(
                    withAppIDs: [app.appID],
                    purchasing: false,
                    appExtVrsId: app.appExtVrsId
                ).wait()
                results.append(AppOutcome(app: app, outcome: .installed))
            } catch let error as MASError {
                print()
                switch error {
                case .purchaseFailed:
                    printWarning("\(app.name) — not in purchase history, skipping.")
                    results.append(AppOutcome(app: app, outcome: .skippedNotPurchased(error.description)))
                default:
                    printError("Could not install \(app.name): \(error.description)")
                    results.append(AppOutcome(app: app, outcome: .failed(error.description)))
                }
            } catch {
                print()
                printError("Could not install \(app.name): \(error.localizedDescription)")
                results.append(AppOutcome(app: app, outcome: .failed(error.localizedDescription)))
            }

            if index < apps.count - 1 && delay > 0 {
                print()
                printInfo("Waiting \(delay)s before next install…")
                Thread.sleep(forTimeInterval: Double(delay))
            }
        }

        return results
    }

    // MARK: - Summary

    private func printSummary(outcomes: [AppOutcome], release: MacOSRelease) {
        var installedCount = 0
        var skippedCount = 0
        var failedCount = 0

        print()
        print(String(repeating: "━", count: 66))
        printInfo("Restore Summary — \(release.name) (\(release.displayVersion))")
        print(String(repeating: "━", count: 66))
        print()

        for entry in outcomes {
            let name = entry.app.name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let version = entry.app.version.padding(toLength: 10, withPad: " ", startingAt: 0)

            switch entry.outcome {
            case .installed:
                print("  ✓  \(name)  \(version)  Installed")
                installedCount += 1
            case .skippedNotPurchased:
                print("  ↷  \(name)  \(version)  Not purchased — skipped")
                skippedCount += 1
            case .failed(let message):
                print("  ✗  \(name)  \(version)  Failed")
                print("       └─ \(message)")
                failedCount += 1
            }
        }

        print()
        print("  \(installedCount) installed  •  \(skippedCount) skipped (not purchased)  •  \(failedCount) failed")

        if failedCount > 0 {
            print()
            print("  Apps that failed to install may have been extracted instead.")
            print("  Check /Users/Shared/MASExtractedPkgs/ for rescued packages.")
            print()
            print("  If Gatekeeper blocks an extracted app, run:")
            print("    xattr -cr \"/path/to/App.app\"")
            print("  then right-click the .app and choose Open.")
        }

        print()
    }

    // MARK: - Log file

    private func writeLog(outcomes: [AppOutcome], release: MacOSRelease) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        var lines: [String] = [
            "mas-legacyapps Restore Log",
            "Generated : \(Date())",
            "macOS     : \(release.name) (\(release.displayVersion))",
            "",
        ]

        for entry in outcomes {
            let status: String
            switch entry.outcome {
            case .installed:
                status = "INSTALLED"
            case .skippedNotPurchased(let detail):
                status = "SKIPPED (not purchased) — \(detail)"
            case .failed(let message):
                status = "FAILED — \(message)"
            }
            lines.append("\(entry.app.name) \(entry.app.version)  →  \(status)")
        }

        let logContent = lines.joined(separator: "\n") + "\n"
        let logPath = NSString(string: "~/.mas-legacyapps-\(timestamp).log").expandingTildeInPath

        do {
            try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)
            print()
            printInfo("Log saved: \(logPath)")
        } catch {
            printWarning("Could not write log file: \(error.localizedDescription)")
        }
    }

    // MARK: - Banner

    private func printBanner() {
        print("""
        ╔═══════════════════════════════════════════════════════════════════╗
        ║         mas-legacyapps — Apple Pro & Productivity Apps            ║
        ╚═══════════════════════════════════════════════════════════════════╝

        Installs the last compatible version of Apple's Pro and productivity
        apps for a selected macOS release.

        Apps not in your purchase history are skipped with a clear message.
        If an install fails after downloading, the .pkg is automatically
        rescued and extracted to /Users/Shared/MASExtractedPkgs/.

        Note: Currently covers High Sierra → Monterey only.
        """)
    }
}
