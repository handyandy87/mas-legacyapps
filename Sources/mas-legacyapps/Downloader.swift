//
//  Downloader.swift
//  mas
//
//  Copyright (c) 2015 Andrew Naylor. All rights reserved.
//
//  Modified by github.com/handyandy87 on 03/03/2026 07:51:00 PM CST.

import CommerceKit
import PromiseKit
import StoreFoundation

/// Sequentially downloads apps, printing progress to the console.
///
/// - Parameters:
///   - appIDs: The app IDs of the apps to be downloaded.
///   - purchasing: Flag indicating if the apps will be purchased. Only works for free apps. Defaults to false.
///   - appExtVrsId: App External Version ID to request a specific historical version (0 = latest). Passed through to the purchase/download flow.
///   - lookupOnly: When true, resolve the App External Version ID to its version string without downloading. Skips retry logic for lookup failures.
/// - Returns: A promise that completes when the downloads are complete. If any fail,
///   the promise is rejected with the first error, after all remaining downloads are attempted.
func downloadApps(withAppIDs appIDs: [AppID], purchasing: Bool = false, appExtVrsId: Int = 0, lookupOnly: Bool = false) -> Promise<Void> {
    var firstError: Error?
    return
        appIDs
        .reduce(Guarantee.value(())) { previous, appID in
            previous.then {
                downloadApp(withAppID: appID, purchasing: purchasing, appExtVrsId: appExtVrsId, lookupOnly: lookupOnly)
                    .recover { error in
                        if firstError == nil {
                            firstError = error
                        }
                    }
            }
        }
        .done {
            if let firstError {
                throw firstError
            }
        }
}

/// Downloads a single app with optional version override and lookup-only mode.
///
/// - Parameters:
///   - appID: The App Store item ID.
///   - purchasing: Whether this is a "purchase" (free app install confirmation) or a standard redownload.
///   - appExtVrsId: App External Version ID to request a specific historical version (0 = latest).
///   - lookupOnly: When true, cancels the download immediately after reading metadata without downloading bytes.
///   - attemptCount: Number of retry attempts for network failures. Skipped entirely in lookup-only mode.
/// - Returns: A Promise that fulfills when the download completes (or is cancelled in lookup-only mode).
private func downloadApp(
    withAppID appID: AppID,
    purchasing: Bool = false,
    appExtVrsId: Int = 0,
    lookupOnly: Bool = false,
    withAttemptCount attemptCount: UInt32 = 3
) -> Promise<Void> {
    SSPurchase()
        .perform(appID: appID, purchasing: purchasing, appExtVrsId: appExtVrsId, lookupOnly: lookupOnly)
        .recover { error in
            // In lookup-only mode don't retry — just surface the error.
            guard !lookupOnly else { throw error }
            guard attemptCount > 1 else {
                throw error
            }

            // If the download failed due to network issues, try again. Otherwise, fail immediately.
            guard
                case MASError.downloadFailed(let downloadError) = error,
                case NSURLErrorDomain = downloadError?.domain
            else {
                throw error
            }

            let attemptCount = attemptCount - 1
            printWarning((downloadError ?? error).localizedDescription)
            printWarning("Trying again up to \(attemptCount) more \(attemptCount == 1 ? "time" : "times").")
            return downloadApp(withAppID: appID, purchasing: purchasing, appExtVrsId: appExtVrsId, lookupOnly: lookupOnly, withAttemptCount: attemptCount)
        }
}
