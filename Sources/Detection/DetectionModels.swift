import AppKit
import CoreGraphics
import Foundation

/// Physical macOS virtual key code; modifiers use CGEventFlags/NSEvent flags.
struct ShortcutSpec: Codable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt64
    static let modifierMask: UInt64 = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]).rawValue

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        // Function-key and arrow events carry the Fn flag as an OS annotation.
        self.modifiers = modifiers & Self.modifierMask & (Self.functionKeyCodes.contains(keyCode) || (123...126).contains(keyCode) ? ~CGEventFlags.maskSecondaryFn.rawValue : UInt64.max)
    }
    var keyName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }
    var displayName: String {
        var parts: [String] = []
        for (flag, name) in [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘"), (.maskSecondaryFn, "fn")]
            where modifiers & flag.rawValue != 0 { parts.append(name) }
        parts.append(keyName)
        return parts.joined(separator: " ")
    }
    var isSafeForFreeRecording: Bool {
        modifiers & CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue != 0 || Self.functionKeyCodes.contains(keyCode)
    }
    static let functionKeyCodes: Set<UInt16> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    static let keyNames: [UInt16: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",53:"Escape",64:"F17",65:"Keypad .",67:"Keypad *",69:"Keypad +",71:"Clear",75:"Keypad /",76:"Keypad Enter",78:"Keypad -",79:"F18",80:"F19",81:"Keypad =",82:"Keypad 0",83:"Keypad 1",84:"Keypad 2",85:"Keypad 3",86:"Keypad 4",87:"Keypad 5",88:"Keypad 6",89:"Keypad 7",90:"F20",91:"Keypad 8",92:"Keypad 9",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",114:"Help",115:"Home",116:"Page Up",117:"Forward Delete",118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"
    ]
    static var selectableKeys: [(code: UInt16, name: String)] {
        keyNames.map { (code: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Key names used by the supported configuration formats (Karabiner, skhd, Hammerspoon).
    static let keyAliases: [String: UInt16] = ["space":49,"spacebar":49,"return_or_enter":36,"return":36,"enter":36,"tab":48,"escape":53,"esc":53,"delete_or_backspace":51,"backspace":51,"delete_forward":117,"left_arrow":123,"left":123,"right_arrow":124,"right":124,"up_arrow":126,"up":126,"down_arrow":125,"down":125,"open_bracket":33,"close_bracket":30,"semicolon":41,"quote":39,"backslash":42,"comma":43,"period":47,"slash":44,"grave_accent_and_tilde":50,"hyphen":27,"equal_sign":24,"page_up":116,"page_down":121]
    static func keyCode(named name: String) -> UInt16? {
        let lower = name.lowercased()
        if let code = keyAliases[lower] { return code }
        if lower.hasPrefix("0x"), let code = UInt16(lower.dropFirst(2), radix: 16) { return code }
        return keyNames.first { $0.value.lowercased() == lower }?.key
    }
    static func cocoaModifiers(fromCarbon value: UInt64) -> UInt64 {
        var result: UInt64 = 0
        for (bit, flag): (UInt64, CGEventFlags) in [(256,.maskCommand),(512,.maskShift),(2048,.maskAlternate),(4096,.maskControl),(8192,.maskShift),(16384,.maskAlternate),(32768,.maskControl),(131072,.maskSecondaryFn)] where value & bit != 0 { result |= flag.rawValue }
        return result
    }
    /// Modifier words accepted in configuration files (lower-case), in display order. Left/right
    /// variants collapse to one flag: a shortcut does not distinguish the physical side.
    static let modifierAliases: [(symbol: String, flags: UInt64, names: [String])] = [
        ("⌃", CGEventFlags.maskControl.rawValue, ["ctrl", "control", "left_control", "right_control", "lctrl", "rctrl", "⌃"]),
        ("⌥", CGEventFlags.maskAlternate.rawValue, ["alt", "option", "left_option", "right_option", "lalt", "ralt", "⌥"]),
        ("⇧", CGEventFlags.maskShift.rawValue, ["shift", "left_shift", "right_shift", "lshift", "rshift", "⇧"]),
        ("⌘", CGEventFlags.maskCommand.rawValue, ["cmd", "command", "left_command", "right_command", "lcmd", "rcmd", "⌘"]),
        ("fn", CGEventFlags.maskSecondaryFn.rawValue, ["fn", "function"]),
        ("⌃⌥⇧⌘", CGEventFlags([.maskCommand,.maskShift,.maskControl,.maskAlternate]).rawValue, ["hyper"]),
    ]
    static func modifiers(named names: [String]) -> UInt64? {
        var value: UInt64 = 0
        for name in names {
            let lower = name.lowercased()
            if lower.isEmpty || lower == "none" { continue }
            guard let entry = modifierAliases.first(where: { $0.names.contains(lower) }) else { return nil }
            value |= entry.flags
        }
        return value
    }

    /// Typing conveniences for a shortcut given on the command line, on top of `keyAliases` and `keyNames`.
    /// Not used for configuration parsing, so scan results do not change.
    static let inputKeySynonyms: [String: UInt16] = [
        "keypad_decimal":65, "keypad_multiply":67, "keypad_plus":69, "keypad_divide":75, "keypad_enter":76, "keypad_minus":78, "keypad_equals":81,
        "keypad_0":82, "keypad_1":83, "keypad_2":84, "keypad_3":85, "keypad_4":86, "keypad_5":87, "keypad_6":88, "keypad_7":89, "keypad_8":91, "keypad_9":92,
        "forward_delete":117, "pageup":116, "pagedown":121, "grave":50, "backtick":50, "minus":27, "equal":24,
    ]
    static let inputModifierSynonyms: [String: String] = ["opt": "option"]
    /// Spellings shown to agents by `keyscope keys` and the help text; each one is checked by the self-tests.
    static let inputExamples = ["ctrl+g", "cmd+shift+4", "right-cmd+b", "ctrl+page up", "⌃⇧G", "⌃ G", "f5", "ctrl+0x05", "ctrl+keypad_plus", "⌃ Keypad +"]

    enum ParseError: Error, Equatable {
        case empty, ambiguousHyper, unknownModifier(String), unknownKey(String)
        var message: String {
            switch self {
            case .empty: return "没有给出快捷键，例如 ctrl+g、cmd+shift+4、⌃G 或 f5。"
            case .ambiguousHyper: return "hyper 在不同工具里含义不同（有的指 ⌃⌥⇧⌘，有的指 ⌘⌃⇧），请写出具体修饰键，例如 cmd+ctrl+shift+k。"
            case .unknownModifier(let name): return "无法识别的修饰键「\(name)」。可用 ctrl、alt/option、shift、cmd、fn，或 ⌃⌥⇧⌘；运行 keyscope keys 查看全部写法。"
            case .unknownKey(let name): return "无法识别的按键「\(name)」。运行 keyscope keys 查看按键名，或写虚拟键码，如 0x05。"
            }
        }
    }

    /// Parses a shortcut typed by a person or an agent: `ctrl+g`, `cmd+shift+4`, `right-cmd+b`, `ctrl+page up`,
    /// `⌃⇧G`, `⌃ G` (the displayName form) or `ctrl+0x05`. The last `+` part is the key. The one key whose name
    /// contains `+` is read first: a trailing `Keypad +` (displayName) or `keypad+` is the keypad plus, as are
    /// `keypad_plus` and `0x45`. Left/right sides collapse to one modifier. Every displayName parses back.
    static func parse(_ text: String) -> Result<ShortcutSpec, ParseError> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        for suffix in ["keypad +", "keypad+"] where trimmed.lowercased().hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count)) + "keypad_plus"
            break
        }
        var modifierWords: [String] = []
        var keyText: String
        if trimmed.contains("+") {
            let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let last = parts.last, !last.isEmpty, !parts.contains(where: \.isEmpty) else { return .failure(.unknownKey(trimmed)) }
            modifierWords = Array(parts.dropLast())
            keyText = last
        } else {
            keyText = trimmed
        }
        // Leading modifier symbols (⌃⇧G, ⌃ ⇧ G) and a leading "fn " word, as in displayName.
        let symbols: [Character: String] = ["⌃": "ctrl", "⌥": "alt", "⇧": "shift", "⌘": "cmd"]
        while let first = keyText.first {
            if let word = symbols[first] { modifierWords.append(word); keyText.removeFirst() }
            else if first == " " { keyText.removeFirst() }
            else if keyText.lowercased().hasPrefix("fn "), keyText.count > 3 { modifierWords.append("fn"); keyText.removeFirst(3) }
            else { break }
        }
        guard !keyText.isEmpty else { return .failure(.unknownKey(trimmed)) }
        var flags: UInt64 = 0
        for word in modifierWords {
            var name = word.lowercased().replacingOccurrences(of: "-", with: "_")
            if name == "hyper" { return .failure(.ambiguousHyper) }
            for side in ["left_", "right_"] where name.hasPrefix(side) { name.removeFirst(side.count) }
            name = inputModifierSynonyms[name] ?? name
            guard let value = modifiers(named: [name]), value != 0 else { return .failure(.unknownModifier(word)) }
            flags |= value
        }
        let keyLower = keyText.lowercased()
        guard let code = keyCode(named: keyText) ?? inputKeySynonyms[keyLower.replacingOccurrences(of: " ", with: "_")]
                ?? keyNames.first(where: { $0.value.lowercased().replacingOccurrences(of: " ", with: "_") == keyLower })?.key
        else { return .failure(.unknownKey(keyText)) }
        return .success(ShortcutSpec(keyCode: code, modifiers: flags))
    }
}

