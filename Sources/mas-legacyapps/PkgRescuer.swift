//
//  PkgRescuer.swift
//  mas
//
//
//  Created by github.com/handyandy87 on 02/03/2026 09:49:09 AM CST.

import Foundation
import Dispatch

/// Stages the in-flight App Store downloaded `.pkg` (and `receipt`) into `/Users/Shared/MASExtractedPkgs`
/// so it can be extracted quickly if the install step fails after the download.
final class PkgRescuer {
    struct StagedPaths {
        let cacheDirectory: URL
        let stagedDirectory: URL
        let stagedPkg: URL
        let stagedReceipt: URL?
        let extractedDirectory: URL
        let extractedApp: URL?
    }

    private let appID: UInt64

    private let outputRoot = URL(fileURLWithPath: "/Users/Shared/MASExtractedPkgs", isDirectory: true)
    private var timer: DispatchSourceTimer?

    private let ioQueue = DispatchQueue(label: "mas.pkgrescuer.io", qos: .userInitiated)

    private var cacheDirectory: URL?
    private var stagedDirectory: URL?
    private var stagedPkg: URL?
    private var stagedReceipt: URL?

    private let monitoringStartedAt = Date()

    init(appID: UInt64) {
        self.appID = appID
    }

    func startMonitoring() {
        // Determine cache directory once, best-effort.
        cacheDirectory = Self.findAppStoreCacheDirectory(appID: appID)

        // Ensure staging directory exists.
        let stageDir = outputRoot
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(String(appID), isDirectory: true)
        stagedDirectory = stageDir
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true, attributes: nil)

