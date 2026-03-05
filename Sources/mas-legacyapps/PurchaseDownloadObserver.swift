//
//  PurchaseDownloadObserver.swift
//  mas
//
//  Copyright (c) 2015 Andrew Naylor. All rights reserved.
//
//  Modified by github.com/handyandy87 on 03/03/2026 07:51:00 PM CST.

import CommerceKit
import Foundation
import PromiseKit
import StoreFoundation

private let downloadingPhase = 0 as Int64
private let installingPhase = 1 as Int64
private let downloadedPhase = 5 as Int64

/// Observes App Store download queue events to provide three capabilities:
///
/// 1. **Version Lookup** (`lookupOnly`): When enabled, intercepts the CommerceKit metadata callback,
///    extracts the `bundleVersion`, prints it, cancels the download immediately, and fulfills without
///    downloading any bytes. Useful for resolving App External IDs to their version strings.
///    Fallback logic handles older App External IDs where `changedWithAddition` is skipped by CommerceKit.
///
/// 2. **Package Rescue + Extraction**: When an install fails after a successful download, automatically
///    stages the in-flight `.pkg` and `receipt` from the App Store cache to `/Users/Shared/MASExtractedPkgs`
///    and extracts them. Stages to `.staging/<app-id>/` during download, extracts to `<app-id>/<timestamp>/`
///    on install failure. Prompts user to optionally embed the receipt into the extracted app bundle.
///
/// 3. **Error Suppression for Successful Rescues**: If package rescue and extraction succeeds,
///    suppresses the downstream install error so the overall command completes successfully.
class PurchaseDownloadObserver: CKDownloadQueueObserver {
    private let purchase: SSPurchase
    private var completionHandler: (() -> Void)?
    private var errorHandler: ((MASError) -> Void)?
    private var priorPhaseType: Int64?

    /// Stages the in-flight `.pkg` and `receipt` to `/Users/Shared/MASExtractedPkgs` so we can extract it
    /// quickly if the install step fails after a download.
    private var pkgRescuer: PkgRescuer?

    /// Guard to avoid attempting rescue multiple times (we may see failure in both
    /// `statusChangedFor` and `changedWithRemoval`).
    private var didAttemptRescue = false

    /// If rescue/extraction succeeds, suppress the downstream install error.
    private var rescueSucceeded = false

    /// When true, cancel the download immediately after reading bundleVersion from metadata.
    /// Prints "==> Version lookup: <AppName> (<version>)" and fulfills without downloading anything.
    let lookupOnly: Bool

    init(purchase: SSPurchase, lookupOnly: Bool = false) {
        self.purchase = purchase
        self.lookupOnly = lookupOnly
    }

    deinit {
        // do nothing
    }

    // MARK: - Receipt embedding

    /// After a rescue extraction completes, optionally embed the receipt into the extracted app bundle.
    ///
    /// If the user answers "Y", copies the receipt (renamed to "receipt") into:
    ///   <App>.app/Contents/_MASReceipt/receipt
    private func promptToEmbedReceiptIfRequested(
        appURL: URL,
        extractedDirectory: URL,
        stagedReceipt: URL?,
        appID: UInt64
    ) {
        // Prefer the receipt we already copied into the output folder.
        let fm = FileManager.default
        let extractedReceipt = extractedDirectory.appendingPathComponent("\(appID)-receipt")
        let receiptSource: URL?
        if fm.fileExists(atPath: extractedReceipt.path) {
            receiptSource = extractedReceipt
        } else if let staged = stagedReceipt, fm.fileExists(atPath: staged.path) {
            receiptSource = staged
        } else {
            printWarning("No receipt file was found to embed into the app bundle.")
            return
        }

        // Don't prompt when stdin isn't interactive (e.g. piped/non-tty).
        guard isatty(fileno(stdin)) != 0 else {
            return
        }

        // Prompt the user.
        printInfo("Would you like to copy the Mac App Store receipt into the extracted app bundle? [Y/N]")
        print("Enter Y to copy the Mac App Store receipt into the app bundle, or N to skip: ", terminator: "")
        fflush(stdout)
        let response = (readLine(strippingNewline: true) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard response == "y" || response == "yes" else {
            return
        }

        // Copy receipt into app bundle.
        let destDir = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
        let destReceipt = destDir.appendingPathComponent("receipt")

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
            // Replace if present.
            _ = try? fm.removeItem(at: destReceipt)
            guard let src = receiptSource else { return }
            try fm.copyItem(at: src, to: destReceipt)
            printInfo("Receipt embedded at: \(destReceipt.path)")
        } catch {
            printError("Failed to embed receipt into app bundle: \(error.localizedDescription)")
        }
    }

