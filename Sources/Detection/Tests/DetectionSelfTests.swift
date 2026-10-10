#if DETECTION_SELF_TEST
import AppKit
import CoreGraphics
import Foundation

@main struct DetectionSelfTests {
    static func main() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            passed += 1
        }
        let ctrlG = ShortcutSpec(keyCode: 5, modifiers: CGEventFlags.maskControl.rawValue)
        let ctrlShiftG = ShortcutSpec(keyCode: 5, modifiers: CGEventFlags([.maskControl,.maskShift]).rawValue)
        let source = URL(fileURLWithPath: "/fixture/config")
        check(ctrlG.displayName == "⌃ G", "Ctrl G display")
        check(ShortcutSpec(keyCode: 5, modifiers: CGEventFlags([.maskControl,.maskAlphaShift]).rawValue) == ctrlG, "Caps Lock does not change shortcut")
        check(ShortcutSpec.cocoaModifiers(fromCarbon: 4096) == CGEventFlags.maskControl.rawValue, "Carbon Control")
        check(ShortcutSpec.cocoaModifiers(fromCarbon: 8192) == CGEventFlags.maskShift.rawValue, "Carbon right Shift")
        check(ShortcutSpec.cocoaModifiers(fromCarbon: 16384) == CGEventFlags.maskAlternate.rawValue, "Carbon right Option")
        check(ShortcutSpec.cocoaModifiers(fromCarbon: 32768) == CGEventFlags.maskControl.rawValue, "Carbon right Control")
        check(!ShortcutSpec(keyCode: 5, modifiers: 0).isSafeForFreeRecording, "Ordinary text excluded")
        check(!ShortcutSpec(keyCode: 5, modifiers: CGEventFlags.maskShift.rawValue).isSafeForFreeRecording, "Uppercase text excluded")
        check(ShortcutSpec(keyCode: 122, modifiers: CGEventFlags.maskSecondaryFn.rawValue).isSafeForFreeRecording, "F keys allowed")
        let selection = ShortcutDetector()
        check(!selection.acceptShortcut(ShortcutSpec(keyCode: 5, modifiers: 0)), "Free recording rejects plain text")
        check(selection.acceptShortcut(ctrlG), "Free recording accepts first safe chord")
        check(!selection.acceptShortcut(ctrlShiftG), "Free recording locks first chord")
        check(selection.acceptShortcut(ctrlG), "Locked recording accepts original chord")
        selection.stop()
        check(selection.acceptShortcut(ctrlShiftG), "Stop resets recording target")
        selection.stop()
        check(ConfigurationScanner.raycastShortcut("Option-49") == ShortcutSpec(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue), "Raycast Option Space")
        check(ConfigurationScanner.raycastShortcut("Control-Option-5") == ShortcutSpec(keyCode: 5, modifiers: CGEventFlags([.maskControl,.maskAlternate]).rawValue), "Raycast multiple modifiers")
        check(ConfigurationScanner.raycastShortcut("Command-5") != ctrlG, "Raycast different modifier excluded")
        check(ConfigurationScanner.raycastShortcut("garbage-5") == nil, "Raycast unknown modifier rejected")
        check(ConfigurationScanner.raycastShortcut("Option-999999") == nil, "Raycast invalid key rejected")
        check(ConfigurationScanner.raycastShortcut("Option--5") == nil, "Raycast malformed negative key rejected")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 100, eventTimestamp: 100, targetPID: 42, ownPID: 2) == .observedRecipient, "Exact timestamp")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 100, eventTimestamp: 101, targetPID: 42, ownPID: 2) == .nearbyEvent, "Nearby never confirmed")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 100, eventTimestamp: 99, targetPID: 42, ownPID: 2) == nil, "Earlier event excluded")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 100, eventTimestamp: 250_000_100, targetPID: 42, ownPID: 2) == nil, "Expired event excluded")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 100, eventTimestamp: 100, targetPID: 0, ownPID: 2) == nil, "PID zero excluded")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 100, eventTimestamp: 100, targetPID: 2, ownPID: 2) == nil, "Own UI excluded")
        check(ShortcutDetector.correlationLevel(keyTimestamp: 0, eventTimestamp: 0, targetPID: 42, ownPID: 2) == nil, "Zero timestamp excluded")
        let skhd = "# ctrl - g : ignored\nctrl + shift - g : command\nctrl - g : command\nresize < ctrl - g : command\nctrl - 0x05 [\n"
        let skhdMatches = ConfigurationScanner.skhdFindings(text: skhd, shortcut: ctrlG, sourceURL: source)
        check(skhdMatches.count == 3, "skhd exact combination only")
        check(skhdMatches.filter { $0.level == .configuration }.count == 1, "skhd conditions retained")
        check(ConfigurationScanner.skhdFindings(text: skhd, shortcut: ctrlShiftG, sourceURL: source).count == 1, "skhd shift distinguished")
        let lua = "-- hs.hotkey.bind({\"ctrl\"},\"g\",func)\n--[[\nhs.hotkey.bind({\"ctrl\"},\"g\",func)\n]]\nhs.hotkey.bind({\"ctrl\", \"shift\"},\"g\",func)\nhs.hotkey.bind({\"ctrl\"},\"g\",func)\n{mods={\"ctrl\"}, key=\"g\"}\n"
        let luaMatches = ConfigurationScanner.hammerspoonFindings(text: lua, shortcut: ctrlG, sourceURL: source)
        check(luaMatches.count == 2, "Lua comments and other modifier excluded")
        check(luaMatches.allSatisfy { $0.level == .conditionalConfiguration }, "Lua static never runtime ownership")
        let macro: [String: Any] = ["UID":"fixture","Name":"fixture","IsActive":true,"Triggers":[["MacroTriggerType":"HotKey","Modifiers":4096,"KeyCode":5]]]
        let root: [String: Any] = ["MacroGroups":[["Macros":[macro]]]]
        check(ConfigurationScanner.keyboardMaestroFindings(root: root, shortcut: ctrlG, sourceURL: source).count == 1, "KM enabled exact macro")
        var disabled = macro; disabled["IsActive"] = false
        check(ConfigurationScanner.keyboardMaestroFindings(root: ["MacroGroups":[["Macros":[disabled]]]], shortcut: ctrlG, sourceURL: source).isEmpty, "KM disabled excluded")
        check(ConfigurationScanner.keyboardMaestroFindings(root: ["MacroGroups":[["IsActive":false,"Macros":[macro]]]], shortcut: ctrlG, sourceURL: source).isEmpty, "KM disabled group excluded")
        check(ConfigurationScanner.keyboardMaestroFindings(root: ["MacroGroups":[["Targeting":["Targeting":"Included"],"Macros":[macro]]]], shortcut: ctrlG, sourceURL: source).first?.level == .conditionalConfiguration, "KM scope retained")
        let manipulator: [String: Any] = ["type":"basic","from":["key_code":"g","modifiers":["mandatory":["control"]]]]
        func karabiner(_ rules: [[String: Any]], selected: Bool = true) -> [Finding] {
            ConfigurationScanner.karabinerFindings(root: ["profiles":[["selected":selected,"complex_modifications":["rules":rules]]]], shortcut: ctrlG, sourceURL: source)
        }
        check(karabiner([["manipulators":[manipulator]]]).count == 1, "Karabiner mandatory matches")
        check(karabiner([["enabled":false,"manipulators":[manipulator]]]).isEmpty, "Karabiner disabled rule excluded")
        check(karabiner([["manipulators":[manipulator]]], selected: false).isEmpty, "Karabiner unselected profile excluded")
        var conditional = manipulator; conditional["conditions"] = [["type":"variable_if","name":"tab pressed","value":1]]
        check(karabiner([["manipulators":[conditional]]]).first?.level == .conditionalConfiguration, "Karabiner variable not evaluated")
        var noModifiers = manipulator; noModifiers["from"] = ["key_code":"g"]
        check(karabiner([["manipulators":[noModifiers]]]).isEmpty, "Karabiner no optional means reject Ctrl")
        var optional = manipulator; optional["from"] = ["key_code":"g","modifiers":["optional":["any"]]]
        check(karabiner([["manipulators":[optional]]]).count == 1, "Karabiner optional any permits Ctrl")
        // Command line shortcut grammar (ShortcutSpec.parse) resolves to the same specs as the GUI picker.
        func parsed(_ text: String) -> ShortcutSpec? { if case .success(let spec) = ShortcutSpec.parse(text) { return spec }; return nil }
        let cmdShift4 = ShortcutSpec(keyCode: 21, modifiers: CGEventFlags([.maskCommand,.maskShift]).rawValue)
        check(parsed("ctrl+g") == ctrlG && parsed("Control+G") == ctrlG && parsed("⌃+g") == ctrlG, "Parse ctrl+g words")
        check(parsed("⌃G") == ctrlG && parsed("⌃ G") == ctrlG && parsed(ctrlG.displayName) == ctrlG, "Parse symbols and displayName round trip")
        check(parsed("ctrl+0x05") == ctrlG && parsed("ctrl + g") == ctrlG, "Parse hex key code and spaces")
        check(parsed("cmd+shift+4") == cmdShift4 && parsed("⇧⌘4") == cmdShift4 && parsed("shift+cmd+4") == cmdShift4, "Parse modifier order free")
        check(parsed("right-cmd+b") == ShortcutSpec(keyCode: 11, modifiers: CGEventFlags.maskCommand.rawValue), "Parse side collapses")
        check(parsed("opt+space") == ShortcutSpec(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue), "Parse opt synonym")
        check(parsed("ctrl+page up") == ShortcutSpec(keyCode: 116, modifiers: CGEventFlags.maskControl.rawValue) && parsed("ctrl+pageup") == parsed("ctrl+page_up"), "Parse multi-word key")
        check(parsed("ctrl+keypad_plus")?.keyCode == 69 && parsed("ctrl+0x45")?.keyCode == 69, "Parse keypad plus")
        let ctrlKeypadPlus = ShortcutSpec(keyCode: 69, modifiers: CGEventFlags.maskControl.rawValue)
        check(parsed("⌃ Keypad +") == ctrlKeypadPlus && parsed("ctrl+keypad +") == ctrlKeypadPlus && parsed("ctrl + Keypad+") == ctrlKeypadPlus
              && parsed("keypad +") == ShortcutSpec(keyCode: 69, modifiers: 0), "Parse keypad plus displayName")
        // Every key the picker offers, under every modifier set the window can toggle, reads back from its displayName.
        let toggles: [CGEventFlags] = [[], .maskControl, [.maskControl, .maskShift], [.maskAlternate, .maskCommand], [.maskControl, .maskAlternate, .maskShift, .maskCommand], .maskSecondaryFn]
        let roundTripMisses = ShortcutSpec.selectableKeys.flatMap { key in toggles.map { ShortcutSpec(keyCode: key.code, modifiers: $0.rawValue) } }
            .filter { parsed($0.displayName) != $0 }.map(\.displayName)
        check(roundTripMisses.isEmpty, "Every displayName parses back (misses: \(roundTripMisses.prefix(5)))")
        check(ShortcutSpec.inputExamples.allSatisfy { parsed($0) != nil }, "Documented spellings all parse")
        check(parsed("f5") == ShortcutSpec(keyCode: 96, modifiers: 0) && parsed("fn+f5") == ShortcutSpec(keyCode: 96, modifiers: 0), "Parse F key drops fn")
        check(parsed("⌃ ⇧ ←") == ShortcutSpec(keyCode: 123, modifiers: CGEventFlags([.maskControl,.maskShift]).rawValue), "Parse arrow symbols")
        check(ShortcutSpec.parse("hyper+k") == .failure(.ambiguousHyper), "Parse rejects ambiguous hyper")
        check(ShortcutSpec.parse("ctrl+nosuchkey") == .failure(.unknownKey("nosuchkey")), "Parse rejects unknown key")
        check(ShortcutSpec.parse("meta+g") == .failure(.unknownModifier("meta")), "Parse rejects unknown modifier")
        check(ShortcutSpec.parse("ctrl++") == .failure(.unknownKey("ctrl++")) && ShortcutSpec.parse("  ") == .failure(.empty), "Parse rejects empty parts")
        check(ShortcutSpec.parse("none+g") == .failure(.unknownModifier("none")), "Parse rejects no-op modifier word")
        check(ShortcutSpec.modifiers(named: ["hyper"]) == CGEventFlags([.maskControl,.maskAlternate,.maskShift,.maskCommand]).rawValue
              && ShortcutSpec.modifiers(named: ["lcmd", "", "none"]) == CGEventFlags.maskCommand.rawValue
              && ShortcutSpec.modifiers(named: ["opt"]) == nil, "Config modifier words unchanged")
        check(ShortcutSpec.keyAliases.count == 32 && ShortcutSpec.keyNames.count == 99, "Key tables unchanged")
        // One verdict rule for the window headline and the command line.
        func snapshot(_ levels: [EvidenceLevel]) -> DetectionSnapshot {
            DetectionSnapshot(shortcut: ctrlG, findings: levels.map { Finding(level: $0, application: AppIdentity(name: "fixture"), title: "", detail: "") },
                              notes: [], checkedSources: [], observedAt: Date())
        }
        check(snapshot([]).verdict == .unconfirmed && snapshot([.listener, .nearbyEvent]).verdict == .unconfirmed, "Clues alone stay unconfirmed")
        check(snapshot([.conditionalConfiguration, .listener]).verdict == .relatedBinding, "Binding without receipt")
        check(snapshot([.systemBinding, .observedRecipient]).verdict == .recipientObserved, "Observed recipient wins")
        check(snapshot([.systemBinding, .listener, .nearbyEvent]).primaryFindings.count == 1
              && snapshot([.systemBinding, .listener, .nearbyEvent]).listenerFindings.count == 2, "Primary and clue split")
        check(DetectionVerdict.allCases.map(\.headline) == ["找到接收软件", "找到相关绑定", "暂未确认接收软件"], "Verdict headlines match window")
        // Auto-stop after a received key (onComplete, shared by the window and `keyscope detect`), driven through the
        // real deliver() path with synthetic snapshots: no tap, no key event. The main thread is blocked with
        // Thread.sleep where a callback must not run yet, so the timing checks cannot fail under load.
        do {
            let detector = ShortcutDetector()
            var updates = 0
            var completions: [(snapshot: DetectionSnapshot, at: Date, listening: Bool)] = []
            detector.onUpdate = { _ in updates += 1 }
            detector.onComplete = { [unowned detector] value in completions.append((value, Date(), detector.isListening)) }
            func received(_ levels: [EvidenceLevel]) -> DetectionSnapshot { var value = snapshot(levels); value.receivedKey = true; return value }
            func runLoop(_ seconds: TimeInterval) { _ = CFRunLoopRunInMode(.defaultMode, seconds, false) }
            detector.selfTestDeliver(snapshot([.conditionalConfiguration]))
            runLoop(ShortcutDetector.completionDelay + 0.15)
            check(completions.isEmpty && detector.isListening && updates == 1, "No auto-stop before a key is received")
            detector.selfTestDeliver(received([.conditionalConfiguration]))
            Thread.sleep(forTimeInterval: 0.1)
            let second = Date()
            detector.selfTestDeliver(received([.observedRecipient, .conditionalConfiguration]))
            let limit = Date().addingTimeInterval(5)
            while completions.isEmpty, limit.timeIntervalSinceNow > 0 { runLoop(0.02) }
            check(completions.count == 1, "Auto-stop reports once after a received key")
            if let first = completions.first {
                check(first.at.timeIntervalSince(second) >= ShortcutDetector.completionDelay - 0.005, "A later update restarts the settle window")
                check(first.snapshot.verdict == .recipientObserved && first.snapshot.receivedKey, "Auto-stop reports the latest snapshot")
                check(!first.listening && !detector.isListening, "Listening has stopped when onComplete runs")
            }
            runLoop(ShortcutDetector.completionDelay + 0.15)
            check(completions.count == 1 && updates == 3, "No second completion or update after auto-stop")
            detector.selfTestDeliver(received([.listener]))
            detector.stop()
            runLoop(ShortcutDetector.completionDelay + 0.15)
            check(completions.count == 1 && !detector.isListening, "Stop cancels a pending auto-stop")
        }
        print("PASS: \(passed) detection assertions")
        if CommandLine.arguments.contains("--lifecycle") {
            let detector = ShortcutDetector()
            var updates = 0
            detector.onUpdate = { _ in updates += 1 }
            check(ShortcutDetector.ownsKeyboardTap(pid: getpid()) == false, "An idle process owns no keyboard tap")
            let started = detector.start(ctrlG)
            check(detector.isListening == started, "Actual start state")
            // What `keyscope status` reports as window.listening: read from the system tap list, not from this object.
            check(ShortcutDetector.ownsKeyboardTap(pid: getpid()) == started, "The system tap list shows whether this process is listening")
            if !detector.inputMonitoringGranted { check(!started, "Without Input Monitoring start refuses before creating a tap") }
            detector.stop()
            check(!detector.isListening, "Stop clears listening state")
            detector.stop()
            check(!detector.isListening, "Repeated stop is idempotent")
            CFRunLoopRunInMode(.defaultMode, 0.2, false)
            check(updates == 0, "Stop does not publish retained observations")
            check(ShortcutDetector.ownsKeyboardTap(pid: getpid()) == false, "After stop the system tap list no longer shows this process")
            print("PASS: lifecycle checks; inputMonitoring=\(detector.inputMonitoringGranted) startSucceeded=\(started)")
        }
        // Live listening with a real key press is `keyscope detect <shortcut> --trace` (Sources/CLI/DetectCommand.swift).
        if CommandLine.arguments.contains("--live-scan") {
            let detector = ShortcutDetector()
            for spec in [ctrlG, ctrlShiftG, ShortcutSpec(keyCode: 20, modifiers: CGEventFlags([.maskCommand,.maskShift]).rawValue)] {
                let started = Date()
                let snapshot = detector.scan(spec)
                let counts = Dictionary(grouping: snapshot.findings, by: { $0.level.rawValue }).mapValues(\.count)
                let data = try! JSONSerialization.data(withJSONObject: ["shortcut": spec.displayName,"milliseconds":Date().timeIntervalSince(started)*1000,"findingsByLevel": counts,"checkedSourceCount":snapshot.checkedSources.count], options: [.sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            }
        }
    }
}
#endif