enum EvidenceLevel: String, Codable, CaseIterable {
    case observedRecipient, systemBinding, configuration, conditionalConfiguration, nearbyEvent, listener
    var label: String {
        switch self {
        case .observedRecipient: return "观察到接收软件"
        case .systemBinding: return "系统已启用绑定"
        case .configuration: return "匹配配置"
        case .conditionalConfiguration: return "条件配置线索"
        case .nearbyEvent: return "相邻事件线索"
        case .listener: return "可能拦截的监听器"
        }
    }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    /// Shown in the main result; listeners and nearby events are troubleshooting clues only.
    var isPrimary: Bool { self != .listener && self != .nearbyEvent }
    /// Evidence strong enough to name the shortcut's owner without conditions.
    var isDefinite: Bool { self == .observedRecipient || self == .systemBinding }
}

struct AppIdentity: Codable, Hashable {
    let name: String
    let pid: Int32?
    let bundleID: String?
    let bundleURL: URL?
    let isRunning: Bool

    init(name: String, pid: Int32? = nil, bundleID: String? = nil, bundleURL: URL? = nil, isRunning: Bool = false) {
        self.name = name; self.pid = pid; self.bundleID = bundleID; self.bundleURL = bundleURL; self.isRunning = isRunning
    }
    static func process(_ pid: Int32) -> AppIdentity {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return AppIdentity(name: app.localizedName ?? app.executableURL?.lastPathComponent ?? "进程 \(pid)", pid: pid, bundleID: app.bundleIdentifier, bundleURL: app.bundleURL, isRunning: !app.isTerminated)
        }
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        let path = count > 0 ? String(cString: bytes) : nil
        return AppIdentity(name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "进程 \(pid)", pid: pid, isRunning: kill(pid, 0) == 0)
    }
    static func known(_ name: String, bundleID: String) -> AppIdentity {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return process(app.processIdentifier)
        }
        return AppIdentity(name: name, bundleID: bundleID, bundleURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
    }
}

