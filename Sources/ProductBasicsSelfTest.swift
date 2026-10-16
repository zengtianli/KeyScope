#if !APP_STORE
import AppKit

enum ProductBasicsSelfTest {
    static func run(_ out:URL) -> Int32 {
        guard Bundle.main.bundleIdentifier?.hasPrefix("test.tianli.keyscope.basics.") == true,
              ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil,
              ProcessInfo.processInfo.environment["APP_LIFECYCLE_CLOUD_DIR"] != nil else { return 2 }
        var checks:[String:Bool] = [:]
        do {
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            let delegate = AppDelegate();delegate.buildMenu();delegate.installLifecycle()
            delegate.model.isListening = true
            let busy = AppLifecycleUI.shared.canInstallUpdate?() == false
            delegate.model.isListening = false
            checks["updates.busy_gate"] = busy && AppLifecycleUI.shared.canInstallUpdate?() == true
            let settings = KeyScopeSettings.shared
            let initial = try AppLifecycleUI.shared.offscreenSnapshot(to:out.appendingPathComponent("settings-before.png"),showingUpdateOptions:true)
            settings.detailsToggle.state = .on
            let sent = settings.detailsToggle.sendAction(settings.detailsToggle.action,to:settings.detailsToggle.target)
            checks["settings.interaction"] = sent && settings.defaults.bool(forKey:KeyScopeSettings.detailsKey) && delegate.model.showDetails && initial.values.allSatisfy{$0}
            let saved = try settings.configuration.exportData()
            do { try settings.configuration.importData(Data("{broken".utf8));checks["settings.error_preserves_data"] = false }
            catch { checks["settings.error_preserves_data"] = try settings.configuration.exportData() == saved }
            let item = settings.shortcuts.menuItem!
            checks["shortcuts.action_path"] = NSApp.sendAction(item.action!,to:item.target,from:item) && delegate.model.snapshot != nil && !delegate.model.isListening
            let binding = settings.shortcuts.binding.dictionary as NSDictionary
            settings.shortcutToggle.state = .off
            _ = settings.shortcutToggle.sendAction(settings.shortcutToggle.action,to:settings.shortcutToggle.target)
            let disabled = item.keyEquivalent.isEmpty && !settings.shortcuts.enabled && binding == settings.shortcuts.binding.dictionary as NSDictionary
            settings.shortcutToggle.state = .on
            _ = settings.shortcutToggle.sendAction(settings.shortcutToggle.action,to:settings.shortcutToggle.target)
            checks["shortcuts.disable_restore"] = disabled && item.keyEquivalent == "l" && settings.shortcuts.enabled
            settings.shortcutKey.stringValue = "k";settings.saveShortcutKey()
            let conflict = settings.shortcuts.binding.key == "l" && settings.message.stringValue.contains("已使用")
            settings.shortcutKey.stringValue = "q";settings.saveShortcutKey()
            checks["shortcuts.conflict_or_reserved_keys"] = conflict && settings.shortcuts.binding.key == "l" && settings.message.stringValue.contains("保留")
            settings.shortcutKey.stringValue = "j";settings.saveShortcutKey()
            checks["shortcuts.custom_binding_saved"] = item.keyEquivalent == "j"
            func views(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap { views($0) } }
            let window = NSApp.windows.first { $0.title.contains("设置") }!
            if let button = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == "检查更新"}) {
                // The menu/button action intentionally presents a window; use the shared
                // check's native non-presenting mode while retaining the actual UI target assertion.
                let wired = button.target === AppLifecycleUI.shared && button.action == NSSelectorFromString("checkUpdates")
                AppLifecycleUI.shared.checkForUpdates(present:false)
                let limit = Date().addingTimeInterval(8)
                while Date() < limit {
                    RunLoop.main.run(until:Date().addingTimeInterval(0.03))
                    let history = AppUpdatePreferences.status(Bundle.main.bundleIdentifier!,source:ProductLifecycle.updateSource)["history"] as? [String:Any]
                    if history?["latest_build"] != nil { break }
                }
                let history = AppUpdatePreferences.status(Bundle.main.bundleIdentifier!,source:ProductLifecycle.updateSource)["history"] as? [String:Any]
                checks["updates.actual_check_path"] = wired && history?["latest_build"] as? String == "1000000"
            } else { checks["updates.actual_check_path"] = false }
            let image = try AppLifecycleUI.shared.offscreenSnapshot(to:out.appendingPathComponent("settings-after.png"),showingUpdateOptions:true)
            checks["settings.real_view_rendered"] = image.values.allSatisfy{$0}
            checks["settings.hidden_no_focus"] = !NSApp.isActive && NSApp.windows.allSatisfy{!$0.isVisible} && NSApp.activationPolicy() == .prohibited
            window.close()
            settings.defaults.synchronize()
            withExtendedLifetime(delegate) {}
        } catch { checks["settings.execution"] = false;fputs("\(error)\n",stderr) }
        KeyScopeCLI.emitJSON(["checks":checks])
        return checks.values.allSatisfy{$0} && !checks.isEmpty ? 0 : 1
    }
}
#endif
