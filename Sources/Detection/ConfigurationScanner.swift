import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Reads only documented hotkey records or narrowly scoped local configuration.
/// A configuration match never asserts that the process received an event.
struct ConfigurationScanner {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func scan(_ shortcut: ShortcutSpec) -> DetectionSnapshot {
        var snapshot = DetectionSnapshot(shortcut: shortcut, findings: [], notes: [], checkedSources: [], observedAt: Date())
        #if APP_STORE
        system(shortcut, into: &snapshot)
        let granted = StorePreferences.withFolder { folder in
            knownPreferences(shortcut, directory: folder, into: &snapshot)
        }
        snapshot.notes.append(granted
            ? "系统热键通过 macOS 接口查询；另只扫描已允许的 Preferences 文件夹中的 Rectangle、Maccy、Raycast 和 MonitorControl 偏好。系统绑定或配置匹配不等于已观察到接收进程。"
            : "商店版默认通过 macOS 接口查询已启用的系统热键，并提供热键接收结果与监听候选。其它软件的偏好线索未启用，可选择允许 Preferences 文件夹；系统热键查询不需要文件授权。")
        snapshot.notes.append("商店版不读取系统快捷键偏好文件，不扫描 Keyboard Maestro 的 Application Support、Karabiner/skhd 的 .config、.skhdrc、Hammerspoon 脚本，也不枚举登录项。")
        #else
        system(shortcut, into: &snapshot)
        keyboardMaestro(shortcut, into: &snapshot)
        karabiner(shortcut, into: &snapshot)
        skhd(shortcut, into: &snapshot)
        hammerspoon(shortcut, into: &snapshot)
        knownPreferences(shortcut, into: &snapshot)
        #endif
        listeners(into: &snapshot)
        snapshot.notes.append("配置能证明存在对应规则；软件是否已加载、应用范围及条件是否满足，仍需结合实时结果。未检出不代表没有占用。")
        snapshot.notes.append("按物理键位匹配，字母标记采用美式键盘；系统菜单、浏览器扩展、任意脚本与未支持工具的私有配置不在完整扫描范围内。")
        snapshot.findings.sort { $0.level.rank == $1.level.rank ? $0.application.name < $1.application.name : $0.level.rank < $1.level.rank }
        return snapshot
    }

