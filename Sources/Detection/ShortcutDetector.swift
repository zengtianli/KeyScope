import AppKit
import Carbon
import CoreGraphics
import Foundation

struct ObservationDiagnostic: Codable {
    let kind: String
    let keyTimestamp: UInt64?
    let eventTimestamp: UInt64?
    let targetPID: Int64?
    let correlation: String?
}

/// All methods and callbacks run on the main thread. Listening never consumes,
/// changes, registers, or posts a keyboard event. No text is retained or logged.
final class ShortcutDetector {
    var onUpdate: ((DetectionSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Called once per received shortcut, after listening has stopped: `completionDelay` after the
    /// latest update, so routing evidence that arrives just after the key press is merged first.
    var onComplete: ((DetectionSnapshot) -> Void)?
    static let completionDelay: TimeInterval = 0.25
    /// Opt-in test diagnostics contain only an explicitly selected shortcut's
    /// timestamp and associated system-hotkey routing metadata. No text.
    var onDiagnostic: ((ObservationDiagnostic) -> Void)?
    private(set) var isListening = false
    var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    var secureInputEnabled: Bool { IsSecureEventInputEnabled() }
    private var taps: [CFMachPort] = []
    private var sources: [CFRunLoopSource] = []
    private var target: ShortcutSpec?
    private var pending: PendingKey?
    private var currentFindings: [Finding] = []
    private var generation = 0
    private var scheduled: DispatchWorkItem?
    private var routeAvailable = false
    private var lastSnapshot: DetectionSnapshot?
    private var watchdog: Timer?
    private var lastSecureInput = false
    private var completion: DispatchWorkItem?

    private struct PendingKey {
        let shortcut: ShortcutSpec
        let timestamp: UInt64
        let generation: Int
        var findings: [Finding]
    }

    func scan(_ shortcut: ShortcutSpec) -> DetectionSnapshot {
        var result = ConfigurationScanner().scan(shortcut)
        if secureInputEnabled { result.notes.insert("macOS 正在使用安全键盘输入，实时按键可能无法被观察；关闭密码输入框或结束对应安全输入后重试。", at: 0) }
        return result
    }

    /// nil records only Ctrl/Option/Command combinations or function keys. Never asks for permission:
    /// without Input Monitoring it returns false before creating a tap, so no system prompt appears.
    @discardableResult func start(_ shortcut: ShortcutSpec? = nil) -> Bool {
        precondition(Thread.isMainThread)
        stop()
        guard inputMonitoringGranted else {
            onStatus?("尚未获得输入监控权限，未开始观察键盘；手动查询仍可使用。")
            return false
        }
        target = shortcut
        guard install(.cgSessionEventTap, mask: 1 << CGEventType.keyDown.rawValue) else {
            stop()
            onStatus?("无法观察键盘。请在系统设置 → 隐私与安全性 → 输入监控中允许 KeyScope，然后重新打开应用；手动查询仍可使用。")
            return false
        }
        routeAvailable = install(.cgAnnotatedSessionEventTap, mask: 1 << NSEvent.EventType.systemDefined.rawValue)
        isListening = true
        lastSecureInput = secureInputEnabled
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkListeningHealth() }
        timer.tolerance = 1
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
        if lastSecureInput {
            onStatus?("已开始，但系统安全输入可能阻止观察；结束密码输入后重试。")
        } else if !routeAvailable {
            onStatus?("按键观察已开始，但系统派发通路不可用；暂时只显示配置和监听器线索。")
        } else {
            onStatus?(shortcut.map { "正在观察 \($0.displayName)。按键仍会触发原来功能。" } ?? "请按下要检查的组合键。按键仍会触发原来功能。")
        }
        return true
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        scheduled?.cancel(); scheduled = nil
        completion?.cancel(); completion = nil
        generation += 1; pending = nil; lastSnapshot = nil; target = nil; currentFindings = []
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for tap in taps { CFMachPortInvalidate(tap) }
        sources.removeAll(); taps.removeAll()
        isListening = false; routeAvailable = false
    }

    deinit { stop() }

    /// Whether process `pid` owns an enabled key-down event tap right now — for the KeyScope window that is the
    /// time between 开始检测 and its stop (the 正在检测 / 未在监听 indicator). Reads the system tap list only:
    /// creates nothing, needs no permission. nil when the list cannot be read.
    static func ownsKeyboardTap(pid: pid_t) -> Bool? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return false }
        let capacity = min(count + 16, 4096)
        let records = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
        defer { records.deallocate() }
        var copied: UInt32 = 0
        guard CGGetEventTapList(capacity, records, &copied) == .success else { return nil }
        let keyDown: CGEventMask = 1 << CGEventType.keyDown.rawValue
        for index in 0..<Int(min(copied, capacity)) {
            let tap = records[index]
            if tap.enabled, tap.tappingProcess == pid, tap.eventsOfInterest & keyDown != 0 { return true }
        }
        return false
    }

    /// Free recording locks its first safe combination until stop/start. This
    /// also keeps unrelated app shortcuts from replacing the diagnostic result.
    func acceptShortcut(_ shortcut: ShortcutSpec) -> Bool {
        if let target { return target == shortcut }
        guard shortcut.isSafeForFreeRecording else { return false }
        target = shortcut
        return true
    }

    private func checkListeningHealth() {
        guard isListening else { return }
        guard taps.allSatisfy({ CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) }) else {
            stop()
            onStatus?("键盘观察已中断。权限可能发生变化；请检查输入监控授权并重新开始。")
            return
        }
        let secure = secureInputEnabled
        guard secure != lastSecureInput else { return }
        lastSecureInput = secure
        onStatus?(secure ? "系统安全输入已开启，暂时可能无法观察；结束密码输入后会自动恢复。" : "系统安全输入已结束，可以继续按下组合键检测。")
    }

    private func install(_ location: CGEventTapLocation, mask: CGEventMask) -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context { Unmanaged<ShortcutDetector>.fromOpaque(context).takeUnretainedValue().receive(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        guard CGEvent.tapIsEnabled(tap: tap) else { CFMachPortInvalidate(tap); return false }
        taps.append(tap); sources.append(source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Stop and let the user restart. Silent retry could leave an old
            // association alive across a period where keys were not observed.
            pending = nil
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.onStatus?("系统暂停了键盘观察。请点击开始检测重试；期间未归属任何按键。")
            }
            return
        }
        guard isListening else { return }
        if type == .keyDown {
            // Every intervening key invalidates correlation. Ordinary text is
            // discarded immediately and never reaches the model or callback.
            pending = nil
            let rawCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard rawCode >= 0, rawCode <= Int64(UInt16.max), event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let shortcut = ShortcutSpec(keyCode: UInt16(rawCode), modifiers: event.flags.rawValue)
            guard acceptShortcut(shortcut) else { return }
            generation += 1
            lastSnapshot = nil
            currentFindings = []
            let key = PendingKey(shortcut: shortcut, timestamp: event.timestamp, generation: generation, findings: [])
            pending = key
            diagnostic(ObservationDiagnostic(kind: "selectedKeyDown", keyTimestamp: key.timestamp, eventTimestamp: key.timestamp, targetPID: nil, correlation: nil))
            // File reads and UI callbacks never run in the event-tap callback.
            scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.publish(shortcut: shortcut, generation: key.generation) }
            scheduled = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            return
        }
        guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              var key = pending, let native = NSEvent(cgEvent: event), native.subtype.rawValue == 6 else { return }
        let routedPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let matchedLevel = Self.correlationLevel(keyTimestamp: key.timestamp, eventTimestamp: event.timestamp, targetPID: routedPID, ownPID: getpid())
        if event.timestamp >= key.timestamp, event.timestamp - key.timestamp < 1_000_000_000 {
            diagnostic(ObservationDiagnostic(kind: "systemHotKey", keyTimestamp: key.timestamp, eventTimestamp: event.timestamp, targetPID: routedPID, correlation: matchedLevel?.rawValue ?? "rejected"))
        }
        guard let level = matchedLevel else { return }
        let pid = Int32(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard !key.findings.contains(where: { $0.application.pid == pid }) else { return }
        let identity = AppIdentity.process(pid)
        let delta = event.timestamp - key.timestamp
        key.findings.append(Finding(id: "event-\(key.timestamp)-\(pid)", level: level, application: identity,
            title: level == .observedRecipient ? "该次系统热键事件派发给此软件" : "相邻系统事件指向此软件",
            detail: level == .observedRecipient ? "系统热键事件与按键的时间戳完全相同，目标 PID 为 \(pid)。这是系统派发目标的证据；不证明软件内部执行了哪个功能。" : "系统事件晚于按键 \(String(format: "%.1f", Double(delta) / 1_000_000)) 毫秒，只有时间邻近，不能确认为该组合的接收者。"))
        pending = key
        currentFindings = key.findings
        if var snapshot = lastSnapshot, snapshot.shortcut == key.shortcut, key.generation == generation {
            snapshot.findings.removeAll { $0.level == .observedRecipient || $0.level == .nearbyEvent }
            snapshot.findings.insert(contentsOf: key.findings, at: 0)
            lastSnapshot = snapshot
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isListening, self.generation == key.generation else { return }
                self.deliver(snapshot)
            }
        }
    }

    private func diagnostic(_ record: ObservationDiagnostic) {
        guard target != nil, onDiagnostic != nil else { return }
        let recordedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isListening, self.generation == recordedGeneration else { return }
            self.onDiagnostic?(record)
        }
    }

    /// Pure association rule, also used by negative tests. Do not promote
    /// temporal proximity, PID zero, or our own UI events to ownership.
    static func correlationLevel(keyTimestamp: UInt64, eventTimestamp: UInt64, targetPID: Int64, ownPID: Int32) -> EvidenceLevel? {
        guard keyTimestamp > 0, eventTimestamp >= keyTimestamp, eventTimestamp - keyTimestamp < 250_000_000,
              targetPID > 0, targetPID <= Int64(Int32.max), targetPID != Int64(ownPID) else { return nil }
        return eventTimestamp == keyTimestamp ? .observedRecipient : .nearbyEvent
    }

    private func publish(shortcut: ShortcutSpec, generation keyGeneration: Int) {
        guard isListening, generation == keyGeneration else { return }
        var snapshot = scan(shortcut)
        snapshot.receivedKey = true
        snapshot.findings.insert(contentsOf: currentFindings, at: 0)
        if snapshot.observedRecipient == nil {
            snapshot.notes.insert("已观察到组合键，但尚未取得可确认的接收进程。过滤器提前吞键、应用内部快捷键或未公开的系统行为都可能没有热键派发证据。", at: 0)
        }
        if !routeAvailable { snapshot.notes.insert("当前系统派发观察通路不可用。", at: 0) }
        lastSnapshot = snapshot
        deliver(snapshot)
    }

    /// Every update restarts the short settle window; when it ends, listening stops and the final
    /// snapshot is reported once (the window's 检测完成 and `keyscope detect` both use this).
    private func deliver(_ snapshot: DetectionSnapshot) {
        onUpdate?(snapshot)
        guard snapshot.receivedKey, isListening else { return }
        completion?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            let result = self.lastSnapshot ?? snapshot
            self.stop()
            self.onComplete?(result)
        }
        completion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDelay, execute: work)
    }

    #if DETECTION_SELF_TEST
    /// Self-test only (not compiled into the app): marks the detector as listening without creating a tap and
    /// feeds a snapshot through the real deliver()/onComplete path, as publish() and the routing event do.
    func selfTestDeliver(_ snapshot: DetectionSnapshot) {
        precondition(Thread.isMainThread)
        isListening = true
        lastSnapshot = snapshot
        deliver(snapshot)
    }
    #endif
}