        // Poll rapidly; the cache file can disappear quickly once the system proceeds.
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.pollAndStageIfNeeded()
        }
        timer = t
        t.resume()
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }

    /// Attempt to rescue (stage if not already staged) and extract the staged package.
    /// Returns paths for user messaging.
    func rescueAndExtract(appName: String, bundleVersion: String?) throws -> StagedPaths {
        // One last poll in case we haven't staged yet.
        pollAndStageIfNeeded(force: true)

        guard let cacheDir = cacheDirectory else {
            throw NSError(domain: "mas.pkgrescuer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine App Store cache directory."])
        }
        guard let stageDir = stagedDirectory else {
            throw NSError(domain: "mas.pkgrescuer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not determine staging directory."])
        }
        guard let pkg = stagedPkg else {
            throw NSError(domain: "mas.pkgrescuer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not locate the downloaded .pkg in the App Store cache."])
        }

        // Prepare output dir.
        // Use a unique folder name to avoid collisions (e.g., repeated attempts within the same second).
        // Include bundle version when available.
        let safeName = Self.sanitizeFileComponent(appName)
        let timestamp = Self.timestampString()

        var folderName = "\(timestamp)-\(safeName)"
        if let v = bundleVersion, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let safeV = Self.sanitizeFileComponent(v)
            if !safeV.isEmpty {
                folderName += "-\(safeV)"
            }
        }

        var outDir = outputRoot
            .appendingPathComponent(String(appID), isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        let fm = FileManager.default
        if fm.fileExists(atPath: outDir.path) {
            outDir = outputRoot
                .appendingPathComponent(String(appID), isDirectory: true)
                .appendingPathComponent("\(timestamp)-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        }
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: nil)

        // Copy receipt (if staged) to output with requested naming.
        if let receipt = stagedReceipt {
            let outReceipt = outDir.appendingPathComponent("\(appID)-receipt")
            _ = Self.copyOrReplace(from: receipt, to: outReceipt)
        }

        // Extract directly into the output directory so the user gets a simple structure:
        // <timestamp-appname[-version]>/<App.app> alongside the receipt.
        try Self.extract(pkgURL: pkg, to: outDir)

        // Try to locate the .app bundle for reporting purposes.
        // Do not move/flatten anything; keep the original package folder structure (often Applications/...).
        let appBundle = Self.findPreferredAppBundle(in: outDir, preferredName: safeName)

        return StagedPaths(
            cacheDirectory: cacheDir,
            stagedDirectory: stageDir,
            stagedPkg: pkg,
            stagedReceipt: stagedReceipt,
            extractedDirectory: outDir,
            extractedApp: appBundle
        )
    }

    // MARK: - Polling + staging

    private func pollAndStageIfNeeded(force: Bool = false) {
        guard let cacheDir = cacheDirectory else { return }
        guard let stageDir = stagedDirectory else { return }

        // Stage pkg
        if stagedPkg == nil || force {
            if let pkg = Self.findPkg(in: cacheDir) {
                let dest = stageDir.appendingPathComponent(pkg.lastPathComponent)
                if Self.hardlinkOrCopy(from: pkg, to: dest) {
                    stagedPkg = dest
                }
            }
        }

        // Stage receipt
        if stagedReceipt == nil || force {
            let receipt = cacheDir.appendingPathComponent("receipt")
            if FileManager.default.fileExists(atPath: receipt.path) {
                let dest = stageDir.appendingPathComponent("receipt")
                if Self.hardlinkOrCopy(from: receipt, to: dest) {
                    stagedReceipt = dest
                }
            }
        }

        // Stop when we have both staged, or after a short grace period.
        if stagedPkg != nil, stagedReceipt != nil {
            stopMonitoring()
            return
        }

        // Don't keep the timer running indefinitely.
        if !force, Date().timeIntervalSince(monitoringStartedAt) > 60 {
            stopMonitoring()
        }
    }

    // MARK: - Cache directory

    private static func findAppStoreCacheDirectory(appID: UInt64) -> URL? {
        guard let base = darwinUserCacheDirectory() else { return nil }

        // Prefer the observed path: .../com.apple.AppStore/<appid>
        let candidates = [
            base.appendingPathComponent("com.apple.AppStore", isDirectory: true).appendingPathComponent(String(appID), isDirectory: true),
            base.appendingPathComponent("com.apple.appstore", isDirectory: true).appendingPathComponent(String(appID), isDirectory: true)
        ]

        for c in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue {
                return c
            }
        }

        // If the appID directory doesn't exist yet, return the parent and rely on polling for creation.
        // Prefer com.apple.AppStore over com.apple.appstore.
        let parentCandidates = [
            base.appendingPathComponent("com.apple.AppStore", isDirectory: true),
            base.appendingPathComponent("com.apple.appstore", isDirectory: true)
        ]

        for p in parentCandidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue {
                return p.appendingPathComponent(String(appID), isDirectory: true)
            }
        }

        return nil
    }

    private static func darwinUserCacheDirectory() -> URL? {
        // Equivalent to: getconf DARWIN_USER_CACHE_DIR
        let p = Process()
        p.launchPath = "/usr/bin/getconf"
        p.arguments = ["DARWIN_USER_CACHE_DIR"]
        let out = Pipe()
        p.standardOutput = out
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s, isDirectory: true)
    }

    // MARK: - Find pkg/receipt

    private static func findPkg(in dir: URL) -> URL? {
        // Search the directory and (if needed) one level below; App Store can place pkgs in subfolders.
        let fm = FileManager.default
        var candidates: [URL] = []

        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in items {
                if item.pathExtension.lowercased() == "pkg" {
                    candidates.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if let subitems = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                        candidates.append(contentsOf: subitems.filter { $0.pathExtension.lowercased() == "pkg" })
                    }
                }
            }
        }

        if candidates.isEmpty { return nil }
        // Choose newest by mtime.
        return candidates.max(by: { (a, b) -> Bool in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return ad < bd
        })
    }



    private static func makeUniqueDirectory(parent: URL, prefix: String) throws -> URL {
        let fm = FileManager.default
        for _ in 0..<10 {
            let candidate = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: nil)
                return candidate
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == CocoaError.fileWriteFileExists.rawValue {
                    // If it already exists as a directory, proceed; otherwise retry.
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                        // Directory already exists; pick a new unique name.
                        continue
                    }
                    continue
                }
                throw error
            }
        }
        throw NSError(
            domain: "mas.pkgrescuer",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "Unable to create a unique directory under \(parent.path)"]
        )
    }


    // MARK: - Extract

    private static func extract(pkgURL: URL, to outDir: URL) throws {
        let fm = FileManager.default

        // Modern .pkg files are XAR archives. Using xar keeps the on-disk structure simpler
        // than pkgutil expansion directories.
        // We extract the XAR contents to a temporary folder, then unpack any Payload files
        // into the requested output directory.
        let tmp = try makeUniqueDirectory(parent: outDir, prefix: ".xar")
        defer { try? fm.removeItem(at: tmp) }

        // xar -xf <pkg> -C <tmp>
        try runProcess("/usr/bin/xar", ["-xf", pkgURL.path, "-C", tmp.path])

        // Unpack each Payload we find into outDir.
        guard let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }

        var payloadFound = false
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "Payload" {
                payloadFound = true
                // ditto -x Payload <outDir>
                try runProcess("/usr/bin/ditto", ["-x", fileURL.path, outDir.path])
            }
        }

        // If no Payload was found, keep the raw extracted XAR contents hidden alongside the output.
        // (Still useful for diagnostics without cluttering the user-facing folder.)
        if !payloadFound {
            let rawOut = outDir.appendingPathComponent(".xar-contents", isDirectory: true)
            _ = try? fm.removeItem(at: rawOut)
            try fm.copyItem(at: tmp, to: rawOut)
        }
    }

    private static func runProcess(_ executable: String, _ args: [String]) throws {
        let p = Process()
        p.launchPath = executable
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "mas.pkgrescuer", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Process failed: \(executable)" : msg])
        }
    }

    // MARK: - File ops helpers

    private static func hardlinkOrCopy(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        // Replace existing if present.
        _ = try? fm.removeItem(at: dst)

        do {
            try fm.linkItem(at: src, to: dst)
            return true
        } catch {
            // Fall back to copy.
            return copyOrReplace(from: src, to: dst)
        }
    }

    @discardableResult
    private static func copyOrReplace(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        _ = try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: src, to: dst)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Output helpers

    private static func sanitizeFileComponent(_ s: String) -> String {
        // Keep it simple: allow alphanumerics, space, dash, underscore. Replace others with underscore.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
            .description
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func findPreferredAppBundle(in outDir: URL, preferredName: String) -> URL? {
        let fm = FileManager.default

        // Find all .app bundles.
        var apps: [URL] = []
        if let enumerator = fm.enumerator(at: outDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    apps.append(url)
                }
            }
        }
        guard !apps.isEmpty else { return nil }

        // Prefer an app whose name contains the appName (best-effort).
        let preferredLower = preferredName.lowercased()
        let chosen = apps.first(where: { $0.lastPathComponent.lowercased().contains(preferredLower) }) ?? apps[0]

        return chosen
    }
}
