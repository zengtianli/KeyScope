#if APP_STORE
import AppKit
import Carbon
import Darwin
import Foundation

/// Machine-local permission, never exported or synced: another Mac must grant its own folder.
enum StorePreferences {
    private static let bookmarkKey = "storePreferencesFolderBookmark"
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyScope", isDirectory: true)
    }
    static var isGranted: Bool { withFolder { _ in } }
    static var description: String {
        isGranted ? "已允许 Preferences 偏好线索；系统热键由 macOS 接口查询，其它工具的脚本与配置目录不在授权范围内。"
            : "可选：允许 Preferences 文件夹后读取支持软件的快捷键偏好。基本检测与系统热键查询不需要此项；未允许或授权失效时不会扫描这些偏好文件。"
    }
    static func save(_ folder: URL) throws {
        guard folder.lastPathComponent == "Preferences",
              (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw NSError(domain: "KeyScope.Store", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请选择 Preferences 文件夹。"])
        }
        let data = try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                          includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }
    static func revoke() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
    @discardableResult static func withFolder(_ body: (URL) -> Void) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
              folder.lastPathComponent == "Preferences" else { return false }
        let started = folder.startAccessingSecurityScopedResource()
        // Container fixtures need no extension; every external folder must actually redeem its scope.
        let insideContainer = folder.standardizedFileURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/")
        guard started || insideContainer else { return false }
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        if stale { try? save(folder) }
        body(folder)
        return true
    }
    static func chooseFolder() -> Bool {
        precondition(Thread.isMainThread)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "允许只读访问"
        panel.message = "可选：选择 Library/Preferences 文件夹以查看支持软件的快捷键偏好。不会修改任何文件。"
        if let path = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("Library/Preferences")
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        do { try save(folder); return isGranted } catch { return false }
    }

    /// Isolated sandbox probe only; no NSApplication, event tap, dialog or real preferences file.
    static func selfTest(resume: Bool) -> Int32 {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard bundleID == "test.tianli.keyscope.store" else {
            fputs("store self-test requires test.tianli.keyscope.store\n", stderr); return 2
        }
        do {
            let fm = FileManager.default
            let fixture = supportDirectory.appendingPathComponent("StoreSelfTest", isDirectory: true)
            let preferences = fixture.appendingPathComponent("Preferences", isDirectory: true)
            let shortcut = ShortcutSpec(keyCode: 5, modifiers: CGEventFlags.maskControl.rawValue)
            var checks: [String: Bool] = [:]
            if !resume { revoke() }
            var rawHotKeys: Unmanaged<CFArray>?
            let hotKeyStatus = CopySymbolicHotKeys(&rawHotKeys)
            let hotKeys = rawHotKeys?.takeRetainedValue() as? [[String: Any]] ?? []
            let enabledHotKeys = hotKeys.filter { ($0["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true }
            let enabledShortcuts = enabledHotKeys.compactMap { entry -> ShortcutSpec? in
                guard let code = entry["kHISymbolicHotKeyCode"] as? NSNumber, code.uint64Value <= UInt64(UInt16.max),
                      let modifiers = entry["kHISymbolicHotKeyModifiers"] as? NSNumber else { return nil }
                return ShortcutSpec(keyCode: code.uint16Value, modifiers: ShortcutSpec.cocoaModifiers(fromCarbon: modifiers.uint64Value))
            }
            let controlUp = ShortcutSpec(keyCode: UInt16(kVK_UpArrow), modifiers: CGEventFlags.maskControl.rawValue)
            let testedShortcut = enabledShortcuts.first { $0 == controlUp } ?? enabledShortcuts.first
            let systemSnapshot = testedShortcut.map { ConfigurationScanner().scan($0) }
            let systemFinding = systemSnapshot?.findings.first { $0.level == .systemBinding }
            checks["system_hotkeys_match_api"] = hotKeyStatus == noErr && !enabledShortcuts.isEmpty && systemFinding != nil
            let systemHotKeys: [String: Any] = ["status": hotKeyStatus, "count": hotKeys.count,
                "enabledCount": enabledHotKeys.count, "controlUpEnabled": enabledShortcuts.contains(controlUp),
                "testedShortcut": testedShortcut?.displayName ?? "", "findingTitle": systemFinding?.title ?? "",
                "folderGranted": isGranted]
            if !resume {
                let before = ConfigurationScanner().scan(shortcut)
                checks["default_has_no_app_configuration"] = !before.findings.contains { $0.level == .configuration || $0.level == .conditionalConfiguration }
                try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: ["raycastGlobalHotkey": "Control-5"], format: .xml, options: 0)
                try data.write(to: preferences.appendingPathComponent("com.raycast.macos.plist"))
                try save(preferences)
                UserDefaults.standard.synchronize()
            }
            let snapshot = ConfigurationScanner().scan(shortcut)
            checks["bookmark_resolves"] = isGranted
            checks["authorized_preferences_parsed"] = snapshot.findings.contains { $0.id == "raycast-global" && $0.level == .configuration }
            let probe = fixture.appendingPathComponent("config-read-write.json")
            let payload = Data("{\"isolated\":true}".utf8)
            try payload.write(to: probe)
            checks["container_read_write"] = try Data(contentsOf: probe) == payload
            let home = fm.homeDirectoryForCurrentUser.path
            checks["sandbox_container"] = home.contains("/Library/Containers/\(bundleID)/Data")
            let ok = checks.values.allSatisfy { $0 }
            let report: [String: Any] = ["ok": ok, "checks": checks, "resume": resume, "home": home,
                                        "support": supportDirectory.path, "fixture": fixture.path,
                                        "sandboxContainer": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "",
                                        "listenerSources": snapshot.checkedSources, "notes": snapshot.notes,
                                        "systemHotKeys": systemHotKeys]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return ok ? 0 : 1
        } catch { fputs("store self-test: \(error)\n", stderr); return 1 }
    }
}
#endif
