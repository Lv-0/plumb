import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct InstalledAppInfo: Hashable {
    let bundleID: String
    let name: String
    let path: String
    let isSystemApp: Bool
}

enum InstalledAppCatalog {
    private static let searchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        // CoreServices 容纳 Finder.app 等系统级应用，此前缺失导致访达在列表中不可见。
        URL(fileURLWithPath: "/System/Library/CoreServices"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    static func loadInstalledApps(fileManager: FileManager = .default) -> [InstalledAppInfo] {
        var appURLs: [URL] = []
        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            appURLs.append(contentsOf: discoverAppBundles(in: root, fileManager: fileManager))
        }

        var seenBundleIDs: Set<String> = []
        var result: [InstalledAppInfo] = []

        for appURL in appURLs {
            // Safari and many system apps live under /Applications as symbolic links into
            // /System/Cryptexes/App/... FileManager's directory enumerator does not surface these
            // symlinked bundles, so they are absent from the picker. Resolve the real path and
            // load the bundle from it. Skip placeholders/stubs that have no bundle id.
            let resolvedURL = resolveSymlink(appURL, fileManager: fileManager) ?? appURL
            guard
                let bundle = Bundle(url: resolvedURL),
                let rawBundleID = bundle.bundleIdentifier
            else {
                continue
            }

            let bundleID = AppTilingSettings.normalizeBundleID(rawBundleID)
            if bundleID.isEmpty || seenBundleIDs.contains(bundleID) {
                continue
            }

            // Mark as a system app if the bundle (or its link target) lives under /System.
            let isSystem = appURL.path.hasPrefix("/System/") ||
                resolvedURL.path.hasPrefix("/System/") ||
                isUnderCryptex(appURL.path)

            // CoreServices 等 /System 位置下混入大量后台 agent（LSUIElement=true 的无界面进程，
            // 如 Dock、ControlCenter、Spotlight）。对这些系统位置，只保留真正的面向用户应用。
            // 注意：限定仅对 /System 位置应用此过滤——用户安装的应用（/Applications、~/Applications）
            // 即便带 LSUIElement=true 也往往是真实的可见窗口应用（如 Windows App/Remote Desktop、
            // Raycast、Bob、BetterDisplay 等，它们用 LSUIElement 仅为隐藏 Dock 图标，仍需可被居中/平铺）。
            if isSystem, (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true {
                continue
            }

            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ??
                appURL.deletingPathExtension().lastPathComponent

            let info = InstalledAppInfo(
                bundleID: bundleID,
                name: name,
                path: appURL.path,
                isSystemApp: isSystem
            )
            seenBundleIDs.insert(bundleID)
            result.append(info)
        }

        return result.sorted {
            let lhsName = $0.name.localizedLowercase
            let rhsName = $1.name.localizedLowercase
            if lhsName == rhsName {
                return $0.bundleID < $1.bundleID
            }
            return lhsName < rhsName
        }
    }

    /// Resolve an `.app` URL that is itself a symbolic link (e.g. Safari under /Applications) to its
    /// real on-disk location. Returns nil if the path is not a symlink or cannot be resolved.
    private static func resolveSymlink(_ url: URL, fileManager: FileManager) -> URL? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink
        else {
            return nil
        }
        // destinationOfSymbolicLink returns the raw link target (often relative, like
        // "../System/Cryptexes/App/System/Applications/Safari.app"). Resolve it against the link's
        // own directory, and fall back to resolving/standardizing if the direct computation fails.
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
            let standardized = resolved.standardizedFileURL.path
            if fileManager.fileExists(atPath: standardized) {
                return URL(fileURLWithPath: standardized)
            }
        }
        // Final fallback: URL.resolvingSymlinksInPath().
        let resolved = url.resolvingSymlinksInPath()
        if fileManager.fileExists(atPath: resolved.path) {
            return resolved
        }
        return nil
    }

    /// System apps shipped via the cryptex appear as symlinks whose target contains "Cryptexes".
    private static func isUnderCryptex(_ path: String) -> Bool {
        path.contains("/Cryptexes/")
    }

    private static func discoverAppBundles(in root: URL, fileManager: FileManager) -> [URL] {
        // List the direct children of the root directory using POSIX readdir rather than FileManager.
        // Reason: system apps such as Safari, Mail and Notes live under /Applications as symbolic
        // links into /System/Cryptexes/App/... macOS App-Management filtering hides these symlinked
        // bundles from FileManager's enumerator/contentsOfDirectory, so they never showed up in the
        // tiling picker. The raw readdir syscall (like `ls`) still surfaces them.
        var apps: [URL] = []
        var topLevelSeen: Set<String> = []
        if let posixEntries = readDirectoryEntriesPOSIX(atPath: root.path) {
            for name in posixEntries where (name as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let url = root.appendingPathComponent(name)
                apps.append(url)
                topLevelSeen.insert(url.path)
            }
        } else {
            // Fallback to FileManager if POSIX listing fails (e.g. permission denied).
            if let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for entry in entries where entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    apps.append(entry)
                    topLevelSeen.insert(entry.path)
                }
            }
        }

        // Recurse one level into subfolders (e.g. /Applications/SomeFolder/Foo.app) to keep
        // existing behavior for nested installations. Skip package descendants so we do not descend
        // into the `.app` bundles themselves.
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return apps
        }

        for case let url as URL in enumerator {
            // Skip the direct children we already collected, and only keep nested `.app` bundles.
            guard !topLevelSeen.contains(url.path),
                  url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            else {
                continue
            }
            apps.append(url)
        }
        return apps
    }

    /// Raw directory listing via POSIX opendir/readdir. Returns entry names (not paths) excluding
    /// "." and "..". Returns nil if the directory cannot be opened.
    private static func readDirectoryEntriesPOSIX(atPath path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }

        var names: [String] = []
        while let entryPtr = readdir(dir) {
            // Convert the fixed-size C array d_name to a Swift String.
            let name = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entryPtr.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }
}
