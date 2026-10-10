import AppKit
import Foundation

/// `keyscope detect`: the window's 开始检测 for an agent working next to a person. It drives the same
/// ShortcutDetector (listen-only taps, first-safe-combination lock, 0.25 s auto-stop via onComplete) and is the
/// only command line code allowed to start listening. Without Input Monitoring it stops before start(), so no
/// permission prompt appears. It never synthesizes a key press: a person has to press the combination.
enum DetectCommand {
    static let defaultTimeout: Double = 15
    static let timeoutRange: ClosedRange<Double> = 1...120

    static func run(_ args: [String]) -> Int32 {
        typealias CLI = KeyScopeCLI
        let parsed: CLI.Arguments
        switch CLI.parseArguments(args, flags: ["--json", "--trace"], values: ["--timeout", "--key-code", "--modifiers"], maxPositionals: 1) {
        case .success(let value): parsed = value
        case .failure(let error): return CLI.usageError(error.message, json: args.contains("--json"), command: "detect")
        }
        let json = parsed.json
        var spec: ShortcutSpec?
        var input: String?
        switch CLI.shortcut(from: parsed) {
        case .success(let value): spec = value?.0; input = value?.1
        case .failure(let error): return CLI.usageError(error.message, json: json, command: "detect")
        }
        if let spec, !spec.isSafeForFreeRecording {
            return CLI.usageError("只能观察含 ⌃/⌥/⌘ 的组合或功能键；\(spec.displayName) 属于文字输入，KeyScope 不记录。", json: json, command: "detect")
        }
        var timeout = defaultTimeout
        if let text = parsed.values["--timeout"] {
            guard let value = Double(text), timeoutRange.contains(value) else {
                return CLI.usageError("--timeout 须为 1-120 秒", json: json, command: "detect")
            }
            timeout = value
        }
        // Every failure object names the requested combination (null for free recording) so an agent can match it.
        let failure: [String: Any] = ["receivedKey": false, "shortcut": spec.map { CLI.shortcutJSON($0, input: input) } ?? NSNull()]
        guard CLI.inputMonitoringGranted() else {
            return CLI.fail("detect", code: "input_monitoring_denied",
                message: "调用本命令的程序（终端或 Agent 宿主）没有输入监控权限，未开始监听，也不会弹出授权。请在 系统设置 → 隐私与安全性 → 输入监控 中允许它并重新打开；keyscope scan 不需要此权限。",
                exit: CLI.ExitCode.noPermission, json: json,
                extra: failure.merging(["settingsURL": CLI.inputMonitoringSettingsURL,
                        "inputMonitoring": ["granted": false, "subject": "调用本命令的程序（终端或 Agent 宿主）"]]) { _, new in new })
        }

        let detector = ShortcutDetector()
        var latest: DetectionSnapshot?
        var result: DetectionSnapshot?
        var interruption: String?
        var signalled: Int32?
        detector.onStatus = { [unowned detector] message in
            CLI.writeErr("keyscope: \(message)\n")
            if !detector.isListening, result == nil { interruption = message }
        }
        detector.onUpdate = { snapshot in
            latest = snapshot
            if snapshot.receivedKey { CLI.writeErr("keyscope: 已收到 \(snapshot.shortcut.displayName)，正在核对接收软件。\n") }
        }
        detector.onComplete = { snapshot in result = snapshot }
        if parsed.flags.contains("--trace") {
            detector.onDiagnostic = { record in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                if let data = try? encoder.encode(record) { CLI.writeErr(String(decoding: data, as: UTF8.self) + "\n") }
            }
        }
        // Ctrl-C / SIGTERM: stop listening and report (exit 128 + signal), instead of dying with taps pending.
        let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { signalled = number }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }

        guard detector.start(spec) else {
            return CLI.fail("detect", code: "listen_failed", message: interruption ?? "无法开始观察键盘。",
                            exit: CLI.ExitCode.failure, json: json, extra: failure)
        }
        let seconds = Int(timeout.rounded())
        CLI.writeErr("keyscope: " + (spec.map { "请在 \(seconds) 秒内按下 \($0.displayName)" } ?? "请在 \(seconds) 秒内按下要检查的组合键（含 ⌃/⌥/⌘ 或功能键）")
                     + "；按键仍会触发原来的功能。\n")
        let deadline = Date().addingTimeInterval(timeout)
        func waiting() -> Bool { result == nil && interruption == nil && signalled == nil }
        while waiting(), deadline.timeIntervalSinceNow > 0 {
            _ = CFRunLoopRunInMode(.defaultMode, min(deadline.timeIntervalSinceNow, 0.2), false)
        }
        // A key that arrived right at the deadline still gets its settle window.
        if waiting(), latest?.receivedKey == true {
            let grace = Date().addingTimeInterval(ShortcutDetector.completionDelay + 0.3)
            while waiting(), grace.timeIntervalSinceNow > 0 { _ = CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        }
        detector.stop()

        if let result {
            if json {
                CLI.emitJSON(CLI.reportJSON(result, command: "detect", input: input, secureInput: detector.secureInputEnabled))
            } else {
                CLI.writeOut(CLI.reportText(result))
            }
            return CLI.ExitCode.ok
        }
        if let signalled {
            return CLI.fail("detect", code: "interrupted", message: "已中断（信号 \(signalled)），监听已停止，未收到按键。",
                            exit: CLI.ExitCode.interrupted(by: signalled), json: json,
                            extra: failure.merging(["signal": Int(signalled)]) { _, new in new })
        }
        if let interruption {
            return CLI.fail("detect", code: "listening_interrupted", message: interruption, exit: CLI.ExitCode.failure, json: json,
                            extra: failure)
        }
        return CLI.fail("detect", code: "timeout", message: "\(seconds) 秒内没有收到可检查的组合键，监听已停止。",
                        exit: CLI.ExitCode.timeout, json: json, extra: failure.merging(["timeoutSeconds": timeout]) { _, new in new })
    }
}