    func downloadQueue(_ queue: CKDownloadQueue, statusChangedFor download: SSDownload) {
        guard
            download.metadata.itemIdentifier == purchase.itemIdentifier,
            let status = download.status
        else {
            return
        }

        // Lookup-only fallback: if changedWithAddition was skipped (can happen for old IDs),
        // intercept here on the first status update instead.
        if lookupOnly && !didAttemptRescue {
            didAttemptRescue = true  // reuse flag to ensure we only fire once
            let version = download.metadata.bundleVersion ?? "unknown"
            let title   = download.metadata.title ?? "unknown"
            printInfo("Version lookup: \(title) (\(version))")
            queue.removeDownload(withItemIdentifier: download.metadata.itemIdentifier)
            completionHandler?()
            return
        }

        // If we hit a failure state, attempt rescue immediately *before* removing the download.
        // In some cases, `changedWithRemoval` is invoked after status becomes nil, which would
        // prevent rescue from running there.
        if status.isFailed, !didAttemptRescue {
            didAttemptRescue = true
            pkgRescuer?.stopMonitoring()

            if let rescuer = pkgRescuer {
                clearLine()
                do {
                    printInfo("Install failed. Attempting to rescue and extract the downloaded package…")
                    let paths = try rescuer.rescueAndExtract(appName: download.metadata.title, bundleVersion: download.metadata.bundleVersion)
                    rescueSucceeded = true
                    printInfo("Rescue complete. Extracted to: \(paths.extractedDirectory.path)")
                    if let app = paths.extractedApp {
                        printInfo("Extracted app: \(app.path)")
                        printInfo("Copy the extracted app into /Applications to install it.")

                        // Offer to embed the receipt into the extracted app bundle.
                        // If the user chooses "Y", copy the receipt (renamed to "receipt") to:
                        // <App>.app/Contents/_MASReceipt/receipt
                        self.promptToEmbedReceiptIfRequested(
                            appURL: app,
                            extractedDirectory: paths.extractedDirectory,
                            stagedReceipt: paths.stagedReceipt,
                            appID: purchase.itemIdentifier
                        )

                        printInfo("Done. Remember to move the extracted app into /Applications.")
                    } else {
                        printInfo("No .app bundle was found in the extracted folder above.")
                        printInfo("Done. If an app bundle exists under the extracted folder, copy it into /Applications.")
                    }
                } catch {
                    printError("Package rescue failed: \(error.localizedDescription)")
                }
            }
        }

        if status.isFailed || status.isCancelled {
            queue.removeDownload(withItemIdentifier: download.metadata.itemIdentifier)
        } else {
            if priorPhaseType != status.activePhase.phaseType {
                switch status.activePhase.phaseType {
                case downloadedPhase:
                    if priorPhaseType == downloadingPhase {
                        clearLine()
                        printInfo("Downloaded \(download.progressDescription)")
                    }
                case installingPhase:
                    clearLine()
                    printInfo("Installing \(download.progressDescription)")
                default:
                    break
                }
                priorPhaseType = status.activePhase.phaseType
            }
            progress(status.progressState)
        }
    }

    func downloadQueue(_ queue: CKDownloadQueue, changedWithAddition download: SSDownload) {
        guard download.metadata.itemIdentifier == purchase.itemIdentifier else {
            return
        }

        // In lookup-only mode: print the version and immediately cancel — nothing is downloaded.
        if lookupOnly {
            let version = download.metadata.bundleVersion ?? "unknown"
            let title   = download.metadata.title ?? "unknown"
            printInfo("Version lookup: \(title) (\(version))")
            queue.removeDownload(withItemIdentifier: download.metadata.itemIdentifier)
            completionHandler?()
            return
        }

        // Start staging as soon as we know the download exists, so the `.pkg` is available
        // if the install step fails later.
        if pkgRescuer == nil {
            pkgRescuer = PkgRescuer(appID: purchase.itemIdentifier)
            pkgRescuer?.startMonitoring()
        }

        clearLine()
        printInfo("Downloading \(download.progressDescription)")
    }

