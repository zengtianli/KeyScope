import AppKit
import Foundation

/// Agent-facing command line (`keyscope`), compiled into the same KeyScope executable and reached through
/// Contents/Resources/bin/keyscope. It calls the Detection layer the window uses: `scan` is 手动选择 →
/// 查询此组合 (ShortcutDetector.scan), `keys` is the key picker (ShortcutSpec), `status` is the permission
/// card, `detect` (DetectCommand.swift) is 开始检测, `update check` is the window's 检查更新 and `update install` its
/// 升级到新版… (shared layer, through ProductLifecycle; the upgrade is the one command that writes, and only with --yes).
/// Nothing in this file installs a keyboard tap, opens a window, requests a permission, posts a key event or writes
/// a file. `status` asks a running window one question (WindowPermission) and stores nothing.
enum KeyScopeCLI {
    static let commandName = "keyscope"
    static let schema = 1
    static let helpURL = "https://keyscope.tianli.cyou/#help"
    static let inputMonitoringSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    /// Test hook: makes the commands treat Input Monitoring as missing. It can only turn detection off.
    static let denyInputMonitoringVariable = "KEYSCOPE_DENY_INPUT_MONITORING"

    enum ExitCode {
        static let ok: Int32 = 0
        static let failure: Int32 = 1
        static let usage: Int32 = 2
        static let timeout: Int32 = 3
        static let noPermission: Int32 = 77
        /// Shell convention for a run ended by a signal: 130 for SIGINT (Ctrl-C), 143 for SIGTERM.
        static func interrupted(by signal: Int32) -> Int32 { 128 + signal }
    }

    /// True when the binary was started as `keyscope` (the in-bundle link or ~/.local/bin). Then it is only
    /// ever the read-only command line: no window, and no developer flags such as --ui-self-test.
    static func invokedAsCommand(_ executable: String) -> Bool {
        URL(fileURLWithPath: executable).lastPathComponent == commandName
    }

    /// Run as `keyscope`, every invocation is the CLI. Run as KeyScope, a first argument that is a word,
    /// `--…` or `-h` is the CLI; no argument or a single-dash launch flag (Finder, Xcode) opens the window.
    static func handles(executable: String, arguments: [String]) -> Bool {
        if invokedAsCommand(executable) { return true }
        guard let first = arguments.first else { return false }
        return first.hasPrefix("--") || first == "-h" || !first.hasPrefix("-")
    }

