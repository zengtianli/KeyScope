#if !APP_STORE
import AppKit

/// Product values only. Transport, merges, backups and upgrades belong to swift-shared.
final class KeyScopeSettings: NSObject {
    static let shared = KeyScopeSettings()
    static let detailsKey = "keyscope.detailsByDefault"
    // A command reached via Resources/bin/keyscope has no main bundle identifier.
    // Resolve the owning app rather than writing the anonymous `keyscope` domain.
    let defaults = AppUpdatePreferences.defaults(ProductLifecycle.hostBundle.bundleIdentifier ?? "cyou.tianli.keyscope")
    var refreshAction: (() -> Void)?
    var changed: (() -> Void)?
    lazy var shortcuts = AppShortcuts(defaults: defaults) { [weak self] in self?.refreshAction?() }
    lazy var configuration: AppConfiguration = {
        let config = AppConfiguration(productID: ProductLifecycle.hostBundle.bundleIdentifier ?? "cyou.tianli.keyscope",
            defaultsKeys: [Self.detailsKey, "appUpdateOptions"] + AppShortcuts.portableKeys, defaults: defaults)
        config.onChange = { [weak self] in
            self?.shortcuts.refresh()
            if NSApp != nil { self?.refreshControls() }
            self?.changed?()
        }
        return config
    }()
    lazy var detailsToggle = NSSwitch()
    lazy var shortcutToggle = NSSwitch()
    lazy var shortcutKey = NSTextField(string: "")
    lazy var message = AppLifecycleUI.detailLabel()
    override init() {
        super.init()
        defaults.register(defaults: [AppShortcuts.bindingKey: ["key":"l", "modifiers":NSEvent.ModifierFlags.command.rawValue]])
    }
    func groups() -> [NSView] {
        detailsToggle.target = self; detailsToggle.action = #selector(saveDetails)
        shortcutToggle.target = self; shortcutToggle.action = #selector(saveShortcutEnabled)
        shortcutKey.target = self; shortcutKey.action = #selector(saveShortcutKey)
        shortcutKey.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let save = NSButton(title: "保存快捷键", target: self, action: #selector(saveShortcutKey))
        let binding = NSStackView(views: [NSTextField(labelWithString:"⌘"), shortcutKey, save]); binding.spacing = 6
        refreshControls()
        return [AppLifecycleUI.group("检测与应用快捷键", rows: [
            AppLifecycleUI.row("默认展开排查详情", accessory: detailsToggle),
            AppLifecycleUI.row("启用刷新快捷键", detail: AppLifecycleUI.detailLabel("仅在 KeyScope 内生效；关闭保留绑定，不改变其它软件的快捷键。"), accessory: shortcutToggle),
            AppLifecycleUI.row("刷新结果", detail: message, accessory: binding)])]
    }
    func refreshControls() {
        detailsToggle.state = defaults.bool(forKey:Self.detailsKey) ? .on : .off
        shortcutToggle.state = shortcuts.enabled ? .on : .off
        shortcutKey.stringValue = shortcuts.binding.key
        message.stringValue = shortcuts.descriptionText
    }
    @objc func saveDetails() {
        defaults.set(detailsToggle.state == .on, forKey: Self.detailsKey); defaults.synchronize(); changed?()
    }
    @objc func saveShortcutEnabled() { shortcuts.setEnabled(shortcutToggle.state == .on); refreshControls() }
    @objc func saveShortcutKey() {
        do { try shortcuts.setBinding(.init(key:shortcutKey.stringValue.lowercased(),modifiers:.command)); refreshControls() }
        catch { message.stringValue = error.localizedDescription }
    }
    static func command(_ args: [String]) -> Int32 {
        let s = shared
        do {
            let words = args.filter { $0 != "--json" }
            let verb = words.first ?? "status"
            if verb == "set" {
                guard words.count == 4, words[1] == "--details", ["on","off"].contains(words[2]), words[3] == "--yes" else { throw AppUpdateError("preferences set --details on|off --yes") }
                s.defaults.set(words[2] == "on",forKey:detailsKey);s.defaults.synchronize()
            } else if ["enable","disable","bind"].contains(verb) {
                if verb == "bind" {
                    guard words.count == 3, words[2] == "--yes" else { throw AppUpdateError("shortcuts bind <字母> --yes") }
                    NSApplication.shared.setActivationPolicy(.prohibited)
                    let delegate = AppDelegate();delegate.buildMenu()
                    try s.shortcuts.setBinding(.init(key:words[1].lowercased(),modifiers:.command))
                    withExtendedLifetime(delegate) {}
                } else {
                    guard words.count == 2, words[1] == "--yes" else { throw AppUpdateError("修改快捷键需要 --yes") }
                    s.shortcuts.setEnabled(verb == "enable")
                }
            } else if verb != "status" || words.count > 1 { throw AppUpdateError("未知设置命令") }
            KeyScopeCLI.emitJSON(["ok":true,"detailsByDefault":s.defaults.bool(forKey:detailsKey),
                "shortcuts":["enabled":s.shortcuts.enabled,"key":s.shortcuts.binding.key,"modifiers":s.shortcuts.binding.modifiers.rawValue]])
            return 0
        } catch { return KeyScopeCLI.fail("preferences",code:"invalid_setting",message:error.localizedDescription,exit:2,json:true) }
    }
}
#endif