    func downloadQueue(_: CKDownloadQueue, changedWithRemoval download: SSDownload) {
        guard download.metadata.itemIdentifier == purchase.itemIdentifier else {
            pkgRescuer?.stopMonitoring()
            pkgRescuer = nil
            return
        }

        let status = download.status

        pkgRescuer?.stopMonitoring()

        clearLine()
        if status?.isFailed == true {
            // If rescue already succeeded, treat this as success and suppress the original
            // install failure output.
            if rescueSucceeded {
                completionHandler?()
                pkgRescuer = nil
                didAttemptRescue = false
                rescueSucceeded = false
                return
            }

            // Any failure after a download attempt: try to rescue and extract the staged `.pkg`.
            // (The App Store cache file can disappear quickly once the system transitions.)
            if !didAttemptRescue, let rescuer = pkgRescuer {
                didAttemptRescue = true
                do {
                    printInfo("Install failed. Attempting to rescue and extract the downloaded package…")
                    let paths = try rescuer.rescueAndExtract(
                        appName: download.metadata.title,
                        bundleVersion: download.metadata.bundleVersion
                    )
                    rescueSucceeded = true
                    printInfo("Rescue complete. Extracted to: \(paths.extractedDirectory.path)")
                    if let app = paths.extractedApp {
                        printInfo("Extracted app: \(app.path)")
                        printInfo("Copy the extracted app into /Applications to install it.")

                        self.promptToEmbedReceiptIfRequested(
                            appURL: app,
                            extractedDirectory: paths.extractedDirectory,
                            stagedReceipt: paths.stagedReceipt,
                            appID: purchase.itemIdentifier
                        )

                        printInfo("Done. Remember to move the extracted app into /Applications.")
                    } else {
                        printInfo("No .app bundle was found in the extracted folder above.")
                        printInfo("Done. If an app bundle exists under the extracted folder, copy it into /Applications.")
                    }
                } catch {
                    // If rescue fails, continue with the original mas failure.
                    printError("Package rescue failed: \(error.localizedDescription)")
                }
            }

            // Suppress the default error output if rescue succeeded.
            if rescueSucceeded {
                completionHandler?()
            } else {
                errorHandler?(.downloadFailed(error: status?.error as NSError?))
            }
        } else if status?.isCancelled == true {
            // In lookup-only mode the cancellation is intentional — suppress the error.
            if lookupOnly {
                completionHandler?()
            } else {
                errorHandler?(.cancelled)
            }
        } else {
            printInfo("Installed \(download.progressDescription)")
            completionHandler?()
        }

        pkgRescuer = nil
        didAttemptRescue = false
        rescueSucceeded = false
    }
}

private struct ProgressState {
    let percentComplete: Float
    let phase: String

    var percentage: String {
        String(format: "%.1f%%", floor(percentComplete * 1000) / 10)
    }
}

private func progress(_ state: ProgressState) {
    // Don't display the progress bar if we're not on a terminal
    guard isatty(fileno(stdout)) != 0 else {
        return
    }

    let barLength = 60
    let completeLength = Int(state.percentComplete * Float(barLength))
    let bar = (0..<barLength).map { $0 < completeLength ? "#" : "-" }.joined()
    clearLine()
    print("\(bar) \(state.percentage) \(state.phase)", terminator: "")
    fflush(stdout)
}

private extension SSDownload {
    var progressDescription: String {
        let version = metadata.bundleVersion ?? "unknown version"
        return "\(metadata.title) (\(version))"
    }
}

private extension SSDownloadStatus {
    var progressState: ProgressState {
        ProgressState(percentComplete: percentComplete, phase: activePhase.phaseDescription)
    }
}

private extension SSDownloadPhase {
    var phaseDescription: String {
        switch phaseType {
        case downloadingPhase:
            return "Downloading"
        case installingPhase:
            return "Installing"
        default:
            return "Waiting"
        }
    }
}

extension PurchaseDownloadObserver {
    func observeDownloadQueue(_ downloadQueue: CKDownloadQueue = CKDownloadQueue.shared()) -> Promise<Void> {
        let observerID = downloadQueue.add(self)

        // Start monitoring immediately after we register as an observer.
        // Depending on timing, the download may already exist in the queue and
        // `changedWithAddition` may not be invoked for this observer.
        if pkgRescuer == nil {
            pkgRescuer = PkgRescuer(appID: purchase.itemIdentifier)
            pkgRescuer?.startMonitoring()
        }

        return Promise<Void> { seal in
            errorHandler = seal.reject
            completionHandler = seal.fulfill_
        }
        .ensure {
            self.pkgRescuer?.stopMonitoring()
            downloadQueue.remove(observerID)
        }
    }
}