    static func main(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            writeErr(help(nil) + "\n")
            return ExitCode.usage
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--help", "-h", "help":
            if rest == ["--help"] || rest == ["-h"] { writeOut(help(command == "help" ? "help" : nil) + "\n"); return ExitCode.ok }
            guard rest.count <= 1 else { return usageError("help 最多接一个命令名", json: false) }
            guard rest.isEmpty || Self.topics.contains(rest[0]) else { return usageError("没有「\(rest[0])」这个命令", json: false) }
            writeOut(help(rest.first) + "\n")
            return ExitCode.ok
        case "--version":
            guard rest.isEmpty else { return usageError("--version 不接参数", json: false) }
            writeOut("KeyScope \(HostBundle.current.version)\n")
            return ExitCode.ok
        case "--scan":
            return legacyScan(rest)
        case "version", "scan", "keys", "status", "detect", "update":
            if rest.contains("--help") || rest.contains("-h") {
                writeOut(help(command) + "\n")
                return ExitCode.ok
            }
            switch command {
            case "version": return version(rest)
            case "scan": return scan(rest)
            case "keys": return keys(rest)
            case "status": return status(rest)
            case "update": return ProductLifecycle.update(rest)
            default: return DetectCommand.run(rest)
            }
        default:
            return usageError(command.hasPrefix("-") ? "未知参数「\(command)」" : "未知命令「\(command)」", json: arguments.contains("--json"))
        }
    }

    static let topics = ["scan", "detect", "status", "keys", "update", "version", "help"]

    // MARK: - Output

    static func writeOut(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    static func writeErr(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }

    static func emitJSON(_ object: [String: Any]) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            writeOut("{\"ok\":false,\"error\":{\"code\":\"encoding_failed\",\"message\":\"JSON 编码失败\"}}\n")
            return
        }
        FileHandle.standardOutput.write(data)
        writeOut("\n")
    }

    /// A failed command: JSON callers get {"ok": false, "error": {...}} on stdout, the message also goes to stderr.
    @discardableResult
    static func fail(_ command: String, code: String, message: String, exit: Int32, json: Bool, extra: [String: Any] = [:]) -> Int32 {
        writeErr("keyscope: \(message)\n")
        if json {
            var object: [String: Any] = ["ok": false, "schema": schema, "command": command, "error": ["code": code, "message": message]]
            object.merge(extra) { _, new in new }
            emitJSON(object)
        }
        return exit
    }

    static func usageError(_ message: String, json: Bool, command: String = "usage") -> Int32 {
        writeErr("keyscope: \(message)\n用法：keyscope <scan|detect|status|keys|update|version|help> …；keyscope help 查看全部说明。\n")
        if json {
            emitJSON(["ok": false, "schema": schema, "command": command, "error": ["code": "usage", "message": message]])
        }
        return ExitCode.usage
    }

    // MARK: - Arguments

    struct Arguments {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var json: Bool { flags.contains("--json") }
    }

    /// Strict parsing: unknown options and extra words are errors, never ignored.
    static func parseArguments(_ args: [String], flags: Set<String>, values: Set<String>, maxPositionals: Int) -> Result<Arguments, CLIError> {
        var parsed = Arguments()
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if !optionsEnded, arg == "--" { optionsEnded = true; continue }
            if !optionsEnded, arg.hasPrefix("-"), arg != "-" {
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                if flags.contains(name), parts.count == 1 { parsed.flags.insert(name); continue }
                if values.contains(name) {
                    if parts.count == 2 { parsed.values[name] = parts[1]; continue }
                    // `--key-code --json` must not take --json as the value (the caller would lose its JSON error).
                    guard index < args.count, !args[index].hasPrefix("--") else { return .failure("\(name) 需要一个值") }
                    parsed.values[name] = args[index]
                    index += 1
                    continue
                }
                return .failure("未知参数「\(arg)」")
            }
            parsed.positionals.append(arg)
        }
        guard parsed.positionals.count <= maxPositionals else {
            return .failure("多余的参数「\(parsed.positionals[maxPositionals])」（含空格的快捷键请加引号）")
        }
        return .success(parsed)
    }

    static func unsignedValue<T: FixedWidthInteger & UnsignedInteger>(_ text: String, as: T.Type) -> T? {
        let lower = text.lowercased()
        if lower.hasPrefix("0x") { return T(lower.dropFirst(2), radix: 16) }
        return T(lower, radix: 10)
    }

    // MARK: - Shared payloads

    /// JSON keeps every key; a missing value is null rather than an absent key.
    static func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    static func isoTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func shortcutJSON(_ shortcut: ShortcutSpec, input: String?) -> [String: Any] {
        ["keyCode": Int(shortcut.keyCode), "modifiers": NSNumber(value: shortcut.modifiers), "displayName": shortcut.displayName,
         "keyName": shortcut.keyName, "input": orNull(input)]
    }

    static func findingJSON(_ finding: Finding) -> [String: Any] {
        let app = finding.application
        let source: Any = orNull(finding.sourceURL.map { $0.isFileURL ? $0.path : $0.absoluteString })
        return ["id": finding.id, "level": finding.level.rawValue, "levelLabel": finding.level.label,
                "primary": finding.level.isPrimary, "definite": finding.level.isDefinite,
                "application": ["name": app.name, "pid": orNull(app.pid.map { Int($0) }),
                                "bundleID": orNull(app.bundleID), "bundlePath": orNull(app.bundleURL?.path),
                                "isRunning": app.isRunning],
                "title": finding.title, "detail": finding.detail, "source": source,
                "sourceIsFile": finding.sourceURL?.isFileURL ?? false]
    }

    /// The window's result area as data: verdict headline, primary findings, clues, notes, checked sources.
    static func reportJSON(_ snapshot: DetectionSnapshot, command: String, input: String?, secureInput: Bool) -> [String: Any] {
        let verdict = snapshot.verdict
        return ["ok": true, "schema": schema, "command": command,
                "shortcut": shortcutJSON(snapshot.shortcut, input: input),
                "verdict": ["code": verdict.rawValue, "headline": verdict.headline],
                "receivedKey": snapshot.receivedKey, "secureInput": secureInput,
                "observedAt": isoTime(snapshot.observedAt),
                "counts": ["findings": snapshot.findings.count, "primary": snapshot.primaryFindings.count,
                           "clues": snapshot.listenerFindings.count, "checkedSources": snapshot.checkedSources.count],
                "findings": snapshot.findings.map(findingJSON),
                "notes": snapshot.notes, "checkedSources": snapshot.checkedSources]
    }

    static func reportText(_ snapshot: DetectionSnapshot) -> String {
        var lines = ["\(snapshot.shortcut.displayName) · \(snapshot.verdict.headline)"]
        for finding in snapshot.primaryFindings {
            lines.append("  [\(finding.level.label)] \(finding.application.name)：\(finding.title)")
            lines.append("    \(finding.detail)")
            if let url = finding.sourceURL { lines.append("    位置：\(url.isFileURL ? url.path : url.absoluteString)") }
        }
        if snapshot.primaryFindings.isEmpty {
            lines.append("  没有发现可明确归属的绑定。部分软件直接过滤按键，可查看下面的排查线索。")
        }
        let clues = snapshot.listenerFindings
        if !clues.isEmpty {
            lines.append("排查线索（\(clues.count) 条；仅凭监听行为，不能判定它占用了这个快捷键）：")
            for finding in clues {
                lines.append("  [\(finding.level.label)] \(finding.application.name)" + (finding.application.pid.map { "（PID \($0)）" } ?? ""))
            }
        }
        if !snapshot.notes.isEmpty {
            lines.append("说明：")
            lines += snapshot.notes.map { "  - \($0)" }
        }
        if !snapshot.checkedSources.isEmpty { lines.append("已检查：" + snapshot.checkedSources.joined(separator: "、")) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func inputMonitoringGranted() -> Bool {
        if ProcessInfo.processInfo.environment[denyInputMonitoringVariable] == "1" { return false }
        return CGPreflightListenEventAccess()
    }

    // MARK: - Commands

    /// Legacy `KeyScope --scan <keyCode> <modifierFlags>`: byte-for-byte the 1.0.x output (acceptance and
    /// perf depend on it); now also rejects trailing arguments instead of ignoring them.
    static func legacyScan(_ args: [String]) -> Int32 {
        guard args.count == 2, let key = UInt16(args[0]), let modifiers = UInt64(args[1]) else {
            writeErr("用法：KeyScope --scan <keyCode 0-65535> <modifierFlags>（新写法：keyscope scan ctrl+g --json）\n")
            return ExitCode.usage
        }
        let result = ShortcutDetector().scan(ShortcutSpec(keyCode: key, modifiers: modifiers))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result) else { writeErr("KeyScope: 结果编码失败\n"); return ExitCode.failure }
        FileHandle.standardOutput.write(data)
        writeOut("\n")
        return ExitCode.ok
    }

    /// Reads the shortcut from `<shortcut>` or `--key-code/--modifiers`. Shared by scan and detect.
    static func shortcut(from parsed: Arguments) -> Result<(ShortcutSpec, String?)?, CLIError> {
        let keyCodeText = parsed.values["--key-code"], modifiersText = parsed.values["--modifiers"]
        if let text = parsed.positionals.first {
            guard keyCodeText == nil, modifiersText == nil else { return .failure("快捷键与 --key-code/--modifiers 只能二选一") }
            switch ShortcutSpec.parse(text) {
            case .success(let spec): return .success((spec, text))
            case .failure(let error): return .failure(CLIError(message: error.message))
            }
        }
        guard let keyCodeText else {
            return modifiersText == nil ? .success(nil) : .failure("--modifiers 需要与 --key-code 一起使用")
        }
        guard let code = unsignedValue(keyCodeText, as: UInt16.self) else { return .failure("--key-code 须为 0-65535（十进制或 0x 十六进制）") }
        guard let modifiers = unsignedValue(modifiersText ?? "0", as: UInt64.self) else { return .failure("--modifiers 须为 CGEventFlags 数值，如 262144（⌃）") }
        return .success((ShortcutSpec(keyCode: code, modifiers: modifiers), nil))
    }

    static func scan(_ args: [String]) -> Int32 {
        let parsed: Arguments
        switch parseArguments(args, flags: ["--json"], values: ["--key-code", "--modifiers"], maxPositionals: 1) {
        case .success(let value): parsed = value
        case .failure(let error): return usageError(error.message, json: args.contains("--json"), command: "scan")
        }
        let target: (ShortcutSpec, String?)
        switch shortcut(from: parsed) {
        case .success(let value?): target = value
        case .success(nil): return usageError("scan 需要一个快捷键，例如 keyscope scan ctrl+g", json: parsed.json, command: "scan")
        case .failure(let error): return usageError(error.message, json: parsed.json, command: "scan")
        }
        let detector = ShortcutDetector()
        let snapshot = detector.scan(target.0)
        if parsed.json {
            emitJSON(reportJSON(snapshot, command: "scan", input: target.1, secureInput: detector.secureInputEnabled))
        } else {
            writeOut(reportText(snapshot))
        }
        return ExitCode.ok
    }

    static func keys(_ args: [String]) -> Int32 {
        let parsed: Arguments
        switch parseArguments(args, flags: ["--json"], values: [], maxPositionals: 0) {
        case .success(let value): parsed = value
        case .failure(let error): return usageError(error.message, json: args.contains("--json"), command: "keys")
        }
        var inputNames: [UInt16: [String]] = [:]
        for (name, code) in ShortcutSpec.keyAliases { inputNames[code, default: []].append(name) }
        for (name, code) in ShortcutSpec.inputKeySynonyms { inputNames[code, default: []].append(name) }
        let keys = ShortcutSpec.selectableKeys
        if parsed.json {
            let keyRows: [[String: Any]] = keys.map { key in
                ["code": Int(key.code), "hex": String(format: "0x%02X", key.code), "name": key.name,
                 "aliases": (inputNames[key.code] ?? []).sorted()]
            }
            let modifierRows: [[String: Any]] = ShortcutSpec.modifierAliases.map { entry in
                var row: [String: Any] = ["symbol": entry.symbol, "flags": NSNumber(value: entry.flags), "names": entry.names]
                if entry.names == ["hyper"] { row["cliAccepted"] = false; row["note"] = ShortcutSpec.ParseError.ambiguousHyper.message }
                else { row["cliAccepted"] = true }
                return row
            }
            emitJSON(["ok": true, "schema": schema, "command": "keys", "count": keys.count, "keys": keyRows,
                      "modifiers": modifierRows,
                      "modifierInputSynonyms": ShortcutSpec.inputModifierSynonyms,
                      "grammar": ShortcutSpec.inputExamples,
                      "notes": ["最后一个 + 之后是按键，之前是修饰键；左右修饰键不区分。",
                                "按物理键位匹配，字母标记采用美式键盘。",
                                "结果里的 displayName（如 ⌃ Keypad +）可原样传回；Keypad + 也可写 keypad_plus 或 0x45。"]])
            return ExitCode.ok
        }
        var lines = ["按键（\(keys.count) 个，与窗口「手动选择」相同；名称不区分大小写，也可写 0x 键码）："]
        for key in keys {
            let aliases = (inputNames[key.code] ?? []).sorted()
            let code = String(format: "0x%02X  %3d", key.code, key.code)
            lines.append("  " + key.name.padding(toLength: 15, withPad: " ", startingAt: 0) + code + (aliases.isEmpty ? "" : "  " + aliases.joined(separator: ", ")))
        }
        lines.append("修饰键：")
        for entry in ShortcutSpec.modifierAliases where entry.names != ["hyper"] {
            lines.append("  \(entry.symbol.padding(toLength: 3, withPad: " ", startingAt: 0)) " + entry.names.joined(separator: ", "))
        }
        lines.append("  另可写 opt、right-cmd、left-option 等（左右不区分）。hyper 含义因工具而异，不接受。")
        lines.append("写法示例：" + ShortcutSpec.inputExamples.joined(separator: "、") + "（结果里的显示名可原样传回）")
        writeOut(lines.joined(separator: "\n") + "\n")
        return ExitCode.ok
    }

    static func version(_ args: [String]) -> Int32 {
        let parsed: Arguments
        switch parseArguments(args, flags: ["--json"], values: [], maxPositionals: 0) {
        case .success(let value): parsed = value
        case .failure(let error): return usageError(error.message, json: args.contains("--json"), command: "version")
        }
        let host = HostBundle.current
        if parsed.json {
            emitJSON(["ok": true, "schema": schema, "command": "version", "name": "KeyScope", "version": host.version,
                      "build": orNull(host.build), "bundleID": orNull(host.bundleID),
                      "bundlePath": orNull(host.appURL?.path), "executable": orNull(host.executableURL?.path)])
        } else {
            writeOut("KeyScope \(host.version)\n")
        }
        return ExitCode.ok
    }

    static func status(_ args: [String]) -> Int32 {
        let parsed: Arguments
        switch parseArguments(args, flags: ["--json"], values: [], maxPositionals: 0) {
        case .success(let value): parsed = value
        case .failure(let error): return usageError(error.message, json: args.contains("--json"), command: "status")
        }
        let host = HostBundle.current
        let granted = inputMonitoringGranted()
        let simulated = ProcessInfo.processInfo.environment[denyInputMonitoringVariable] == "1"
        let secure = ShortcutDetector().secureInputEnabled
        let own = getpid()
        let windows = NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID ?? "cyou.tianli.keyscope")
            .filter { $0.processIdentifier != own && !$0.isTerminated }.map { Int($0.processIdentifier) }.sorted()
        // The window's 正在检测 / 未在监听 indicator, read from the system tap list (nil when it cannot be read).
        let tapStates = windows.map { ShortcutDetector.ownsKeyboardTap(pid: pid_t($0)) }
        let listening: Bool? = tapStates.contains(true) ? true : (tapStates.contains { $0 == nil } ? nil : false)
        let subject = "调用本命令的程序（通常是终端或 Agent 宿主）；macOS 把输入监控记在它名下，不是 KeyScope.app 本身"
        // KeyScope.app's own grant and its permission card: only a window process can read them, so a running window
        // is asked (WindowPermission). No window, no question — and no waiting.
        let onTestChannel = WindowPermission.testChannel != nil
        let answers = windows.isEmpty && !onTestChannel ? [] : WindowPermission.ask(onTestChannel ? [] : windows.map { Int32($0) })
        let window = answers.first
        let ownState = window != nil ? "answered" : (windows.isEmpty && !onTestChannel ? "window_not_running" : "no_answer")
        let ownSubject = "KeyScope.app 自己名下的那份，由运行中的窗口进程现查并回答；窗口未运行或没有回答时命令读不到（null）"
        if parsed.json {
            var permission: [String: Any] = ["granted": granted, "subject": subject, "requiredBy": ["detect"],
                                             "settingsURL": inputMonitoringSettingsURL]
            if simulated { permission["simulatedDenied"] = true }
            emitJSON(["ok": true, "schema": schema, "command": "status",
                      "app": ["name": "KeyScope", "version": host.version, "build": orNull(host.build),
                              "bundleID": orNull(host.bundleID), "bundlePath": orNull(host.appURL?.path),
                              "executable": orNull(host.executableURL?.path)],
                      "inputMonitoring": permission, "secureInput": secure,
                      "window": ["running": !windows.isEmpty, "pids": windows, "listening": orNull(listening),
                                 "inputMonitoring": ["state": ownState, "granted": orNull(window?.granted),
                                                     "permissionCard": orNull(window?.cardVisible), "pid": orNull(window.map { Int($0.pid) }),
                                                     "answeredBy": answers.map { Int($0.pid) }, "subject": ownSubject]],
                      "helpURL": helpURL])
        } else {
            let build = host.build.map { " (\($0))" } ?? ""
            let ownLine: String
            if let window { ownLine = (window.granted ? "已允许" : "未允许") + "，权限卡" + (window.cardVisible ? "显示中" : "未显示") }
            else if ownState == "window_not_running" { ownLine = "读不到：窗口未运行（这一份只有窗口进程能回答）" }
            else { ownLine = "读不到：窗口没有在 \(Int(WindowPermission.timeout)) 秒内回答（旧版本的窗口不会回答）" }
            writeOut("""
            KeyScope \(host.version)\(build) · \(host.appURL?.path ?? "未在 App 包内运行")
            输入监控（记在调用方名下，通常是终端或 Agent 宿主）：\(granted ? "已允许，detect 可用" : "未允许，detect 不可用；scan 不需要此权限")\(simulated ? "（测试开关模拟）" : "")
            安全键盘输入：\(secure ? "开启中，实时按键可能无法观察" : "未开启")
            窗口：\(windows.isEmpty ? "未运行" : "运行中（PID " + windows.map(String.init).joined(separator: ", ") + "），" + (listening.map { $0 ? "正在检测" : "未在监听" } ?? "监听状态读不到"))
            KeyScope 自己名下的输入监控（窗口进程回答）：\(ownLine)
            输入监控设置：\(inputMonitoringSettingsURL)

            """)
        }
        return ExitCode.ok
    }

    // MARK: - Help

    static func help(_ topic: String?) -> String {
        switch topic {
        case "scan":
            return """
            keyscope scan — 查询一个快捷键：系统绑定、已知软件配置与正在过滤键盘的程序（窗口里的「手动选择 → 查询此组合」）

            用法：
              keyscope scan <快捷键> [--json]
              keyscope scan --key-code <0-65535> [--modifiers <CGEventFlags>] [--json]

            <快捷键>：ctrl+g、cmd+shift+4、right-cmd+b、ctrl+page up、⌃⇧G、f5、ctrl+0x05，或结果里的显示名（keyscope keys 列出全部写法）
            --json：{"ok": true, "shortcut", "verdict": {"code", "headline"}, "findings": [...], "notes", "checkedSources", ...}
              verdict.code：recipientObserved（找到接收软件）| relatedBinding（找到相关绑定）| unconfirmed（暂未确认接收软件）
              findings[].primary=false 的是排查线索（监听器、相邻事件），不能据此判定占用。
            只读，不需要输入监控权限，不安装键盘监听。退出码：0 已完成查询（有无发现都是 0）；2 参数错误。
            """
        case "detect":
            return """
            keyscope detect — 等待真人按下组合键，报告系统把它派发给了哪个软件（窗口里的「开始检测」）

            用法：
              keyscope detect [<快捷键>] [--timeout <1-120 秒，默认 15>] [--json] [--trace]
              keyscope detect --key-code <0-65535> [--modifiers <CGEventFlags>] [--timeout …] [--json] [--trace]

            不给快捷键时锁定第一个含 ⌃/⌥/⌘ 的组合或功能键；给出时只观察该组合（普通字母与 ⇧+字母属于文字输入，不接受）。
            需要真人在键盘上按键；Agent 不能也不应合成按键。收到按键 0.25 秒后自动停止，并附带与 scan 相同的配置结果。
            需要输入监控权限，macOS 把它记在调用方（终端或 Agent 宿主）名下；没有权限时立即退出 77，不弹授权。
            只读监听（listenOnly），不改写或吞掉按键，不记录普通文字；--trace 把热键派发诊断逐行写到 stderr。
            --json 失败对象同样带 shortcut（未指定组合时为 null）与 receivedKey:false。
            退出码：0 收到按键；3 超时未收到；77 没有输入监控权限；130 Ctrl-C（SIGINT）/ 143 SIGTERM 中断；1 监听中断；2 参数错误。
            """
        case "status":
            return """
            keyscope status — 版本与安装位置、输入监控权限（调用方的，以及 KeyScope 窗口自己的）、安全键盘输入、窗口是否在运行、是否正在检测

            用法：keyscope status [--json]
            --json：{"ok": true, "app": {"version", "build", "bundlePath", …}, "inputMonitoring": {"granted", "subject", "settingsURL", …},
                     "secureInput", "window": {"running", "pids", "listening",
                                               "inputMonitoring": {"state", "granted", "permissionCard", "pid", "answeredBy", "subject"}}, "helpURL"}
              window.listening 对应窗口的「正在检测 / 未在监听」：窗口进程此刻是否开着键盘监听（读系统的监听器列表；读不到时为 null）。
              inputMonitoring.granted 是调用方（终端或 Agent 宿主）的权限，即 detect 用的那份。
              window.inputMonitoring 是 KeyScope.app 自己名下的那份，对应窗口的权限卡。macOS 按进程归属记这项权限，命令进程读不到，
                所以由运行中的窗口回答：granted 是窗口进程此刻现查的结果（与「重新检查权限」同一个调用，不弹授权）；
                permissionCard 是窗口此刻是否显示「首次使用：允许输入监控」（按窗口上次检查的结果画，可能晚于 granted）。
                state：answered（窗口已回答）| window_not_running（窗口未运行，granted 与 permissionCard 为 null，不等待）|
                       no_answer（窗口在运行但 \(Int(WindowPermission.timeout)) 秒内没回答，例如旧版本的窗口，同样为 null）。
                多个窗口实例时 granted、permissionCard、pid 取 PID 最小的那个，answeredBy 列出全部回答者。
                窗口从访达、Dock 或 open 启动时这一份记在 KeyScope.app 名下；从终端直接执行可执行文件启动的窗口，读到的是那个终端的。
            只读：不申请权限、不写文件；问窗口只是一问一答，不改变窗口显示的内容。输入监控设置：\(inputMonitoringSettingsURL)
            """
        case "update":
            return """
            keyscope update — 检查更新与升级（窗口 KeyScope 菜单的「检查更新…」，「配置与更新…」窗口里的「检查更新」、结果一行与「升级到新版…」）

            用法：
              keyscope update check [--json]
              keyscope update install --yes [--dry-run] [--json]

            update check：\(ProductLifecycle.updateSummary)
            update install：\(ProductLifecycle.installSummary)
            KeyScope 的发行渠道是公开的 GitHub 发行记录（zengtianli/KeyScope）：两条命令都匿名联网读一次最新发行，不带任何本机数据；
            install 在有新版并确认后，另从这条发行记录下载安装包。
            update check --json：{"ok": true, "schema": 1, "command": "update check", "current": {"version", "build"}, "source": {"kind", "repository"},
                     "latest": {"version", "build", "download_url", "release_url", "sha256", "size_bytes", "channel"},
                     "update_available", "state", "message", "upgrade": {"in_app", "button", "how", "download_url", "command"}}
              state：update_available（有新版）| up_to_date（已是此渠道最新版）| ahead_of_channel（本机版本高于此渠道的正式发行）
              upgrade.how 写明怎么升级；upgrade.command 是可直接运行的升级命令（这个安装位置或渠道不能由命令替换时为 null，窗口里是「下载新版…」）。
              check 只读：不下载、不安装、不写文件、不改任何设置。
            update install --json：{"ok": true, "schema": 1, "command": "update install", "current", "latest", "source", "app_running", "installed", "state", "message", …}
              没有新版：installed 为 false，state 为 up_to_date 或 ahead_of_channel，什么都不做（带不带 --yes 都一样）。
              --dry-run（有新版时）：另有 dry_run: true、would_install {from, to}、installation、will_quit_app、will_relaunch；不下载、不替换。
              装上：installed 为 true，state 为 installed，另有 previous {version, build}、current（换好后磁盘上的版本）、backup（成功为 null）、
                old_app_cleanup（"trashed"：旧 App 已移到废纸篓）、relaunched（原来在运行的窗口是否已重新打开）。
              有新版但没带 --yes：什么都不做，error.code 为 confirmation_required。
            失败：{"ok": false, "schema": 1, "command", "error": {"code", "message"}}，原因同时写到 stderr；check_incomplete 另带 current、source，
              读到发行记录之后的失败（manual_install 到 cleanup_failed）另带 current、latest、source、app_running。error.code：
              check_incomplete（没读到发行记录：断网、限流等）· manual_install（这个安装位置或渠道不能由命令替换，带 download_url）·
              needs_product_installer（发行记录要求专用安装事务）· upgrade_failed（下载或验证未通过，当前 App 未动）·
              app_busy（运行中的 KeyScope 没有退出，未替换）· replace_failed（替换未完成，旧版已保留或已回滚）·
              cleanup_failed（新版已装上并验证，旧包清理失败并保留）· confirmation_required（缺 --yes）· usage（参数不对）
            退出码：0 已读到发行记录且没有出错（有没有新版都是 0）；1 未完成（上面除最后两个以外的 error.code）；
                    2 参数错误（usage），或有新版但缺 --yes（confirmation_required）。
            update install 是 KeyScope 唯一会写东西的命令：它替换 KeyScope.app 本身（运行中的窗口先退出、换好再重开），不改快捷键，
            不动别的软件的配置；下载与验证最长等 330 秒。它不弹窗、不抢焦点、不申请权限。
            KeyScope 没有可迁移的配置，所以没有 config 命令（窗口里也没有「配置」这一组）。
            """
        case "keys":
            return """
            keyscope keys — 列出可用按键名（与窗口「手动选择」的列表相同）、键码与修饰键写法

            用法：keyscope keys [--json]
            """
        case "version":
            return """
            keyscope version — 打印版本（读取所在 App 包的 Info.plist，经 ~/.local/bin 链接调用时同样准确）

            用法：keyscope version [--json]   （兼容：keyscope --version）
            """
        case "help":
            return "keyscope help [<命令>] — 显示总说明或某个命令的说明（scan、detect、status、keys、update、version）。"
        default:
            return """
            KeyScope 快捷键侦探的命令行：查询一个快捷键被哪个软件占用或接收（只读）

            用法：
              keyscope scan <快捷键> [--json]        查系统绑定、已知软件配置与键盘过滤器（窗口的「手动选择 → 查询此组合」「刷新结果」）
              keyscope detect [<快捷键>] [--timeout 秒] [--json] [--trace]
                                                    等真人按下组合键，报告实际接收的软件（窗口的「开始检测」；超时或 Ctrl-C 即「停止检测」）
              keyscope status [--json]               版本、输入监控权限（调用方的，以及 KeyScope 窗口自己的）、安全键盘输入、窗口是否在运行、是否正在检测
              keyscope keys [--json]                 按键名、键码与修饰键写法
              keyscope update check [--json]         \(ProductLifecycle.updateSummary)
              keyscope update install --yes [--dry-run] [--json]
                                                    \(ProductLifecycle.installSummary)
              keyscope version [--json]              版本
              keyscope help [<命令>]                 某个命令的详细说明

            读命令：scan、detect、status、keys、update check、version、help。写命令：update install（只替换 KeyScope.app 本身，要带 --yes；
              产品没有可改的设置，别的命令不写任何文件或状态）。
            快捷键写法：ctrl+g、cmd+shift+4、right-cmd+b、ctrl+page up、⌃⇧G、f5、ctrl+0x05；结果里的显示名可原样传回
            scan 与 detect 也接受 --key-code <键码> [--modifiers <CGEventFlags>]；detect --trace 把派发诊断写到 stderr
            --json 输出稳定对象 {"ok": true, "schema": 1, "command": …}；失败时 {"ok": false, "error": {"code", "message"}}。
            退出码：0 成功；1 内部错误，或 update check / update install 未完成（error.code 见 keyscope help update）；
                    2 参数错误，或 update install 有新版但缺 --yes（error.code 为 confirmation_required）；
                    3 detect 超时未收到按键；77 没有输入监控权限（不会弹出授权）；130 / 143 detect 被 Ctrl-C / SIGTERM 中断。
            除 update install 外所有命令只读：不写文件、不改快捷键或配置。所有命令都不申请权限、不发送或合成按键。
            只有 update check 与 update install 联网（匿名读公开发行记录；install 确认后另下载安装包）。
            仅在窗口中（命令不做；相关路径与链接在读命令的结果里）：
              打开输入监控设置并授权（只能真人在系统设置里开；链接见 status 的 inputMonitoring.settingsURL）
              查看配置位置（在访达中显示）、打开系统设置（路径与链接见 scan 的 findings[].source）
              使用指南与官网（链接见最后一行）
              清空结果（命令不保留结果，每次查询独立输出）
              配置与更新窗口、显示主窗口、关闭、最小化、隐藏、退出
            要真人做：detect 等的那一下按键（窗口与命令都只读监听，不合成按键）。
            KeyScope 窗口自己名下的输入监控与权限卡：status 的 window.inputMonitoring，由运行中的窗口回答；窗口未运行时读不到（null）。
            兼容旧写法：KeyScope --scan <keyCode> <modifierFlags>、KeyScope --version。
            图形界面：open "\(HostBundle.current.appURL?.path ?? "/Applications/KeyScope.app")"（本命令所在的 App 包）
            使用指南：\(helpURL)
            """
        }
    }
}