    private func read(_ url: URL, source: String, into snapshot: inout DetectionSnapshot) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000 else {
            snapshot.notes.append("\(source)：文件超过读取上限或无法读取大小，未扫描。")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            snapshot.checkedSources.append(source)
            return data
        } catch {
            snapshot.notes.append("\(source)：无法读取配置。")
            return nil
        }
    }

    private func system(_ shortcut: ShortcutSpec, into snapshot: inout DetectionSnapshot) {
        var values: Unmanaged<CFArray>?
        let error = CopySymbolicHotKeys(&values)
        guard error == noErr, let values = values?.takeRetainedValue() as? [[String: Any]] else {
            snapshot.notes.append("系统热键枚举失败（\(error)）。")
            return
        }
        snapshot.checkedSources.append("macOS 有效系统热键")
        for entry in values {
            guard let code = entry["kHISymbolicHotKeyCode"] as? NSNumber,
                  let modifiers = entry["kHISymbolicHotKeyModifiers"] as? NSNumber,
                  (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  code.uint64Value <= UInt64(UInt16.max),
                  ShortcutSpec(keyCode: code.uint16Value, modifiers: ShortcutSpec.cocoaModifiers(fromCarbon: modifiers.uint64Value)) == shortcut else { continue }
            if snapshot.findings.contains(where: { $0.level == .systemBinding }) { continue }
            snapshot.findings.append(Finding(id: "system-\(shortcut.keyCode)-\(shortcut.modifiers)", level: .systemBinding,
                application: AppIdentity(name: "macOS", bundleID: "com.apple.systempreferences", bundleURL: URL(fileURLWithPath: "/System/Applications/System Settings.app"), isRunning: true),
                title: "系统已启用这个组合键", detail: "macOS 的有效系统热键列表包含 \(shortcut.displayName)。这说明系统保留了该组合，不代表已观察到此次按键的接收进程。",
                sourceURL: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")))
        }
    }

    private func keyboardMaestro(_ shortcut: ShortcutSpec, into snapshot: inout DetectionSnapshot) {
        let url = home.appendingPathComponent("Library/Application Support/Keyboard Maestro/Keyboard Maestro Macros.plist")
        guard let data = read(url, source: "Keyboard Maestro 宏配置", into: &snapshot) else { return }
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            snapshot.notes.append("Keyboard Maestro：配置格式无法解析。")
            return
        }
        snapshot.findings += Self.keyboardMaestroFindings(root: root, shortcut: shortcut, sourceURL: url)
    }

    static func keyboardMaestroFindings(root: [String: Any], shortcut: ShortcutSpec, sourceURL: URL) -> [Finding] {
        var result: [Finding] = []
        let identity = AppIdentity.known("Keyboard Maestro", bundleID: "com.stairways.keyboardmaestro.engine")
        for group in root["MacroGroups"] as? [[String: Any]] ?? [] {
            guard group["IsActive"] as? Bool != false, group["IsDisabled"] as? Bool != true else { continue }
            let targeting = group["Targeting"] as? [String: Any]
            let conditional = targeting != nil || (group["Activate"] as? String).map { $0 != "Normal" } == true
            let targets = (targeting?["TargetingApps"] as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String }.joined(separator: "、")
            for macro in group["Macros"] as? [[String: Any]] ?? [] {
                guard macro["IsActive"] as? Bool != false, macro["IsDisabled"] as? Bool != true else { continue }
                for trigger in macro["Triggers"] as? [[String: Any]] ?? [] {
                    guard trigger["MacroTriggerType"] as? String == "HotKey",
                          let code = trigger["KeyCode"] as? NSNumber, code.uint64Value <= UInt64(UInt16.max),
                          let mods = trigger["Modifiers"] as? NSNumber,
                          ShortcutSpec(keyCode: code.uint16Value, modifiers: ShortcutSpec.cocoaModifiers(fromCarbon: mods.uint64Value)) == shortcut else { continue }
                    let name = macro["Name"] as? String ?? "未命名宏"
                    let scope = conditional ? "此宏有应用或激活条件\(targets.isEmpty ? "" : "（\(targets)）")；当前是否生效需在 Keyboard Maestro 中核对。" : "配置中的宏已启用；当前引擎是否加载此版本尚未确认。"
                    result.append(Finding(id: "km-\(macro["UID"] as? String ?? name)", level: conditional ? .conditionalConfiguration : .configuration, application: identity, title: name, detail: scope, sourceURL: sourceURL))
                }
            }
        }
        return result
    }

    private func karabiner(_ shortcut: ShortcutSpec, into snapshot: inout DetectionSnapshot) {
        let url = home.appendingPathComponent(".config/karabiner/karabiner.json")
        guard let data = read(url, source: "Karabiner 当前配置", into: &snapshot) else { return }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { snapshot.notes.append("Karabiner：配置格式无法解析。"); return }
        snapshot.findings += Self.karabinerFindings(root: root, shortcut: shortcut, sourceURL: url)
    }

    static func karabinerFindings(root: [String: Any], shortcut: ShortcutSpec, sourceURL: URL) -> [Finding] {
        var result: [Finding] = []
        let identity = AppIdentity.known("Karabiner-Elements", bundleID: "org.pqrs.Karabiner-Elements.Settings")
        guard let profile = (root["profiles"] as? [[String: Any]])?.first(where: { $0["selected"] as? Bool == true }) else { return [] }
        for (index, simple) in (profile["simple_modifications"] as? [[String: Any]] ?? []).enumerated() {
            guard let from = simple["from"] as? [String: Any], let name = from["key_code"] as? String,
                  ShortcutSpec.keyCode(named: name) == shortcut.keyCode else { continue }
            result.append(Finding(id: "karabiner-simple-\(index)", level: .configuration, application: identity, title: "简单按键映射", detail: "当前配置把该物理键映射为另一按键；修饰键也可能随映射传递。请在配置中查看输出。", sourceURL: sourceURL))
        }
        let rules = (profile["complex_modifications"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        for (ri, rule) in rules.enumerated() where rule["enabled"] as? Bool != false {
            for (mi, manipulator) in (rule["manipulators"] as? [[String: Any]] ?? []).enumerated() {
                guard manipulator["type"] as? String == "basic", manipulator["enabled"] as? Bool != false,
                      let from = manipulator["from"] as? [String: Any], let name = from["key_code"] as? String,
                      ShortcutSpec.keyCode(named: name) == shortcut.keyCode else { continue }
                let flags = from["modifiers"] as? [String: Any] ?? [:]
                let mandatory = flags["mandatory"] as? [String] ?? []
                let optional = flags["optional"] as? [String] ?? []
                guard let required = ShortcutSpec.modifiers(named: mandatory), shortcut.modifiers & required == required else { continue }
                let allowed = optional.contains("any") ? ShortcutSpec.modifierMask : (ShortcutSpec.modifiers(named: optional) ?? 0) | required
                guard shortcut.modifiers & ~allowed == 0 else { continue }
                let conditions = manipulator["conditions"] as? [[String: Any]] ?? []
                let sideSpecific = (mandatory + optional).contains { $0.hasPrefix("left_") || $0.hasPrefix("right_") }
                let conditional = !conditions.isEmpty || sideSpecific
                let detail = conditional ? "输入键与修饰键匹配，但规则有变量、应用、设备或左右修饰键等条件；未判断这些条件此刻是否满足。" : "当前配置中启用的输入规则匹配该组合；配置是否已被后台服务加载需结合实际按键核对。"
                result.append(Finding(id: "karabiner-\(ri)-\(mi)", level: conditional ? .conditionalConfiguration : .configuration, application: identity, title: rule["description"] as? String ?? "复杂修改规则", detail: detail, sourceURL: sourceURL))
            }
        }
        return result
    }

    private func skhd(_ shortcut: ShortcutSpec, into snapshot: inout DetectionSnapshot) {
        for relative in [".config/skhd/skhdrc", ".skhdrc"] {
            let url = home.appendingPathComponent(relative)
            guard let data = read(url, source: "skhd：\(relative)", into: &snapshot), let text = String(data: data, encoding: .utf8) else { continue }
            snapshot.findings += Self.skhdFindings(text: text, shortcut: shortcut, sourceURL: url)
            if text.contains(".load") { snapshot.notes.append("skhd：当前文件包含 .load；引入文件未展开。") }
        }
    }

    static func skhdFindings(text: String, shortcut: ShortcutSpec, sourceURL: URL) -> [Finding] {
        var result: [Finding] = []
        let pattern = #"^\s*(?:(\w+)\s*<\s*)?([A-Za-z+\s]*)\s*-\s*(0x[0-9A-Fa-f]+|[^\s:]+)\s*(:|\[|->)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.components(separatedBy: "#").first ?? ""
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let modsRange = Range(match.range(at: 2), in: line), let keyRange = Range(match.range(at: 3), in: line),
                  let code = ShortcutSpec.keyCode(named: String(line[keyRange])),
                  let flags = ShortcutSpec.modifiers(named: line[modsRange].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }),
                  ShortcutSpec(keyCode: code, modifiers: flags) == shortcut else { continue }
            let conditional = match.range(at: 1).location != NSNotFound || line.contains("[") || String(line[modsRange]).split(separator: "+").contains { ["lctrl","rctrl","lcmd","rcmd","lalt","ralt","lshift","rshift"].contains($0.trimmingCharacters(in: .whitespaces)) }
            result.append(Finding(id: "skhd-\(sourceURL.path)-\(index)", level: conditional ? .conditionalConfiguration : .configuration, application: AppIdentity(name: "skhd"), title: "skhd 组合键规则 · 第 \(index + 1) 行", detail: conditional ? "存在对应模式、应用或左右修饰键条件；未判定当前是否满足。" : "文件中存在该组合键规则；未验证运行进程的配置路径或是否已重载。", sourceURL: sourceURL))
        }
        return result
    }

    private func hammerspoon(_ shortcut: ShortcutSpec, into snapshot: inout DetectionSnapshot) {
        let roots = [home.appendingPathComponent(".hammerspoon"), home.appendingPathComponent(".config/hammerspoon")]
        var seen = Set<String>(), count = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if ["handoffs", "docs", "vendor", "Spoons"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "lua", seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                count += 1
                guard count <= 100 else { snapshot.notes.append("Hammerspoon：达到 100 个 Lua 文件扫描上限。"); break }
                guard let data = read(url, source: "Hammerspoon：\(url.lastPathComponent)", into: &snapshot), let text = String(data: data, encoding: .utf8) else { continue }
                snapshot.findings += Self.hammerspoonFindings(text: text, shortcut: shortcut, sourceURL: url)
            }
        }
    }

    static func hammerspoonFindings(text: String, shortcut: ShortcutSpec, sourceURL: URL) -> [Finding] {
        let stripped = stripLuaComments(text)
        let patterns = [#"hs\.hotkey\.(?:bind|new)\s*\(\s*\{([^}]*)\}\s*,\s*["']([^"']+)["']"#, #"mods\s*=\s*\{([^}]*)\}\s*,\s*key\s*=\s*["']([^"']+)["']"#]
        var result: [Finding] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
                guard let mr = Range(match.range(at: 1), in: stripped), let kr = Range(match.range(at: 2), in: stripped),
                      let code = ShortcutSpec.keyCode(named: String(stripped[kr])) else { continue }
                let literal = String(stripped[mr])
                let tokens = literal.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
                guard let flags = ShortcutSpec.modifiers(named: tokens), ShortcutSpec(keyCode: code, modifiers: flags) == shortcut else { continue }
                let line = stripped[..<Range(match.range, in: stripped)!.lowerBound].filter { $0 == "\n" }.count + 1
                result.append(Finding(id: "hs-\(sourceURL.path)-\(line)", level: .conditionalConfiguration,
                    application: AppIdentity.known("Hammerspoon", bundleID: "org.hammerspoon.Hammerspoon"), title: "Lua 源码中的组合键 · 第 \(line) 行",
                    detail: "识别到字面量快捷键声明；没有执行 Lua，因此未确认模块是否加载、是否被禁用或被运行时覆盖。变量生成的绑定不在静态扫描范围内。", sourceURL: sourceURL))
            }
        }
        return result
    }

    /// Keep newlines and quoted strings; skip short comments and Lua long comments.
    static func stripLuaComments(_ source: String) -> String {
        let chars = Array(source)
        var result = "", i = 0, quote: Character?
        while i < chars.count {
            if let q = quote {
                result.append(chars[i])
                if chars[i] == "\\", i + 1 < chars.count { i += 1; result.append(chars[i]) }
                else if chars[i] == q { quote = nil }
                i += 1; continue
            }
            if chars[i] == "\"" || chars[i] == "'" { quote = chars[i]; result.append(chars[i]); i += 1; continue }
            if chars[i] == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                i += 2
                var j = i, equals = 0
                if j < chars.count, chars[j] == "[" {
                    j += 1
                    while j < chars.count, chars[j] == "=" { equals += 1; j += 1 }
                    if j < chars.count, chars[j] == "[" {
                        i = j + 1
                        let close = Array("]" + String(repeating: "=", count: equals) + "]")
                        while i < chars.count {
                            if i + close.count <= chars.count, Array(chars[i..<(i + close.count)]) == close { i += close.count; break }
                            result.append(chars[i] == "\n" ? "\n" : " "); i += 1
                        }
                        continue
                    }
                }
                while i < chars.count, chars[i] != "\n" { result.append(" "); i += 1 }
                continue
            }
            result.append(chars[i]); i += 1
        }
        return result
    }

    private func knownPreferences(_ shortcut: ShortcutSpec, directory: URL? = nil, into snapshot: inout DetectionSnapshot) {
        let apps = [("Rectangle", "com.knollsoft.Rectangle"), ("Maccy", "org.p0deje.Maccy"), ("Raycast", "com.raycast.macos"), ("MonitorControl", "me.guillaumeb.MonitorControl")]
        for (name, bundle) in apps {
            let url = (directory ?? home.appendingPathComponent("Library/Preferences")).appendingPathComponent("\(bundle).plist")
            guard let data = read(url, source: "\(name) 快捷键偏好", into: &snapshot),
                  let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
            for (key, raw) in root {
                if bundle == "com.raycast.macos", key == "raycastGlobalHotkey", let encoded = raw as? String,
                   Self.raycastShortcut(encoded) == shortcut {
                    snapshot.findings.append(Finding(id: "raycast-global", level: .configuration, application: .known(name, bundleID: bundle), title: "打开 Raycast", detail: "Raycast 的全局唤起快捷键偏好匹配该组合。未修改设置，仍需结合实时结果确认当前派发。", sourceURL: url))
                    continue
                }
                var value = raw as? [String: Any]
                if key.hasPrefix("KeyboardShortcuts_"), let string = raw as? String, let data = string.data(using: .utf8) {
                    value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
                guard let value, let code = value["keyCode"] as? NSNumber, code.uint64Value <= UInt64(UInt16.max),
                      let mods = (value["modifierFlags"] ?? value["modifiers"]) as? NSNumber,
                      ShortcutSpec(keyCode: code.uint16Value, modifiers: mods.uint64Value) == shortcut else { continue }
                snapshot.findings.append(Finding(id: "prefs-\(bundle)-\(key)", level: .configuration, application: .known(name, bundleID: bundle), title: "快捷键偏好：\(key)", detail: "偏好文件的键码与修饰键匹配；未确认软件当前是否加载这项绑定。仅识别公开的 keyCode/modifierFlags 格式。", sourceURL: url))
            }
        }
    }

    static func raycastShortcut(_ encoded: String) -> ShortcutSpec? {
        let parts = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }), let last = parts.last, let code = UInt16(last), code <= 127,
              let modifiers = ShortcutSpec.modifiers(named: Array(parts.dropLast())), modifiers != 0 else { return nil }
        return ShortcutSpec(keyCode: code, modifiers: modifiers)
    }

    private func listeners(into snapshot: inout DetectionSnapshot) {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { snapshot.notes.append("键盘监听器枚举失败。"); return }
        snapshot.checkedSources.append("系统当前键盘事件过滤器")
        guard count > 0 else { return }
        let capacity = min(count + 16, 4096)
        let records = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
        defer { records.deallocate() }
        var copied: UInt32 = 0
        guard CGGetEventTapList(capacity, records, &copied) == .success else { snapshot.notes.append("监听器列表在扫描时发生变化，请重新查询。"); return }
        var emitted = Set<Int32>()
        for index in 0..<Int(min(copied, capacity)) {
            let tap = records[index]
            guard tap.enabled, tap.tappingProcess > 0, tap.tappingProcess != getpid(),
                  tap.eventsOfInterest & ((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)) != 0,
                  tap.options.rawValue & CGEventTapOptions.listenOnly.rawValue == 0,
                  emitted.insert(tap.tappingProcess).inserted else { continue }
            snapshot.findings.append(Finding(id: "tap-\(tap.tappingProcess)", level: .listener, application: .process(tap.tappingProcess), title: "运行中的键盘事件过滤器", detail: "系统显示此进程启用了可修改或拦截键盘事件的监听器。API 不提供它匹配的组合键；这不是它占用当前快捷键的证据。"))
        }
    }
}
