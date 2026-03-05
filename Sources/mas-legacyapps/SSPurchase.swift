//
//  SSPurchase.swift
//  mas
//
//  Copyright (c) 2015 Andrew Naylor. All rights reserved.
//
//  Modified by github.com/handyandy87 on 03/03/2026 07:51:00 PM CST.

import CommerceKit
import PromiseKit
import StoreFoundation

extension SSPurchase {
    /// Initiates a purchase/download with optional version override and lookup-only mode.
    ///
    /// - Parameters:
    ///   - appID: The App Store item ID for the app.
    ///   - purchasing: Whether this is a "purchase" (free app install confirmation) or a standard redownload.
    ///   - appExtVrsId: App External Version ID to override the default (0). When non-zero, requests a specific
    ///     historical version from Apple's servers. Allows installation of older app versions no longer in the catalog.
    ///   - lookupOnly: When true, cancels the download immediately after reading metadata (bundleVersion) from
    ///     CommerceKit, prints the version, and completes without downloading any bytes. Useful for bulk version
    ///     lookups of App External IDs.
    /// - Returns: A Promise that fulfills when the download completes (or is cancelled in lookup-only mode).
    func perform(appID: AppID, purchasing: Bool, appExtVrsId: Int = 0, lookupOnly: Bool = false) -> Promise<Void> {
        var parameters =
            [
                "productType": "C",
                "price": 0,
                "salableAdamId": appID,
                "pg": "default",
                "appExtVrsId": appExtVrsId,
            ] as [String: Any]

        if purchasing {
            parameters["macappinstalledconfirmed"] = 1
            parameters["pricingParameters"] = "STDQ"
            // Possibly unnecessary…
            isRedownload = false
        } else {
            parameters["pricingParameters"] = "STDRDL"
        }

        buyParameters =
            parameters.map { key, value in
                "\(key)=\(value)"
            }
            .joined(separator: "&")

        itemIdentifier = appID

        downloadMetadata = SSDownloadMetadata()
        downloadMetadata.kind = "software"
        downloadMetadata.itemIdentifier = appID

        // Monterey obscures the user's App Store account, but allows
        // redownloads without passing any account IDs to SSPurchase.
        // https://github.com/mas-cli/mas/issues/417
        if #available(macOS 12, *) {
            return perform(lookupOnly: lookupOnly)
        }

        return
            ISStoreAccount.primaryAccount
            .then { storeAccount in
                self.accountIdentifier = storeAccount.dsID
                self.appleID = storeAccount.identifier
                return self.perform(lookupOnly: lookupOnly)
            }
    }

    private func perform(lookupOnly: Bool = false) -> Promise<Void> {
        Promise<SSPurchase> { seal in
            CKPurchaseController.shared()
                .perform(self, withOptions: 0) { purchase, _, error, response in
                    if let error {
                        seal.reject(MASError.purchaseFailed(error: error as NSError?))
                        return
                    }

                    guard response?.downloads.isEmpty == false, let purchase else {
                        seal.reject(MASError.noDownloads)
                        return
                    }

                    seal.fulfill(purchase)
                }
        }
        .then { purchase in
            PurchaseDownloadObserver(purchase: purchase, lookupOnly: lookupOnly).observeDownloadQueue()
        }
    }
}