/// A usage problem with a message for the person or agent; string literals convert directly.
struct CLIError: Error, ExpressibleByStringInterpolation {
    let message: String
    init(message: String) { self.message = message }
    init(stringLiteral value: String) { message = value }
    init(stringInterpolation: DefaultStringInterpolation) { message = String(stringInterpolation: stringInterpolation) }
}

/// The app bundle this executable lives in. Bundle.main does not resolve when the binary is started
/// through a symlink (~/.local/bin/keyscope → Contents/Resources/bin/keyscope → ../../MacOS/KeyScope)
/// and then reports no version, so the real executable path is resolved first.
struct HostBundle {
    let appURL: URL?
    let executableURL: URL?
    let info: [String: Any]

    static let current: HostBundle = {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else {
            return HostBundle(appURL: Bundle.main.bundleURL, executableURL: Bundle.main.executableURL, info: Bundle.main.infoDictionary ?? [:])
        }
        defer { free(resolved) }
        let executable = URL(fileURLWithPath: String(cString: resolved))
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return HostBundle(appURL: nil, executableURL: executable, info: [:])
        }
        return HostBundle(appURL: contents.deletingLastPathComponent(), executableURL: executable, info: info)
    }()

    var version: String { info["CFBundleShortVersionString"] as? String ?? "development" }
    var build: String? { info["CFBundleVersion"] as? String }
    var bundleID: String? { info["CFBundleIdentifier"] as? String }
}