struct Finding: Codable, Identifiable, Hashable {
    let id: String
    let level: EvidenceLevel
    let application: AppIdentity
    let title: String
    let detail: String
    let sourceURL: URL?
    init(id: String = UUID().uuidString, level: EvidenceLevel, application: AppIdentity, title: String, detail: String, sourceURL: URL? = nil) {
        self.id = id; self.level = level; self.application = application; self.title = title; self.detail = detail; self.sourceURL = sourceURL
    }
}

struct DetectionSnapshot: Codable {
    let shortcut: ShortcutSpec
    var findings: [Finding]
    var notes: [String]
    var checkedSources: [String]
    let observedAt: Date
    var receivedKey: Bool = false
    var strongestFinding: Finding? { findings.min { $0.level.rank < $1.level.rank } }
    var observedRecipient: Finding? { findings.first { $0.level == .observedRecipient } }
    var primaryFindings: [Finding] { findings.filter { $0.level.isPrimary } }
    var listenerFindings: [Finding] { findings.filter { !$0.level.isPrimary } }
    /// The one result rule behind the window headline and the command line verdict.
    var verdict: DetectionVerdict {
        if observedRecipient != nil { return .recipientObserved }
        return primaryFindings.isEmpty ? .unconfirmed : .relatedBinding
    }
}

enum DetectionVerdict: String, Codable, CaseIterable {
    case recipientObserved, relatedBinding, unconfirmed
    var headline: String {
        switch self {
        case .recipientObserved: return "找到接收软件"
        case .relatedBinding: return "找到相关绑定"
        case .unconfirmed: return "暂未确认接收软件"
        }
    }
}
