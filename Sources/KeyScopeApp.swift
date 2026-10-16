import AppKit
import Combine
import SwiftUI

@main
enum KeyScopeMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let executable = CommandLine.arguments.first ?? ""
        #if !APP_STORE
        if arguments.first == "--product-basics-self-test", !KeyScopeCLI.invokedAsCommand(executable) {
            guard arguments.count == 2 else { exit(2) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            exit(ProductBasicsSelfTest.run(URL(fileURLWithPath:arguments[1],isDirectory:true)))
        }
        // Offscreen UI self-test for acceptance: needs the window code, so it stays here. It writes
        // screenshots, so the output directory must be given explicitly and nothing else may follow.
        // Developer hook of the KeyScope executable only: run as `keyscope` it is an unknown option (exit 2),
        // so the agent command line never builds a window or writes a file.
        if arguments.first == "--ui-self-test", !KeyScopeCLI.invokedAsCommand(executable) {
            guard arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("-") else {
                FileHandle.standardError.write(Data("用法：KeyScope --ui-self-test <输出目录>\n".utf8))
                exit(2)
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let delegate = AppDelegate()
            let ok = delegate.runUISelfTest(outDir: URL(fileURLWithPath: arguments[1], isDirectory: true))
            exit(ok ? 0 : 1)
        }
        // Offscreen lifecycle self-test for acceptance (scripts/accept/lifecycle.sh): this process stands in for the
        // running window so the real `keyscope` commands can be run against it. Same rules as --ui-self-test: the
        // output directory is mandatory, and run as `keyscope` the flag is an unknown option (exit 2).
        if arguments.first == "--lifecycle-self-test", !KeyScopeCLI.invokedAsCommand(executable) {
            guard arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("-") else {
                FileHandle.standardError.write(Data("用法：KeyScope --lifecycle-self-test <输出目录>\n".utf8))
                exit(2)
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let delegate = AppDelegate()
            let ok = delegate.runLifecycleSelfTest(outDir: URL(fileURLWithPath: arguments[1], isDirectory: true))
            exit(ok ? 0 : 1)
        }
        // Everything else on the command line (keyscope <command>, --scan, --version, --help) is the
        // agent CLI in Sources/CLI and returns before any window code runs. Run as `keyscope`, the
        // binary never opens the window; Finder/Xcode launch flags use a single dash and reach the GUI.
        if KeyScopeCLI.handles(executable: executable, arguments: arguments) {
            exit(KeyScopeCLI.main(arguments))
        }
        #else
        if arguments.first == "--store-self-test" {
            guard arguments.count == 1 || arguments == ["--store-self-test", "--resume"] else { exit(2) }
            exit(StorePreferences.selfTest(resume: arguments.contains("--resume")))
        }
        if arguments.first == "--ui-self-test" {
            guard arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("-") else { exit(2) }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let delegate = AppDelegate()
            exit(delegate.runUISelfTest(outDir: URL(fileURLWithPath: arguments[1], isDirectory: true)) ? 0 : 1)
        }
        if arguments.first?.hasPrefix("--") == true || (arguments.first.map { !$0.hasPrefix("-") } ?? false) {
            fputs("KeyScope Mac App Store 版不提供命令行工具。\n", stderr); exit(2)
        }
        _ = executable
        #endif
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // -lane_quiet (shared LaneSignal, measurement/acceptance lanes only) starts as an accessory: no Dock icon.
        application.setActivationPolicy(LaneSignal.quiet ? .accessory : .regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow?
    /// Measurement launch (`sop.measure.quiet_launch`, sent together with the shared `-lane_quiet`): the real
    /// window and first screen are built and laid out but never ordered front. A normal launch is unchanged.
    private let background = LaneSignal.quiet || CommandLine.arguments.contains("-background_launch")

    func applicationWillFinishLaunching(_ notification: Notification) { LaneSignal.enterQuietIfAsked() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        installLifecycle()
        buildMenu()
        guard background else { showWindow(); return }
        let window = makeWindow()
        window.contentView?.layoutSubtreeIfNeeded()
        // The first screen is static (no async data, no listener): it is ready once SwiftUI has committed the
        // first layout pass, one main-loop turn after the hosting view is attached.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                window.contentView?.layoutSubtreeIfNeeded()
                LaneSignal.ready("main")
            }
        }
    }
    /// What a launch wires up besides the window: the shared「配置与更新」window with its two menu items, and the
    /// answer to `keyscope status` asking whether Input Monitoring is allowed for this app and whether the permission
    /// card is showing. The lifecycle self-test runs this same function offscreen.
    func installLifecycle() {
        #if !APP_STORE
        AppLifecycleUI.shared.canInstallUpdate = { [weak model] in !(model?.isListening ?? false) }
        ProductLifecycle.installApp()
        WindowPermission.answerQuestions(cardVisible: { [model] in !model.permissionGranted })
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }; return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func windowWillClose(_ notification: Notification) { model.stop() }

    @objc func showWindow() { makeWindow().makeKeyAndOrderFront(nil) }
    private func makeWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 710),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KeyScope · 快捷键侦探"
        window.minSize = NSSize(width: 690, height: 590)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1)
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        self.window = window
        return window
    }
    @objc func toggleDetection() { model.isListening ? model.stop() : model.start() }
    @objc func manualSelection() { model.showManual.toggle() }
    @objc func refresh() { model.refresh() }
    @objc func clear() { model.clear() }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: "https://keyscope.tianli.cyou/#help")!) }
    func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "KeyScope")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        appMenu.addItem(withTitle: "关于 KeyScope", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        #if !APP_STORE
        AppLifecycleUI.menuItems().forEach { appMenu.addItem($0) }
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 KeyScope", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 KeyScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let detection = NSMenu(title: "检测")
        let detectionItem = NSMenuItem(title: "检测", action: nil, keyEquivalent: ""); detectionItem.submenu = detection; main.addItem(detectionItem)
        for (title, selector, key) in [("开始 / 停止检测", #selector(toggleDetection), "r"), ("手动选择", #selector(manualSelection), "k"), ("刷新结果", #selector(refresh), "l"), ("清空", #selector(clear), "\u{8}")] {
            let item = detection.addItem(withTitle: title, action: selector, keyEquivalent: key); item.target = self
        }
        let windowMenu = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "");windowItem.submenu = windowMenu;main.addItem(windowItem)
        let reopen = windowMenu.addItem(withTitle: "显示主窗口", action: #selector(showWindow), keyEquivalent: "n");reopen.target=self
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let help = NSMenu(title: "帮助")
        let helpItem=NSMenuItem(title:"帮助",action:nil,keyEquivalent:"");helpItem.submenu=help;main.addItem(helpItem)
        let guide=help.addItem(withTitle:"使用指南与官网",action:#selector(openHelp),keyEquivalent:"?");guide.target=self
        NSApp.mainMenu=main;NSApp.windowsMenu=windowMenu;NSApp.helpMenu=help
        #if !APP_STORE
        let settings = KeyScopeSettings.shared
        settings.refreshAction = { [weak self] in self?.refresh() }
        settings.changed = { [weak self] in self?.model.showDetails = settings.defaults.bool(forKey:KeyScopeSettings.detailsKey) }
        detection.items.first { $0.title == "刷新结果" }?.keyEquivalent = ""
        settings.shortcuts.installMenu()
        #endif
    }
}

final class AppModel: ObservableObject {
    #if APP_STORE
    @Published var preferencesGranted = StorePreferences.isGranted
    func allowPreferences() {
        let selected = StorePreferences.chooseFolder()
        preferencesGranted = StorePreferences.isGranted
        status = selected ? "已允许只读偏好线索，可以手动查询组合键。"
            : (preferencesGranted ? "已保留此前的目录授权。" : "未选择有效的 Preferences 文件夹，基本检测不受影响。")
        if snapshot != nil { refresh() }
    }
    func revokePreferences() {
        StorePreferences.revoke(); preferencesGranted = false
        if snapshot != nil { refresh() }
    }
    #endif
    @Published var snapshot: DetectionSnapshot?
    @Published var isListening = false
    @Published var status = "点击开始，按下你想检查的快捷键。"
    @Published var showManual = false
    @Published var showDetails = false
    @Published var permissionGranted = CGPreflightListenEventAccess()
    @Published var control = true
    @Published var option = false
    @Published var shift = false
    @Published var command = false
    @Published var keyCode: UInt16 = 5
    private let detector = ShortcutDetector()
    init() {
        #if !APP_STORE
        showDetails = KeyScopeSettings.shared.defaults.bool(forKey:KeyScopeSettings.detailsKey)
        #endif
        detector.onUpdate = { [weak self] value in
            guard let self else { return }
            self.snapshot = value
            if value.receivedKey { self.status = "已收到 \(value.shortcut.displayName)，正在核对接收软件。" }
        }
        // The detector stops itself shortly after the key arrives (shared with `keyscope detect`).
        detector.onComplete = { [weak self] value in
            guard let self else { return }
            self.snapshot = value
            self.isListening = false
            self.status = "检测完成 · 结果已保留，点击再次检测可查询其他组合。"
        }
        detector.onStatus = { [weak self] value in
            guard let self else { return }
            self.status = value
            self.isListening = self.detector.isListening
        }
    }
    var manualShortcut: ShortcutSpec {
        var value: UInt64 = 0
        if control {value |= CGEventFlags.maskControl.rawValue}
        if option {value |= CGEventFlags.maskAlternate.rawValue}
        if shift {value |= CGEventFlags.maskShift.rawValue}
        if command {value |= CGEventFlags.maskCommand.rawValue}
        return ShortcutSpec(keyCode:keyCode,modifiers:value)
    }
    func start() {
        permissionGranted = CGPreflightListenEventAccess()
        guard permissionGranted else {status = "请先在系统设置中允许 KeyScope 监控输入，然后重新检查权限。";return}
        isListening = detector.start(nil)
    }
    func stop() { detector.stop();isListening=false;status="检测已停止，不再监听按键。" }
    func checkPermission() {
        permissionGranted = CGPreflightListenEventAccess()
        status = permissionGranted ? "权限已就绪，可以开始检测。" : "尚未获得输入监控权限。授权后如未生效，请退出并重新打开 KeyScope。"
    }
    func openPermissionSettings() {
        // Permission is requested only through the user's explicit button.
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func query() {stop();scan(manualShortcut);showManual=false}
    func refresh() {stop();scan(snapshot?.shortcut ?? manualShortcut)}
    private func scan(_ value: ShortcutSpec) {
        snapshot=detector.scan(value)
        #if APP_STORE
        status="已查询 \(value.displayName) 的系统热键、监听候选与已允许的偏好线索。"
        #else
        status="已查询 \(value.displayName) 的系统绑定、已知配置与监听软件。"
        #endif
    }
    func clear() {stop();snapshot=nil;showDetails=false;status="点击开始，按下你想检查的快捷键。"}
    var primaryFindings: [Finding] {snapshot?.primaryFindings ?? []}
    var listenerFindings: [Finding] {snapshot?.listenerFindings ?? []}
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let ink=Color(red:0.10,green:0.15,blue:0.26)
    private let accent=Color(red:0.24,green:0.36,blue:0.82)
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(nsImage:NSApp.applicationIconImage).resizable().frame(width:44,height:44)
                VStack(alignment:.leading,spacing:3) {
                    Text("KeyScope").font(.system(size:23,weight:.bold,design:.rounded))
                    Text("快捷键侦探").font(.system(size:12)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.isListening ? Color.green : Color.gray.opacity(0.5)).frame(width:7,height:7)
                Text(model.isListening ? "正在检测" : "未在监听").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
            }.padding(.horizontal,28).padding(.top,20).padding(.bottom,20)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    hero
                    if !model.permissionGranted { permissionCard }
                    #if APP_STORE
                    preferencesCard
                    #endif
                    if model.showManual {manualCard}
                    if let snapshot=model.snapshot {
                        if !model.primaryFindings.isEmpty {
                            VStack(alignment:.leading,spacing:10) {
                                Label(snapshot.verdict.headline,systemImage:"checkmark.shield")
                                    .font(.system(size:15,weight:.semibold))
                                ForEach(model.primaryFindings) {finding in FindingRow(finding:finding)}
                            }
                        } else {
                            HStack(alignment:.top,spacing:12) {
                                Image(systemName:"questionmark.circle").font(.system(size:23)).foregroundStyle(accent)
                                VStack(alignment:.leading,spacing:6) {
                                    Text(snapshot.verdict.headline).font(.system(size:16,weight:.semibold))
                                    Text("没有发现可明确归属的绑定。部分软件直接过滤按键，可以展开排查详情查看线索。").font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
                        }
                        DisclosureGroup(isExpanded:$model.showDetails) {
                            VStack(alignment:.leading,spacing:12) {
                                if !model.listenerFindings.isEmpty {
                                    Text("以下软件在监听键盘事件。仅凭监听行为，不能判定它占用了这个快捷键。")
                                        .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                    ForEach(model.listenerFindings) {finding in FindingRow(finding:finding)}
                                }
                                ForEach(Array(snapshot.notes.enumerated()),id:\.offset) {_,note in
                                    Text(note).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                                if !snapshot.checkedSources.isEmpty {
                                    Text("已检查："+snapshot.checkedSources.joined(separator:"、")).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                            }.padding(.top,14)
                        } label: {
                            HStack {
                                Text("查看排查详情").font(.system(size:13,weight:.semibold))
                                if !model.listenerFindings.isEmpty {Text("\(model.listenerFindings.count) 条线索").font(.system(size:11)).foregroundStyle(.secondary)}
                                Spacer()
                            }
                        }.padding(16).background(Color.white.opacity(0.75),in:RoundedRectangle(cornerRadius:16))
                    } else {intro}
                }.padding(.horizontal,28).padding(.bottom,22)
            }
            Divider().opacity(0.55)
            HStack(spacing:8) {
                Image(systemName:"lock.shield").foregroundStyle(accent)
                Text("本机处理 · 不记录普通文本 · 不修改现有快捷键").font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Button("使用指南") {NSWorkspace.shared.open(URL(string:"https://keyscope.tianli.cyou/#help")!)}.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(accent)
            }.padding(.horizontal,28).padding(.vertical,14)
        }.foregroundStyle(ink).frame(minWidth:680,minHeight:540).background(Color(red:0.965,green:0.973,blue:0.99))
            .preferredColorScheme(.light)
    }
    private var hero: some View {
        VStack(spacing:17) {
            Text(model.snapshot == nil ? "按下你想检查的快捷键" : "正在检查的快捷键")
                .font(.system(size:14,weight:.medium)).foregroundStyle(.secondary)
            if let shortcut=model.snapshot?.shortcut {
                HStack(spacing:9) {ForEach(Array(shortcut.displayName.components(separatedBy:" ").enumerated()),id:\.offset) {_,key in
                    Text(key).font(.system(size:33,weight:.medium,design:.rounded)).frame(minWidth:48,minHeight:53).padding(.horizontal,9)
                        .background(Color.white,in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(Color.black.opacity(0.07))).shadow(color:.black.opacity(0.045),radius:0,y:3)
                }}.accessibilityElement(children:.ignore).accessibilityLabel("快捷键 "+shortcut.displayName)
            } else {
                Image(systemName:"keyboard").font(.system(size:46,weight:.light)).foregroundStyle(accent).frame(height:61)
            }
            Text(model.status).font(.system(size:12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(minHeight:18)
            HStack(spacing:10) {
                Button {model.isListening ? model.stop() : model.start()} label: {
                    Label(model.isListening ? "停止检测" : (model.snapshot == nil ? "开始检测" : "再次检测"),systemImage:model.isListening ? "stop.fill" : "waveform")
                        .font(.system(size:13,weight:.semibold)).padding(.horizontal,12).padding(.vertical,5)
                }.buttonStyle(.borderedProminent).tint(accent).accessibilityIdentifier("toggleDetection")
                Button("手动选择") {model.showManual.toggle()}.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("manualSelection")
                if model.snapshot != nil {
                    Button {model.refresh()} label: {Image(systemName:"arrow.clockwise")}.buttonStyle(.borderless).help("刷新结果 ⌘L").accessibilityLabel("刷新结果")
                    Button {model.clear()} label: {Image(systemName:"xmark")}.buttonStyle(.borderless).help("清空").accessibilityLabel("清空")
                }
            }
        }.padding(24).frame(maxWidth:.infinity)
            .background(LinearGradient(colors:[Color(red:0.92,green:0.94,blue:1),Color(red:0.95,green:0.97,blue:1)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(Color(red:0.86,green:0.90,blue:0.98)))
    }
    private var permissionCard: some View {
        VStack(alignment:.leading,spacing:12) {
            Label("首次使用：允许输入监控",systemImage:"hand.raised").font(.system(size:14,weight:.semibold))
            #if APP_STORE
            Text("输入监控用于实时检测。未授权也可手动查询系统热键与监听候选；其它软件的偏好线索需另行允许配置目录。")
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            #else
            Text("KeyScope 需要输入监控权限来检查你按下的组合键。查询系统绑定与已知配置仍可使用“手动选择”。")
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            #endif
            HStack {
                Button("打开输入监控设置") {model.openPermissionSettings()}.buttonStyle(.bordered)
                Button("重新检查权限") {model.checkPermission()}.buttonStyle(.bordered)
            }
        }.padding(17).frame(maxWidth:.infinity,alignment:.leading).background(Color(red:1,green:0.974,blue:0.91),in:RoundedRectangle(cornerRadius:15))
    }
    #if APP_STORE
    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("偏好线索（可选）", systemImage: "folder.badge.gearshape").font(.system(size:14,weight:.semibold))
            Text(StorePreferences.description).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("允许 Preferences 文件夹…") { model.allowPreferences() }.buttonStyle(.bordered)
                if model.preferencesGranted {
                    Button("取消目录授权") { model.revokePreferences() }.buttonStyle(.bordered)
                }
            }
        }.padding(17).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:15))
    }
    #endif
    private var manualCard: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("手动选择").font(.system(size:15,weight:.semibold))
            Text("按键被其他软件接走时，也可以直接查询这个组合。").font(.system(size:12)).foregroundStyle(.secondary)
            HStack(spacing:10) {
                Toggle("⌃ Control",isOn:$model.control)
                Toggle("⌥ Option",isOn:$model.option)
                Toggle("⇧ Shift",isOn:$model.shift)
                Toggle("⌘ Command",isOn:$model.command)
            }.toggleStyle(.checkbox).font(.system(size:12))
            HStack(spacing:14) {
                Picker("按键",selection:$model.keyCode) {
                    ForEach(ShortcutSpec.selectableKeys,id:\.code) {key in Text(key.name).tag(key.code)}
                }.frame(width:220).accessibilityIdentifier("keyPicker")
                Spacer()
                Button("查询此组合") {model.query()}.buttonStyle(.borderedProminent).tint(accent).accessibilityIdentifier("queryShortcut")
            }
        }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:16))
    }
    private var intro: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("找到快捷键的去向").font(.system(size:16,weight:.semibold))
            HStack(alignment:.top,spacing:24) {
                feature("1","开始检测","开启只读监听，按下 Control、Option、Command 组合或功能键。")
                feature("2","查看接收软件","优先显示实际接收事件的软件，并说明找到的绑定依据。")
                feature("3","解决冲突","根据结果回到对应软件调整。无法确认时，查看排查线索。")
            }
        }.padding(20).background(.white,in:RoundedRectangle(cornerRadius:16))
    }
    private func feature(_ number:String,_ title:String,_ detail:String)->some View {
        VStack(alignment:.leading,spacing:9) {
            Text(number).font(.system(size:11,weight:.bold)).foregroundStyle(accent).frame(width:24,height:24).background(accent.opacity(0.09),in:Circle())
            Text(title).font(.system(size:13,weight:.semibold))
            Text(detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct FindingRow: View {
    let finding: Finding
    private var isDefinite: Bool {finding.level.isDefinite}
    var body: some View {
        HStack(alignment:.top,spacing:13) {
            appIcon.frame(width:40,height:40)
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:9) {
                    Text(finding.application.name).font(.system(size:15,weight:.semibold)).textSelection(.enabled)
                    Text(finding.level.label).font(.system(size:10,weight:.medium)).foregroundStyle(isDefinite ? Color(red:0.13,green:0.46,blue:0.36) : Color.secondary)
                        .padding(.horizontal,7).padding(.vertical,3).background(isDefinite ? Color.green.opacity(0.08) : Color.gray.opacity(0.08),in:Capsule())
                    Spacer()
                }
                Text(finding.title).font(.system(size:12,weight:.medium)).textSelection(.enabled)
                Text(finding.detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                if let url=finding.sourceURL {
                    Button(url.isFileURL ? "查看配置位置" : "打开系统设置") {
                        if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        else { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link).font(.system(size:11))
                }
            }
        }.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(Color.white,in:RoundedRectangle(cornerRadius:13))
            .overlay(RoundedRectangle(cornerRadius:13).stroke(Color.black.opacity(0.055)))
    }
    @ViewBuilder private var appIcon: some View {
        if let url=finding.application.bundleURL {
            Image(nsImage:NSWorkspace.shared.icon(forFile:url.path)).resizable().scaledToFit()
        } else {Image(systemName:finding.level == .systemBinding ? "macwindow" : "app.dashed").resizable().scaledToFit().padding(5).foregroundStyle(.secondary)}
    }
}

// In-process offscreen UI self-test (`--ui-self-test <dir>`): the real ContentView and menu are built
// offscreen, and the same model/menu action code paths are called directly. No window is ordered
// front, the App is never activated, no menu is opened and no input is synthesized. start() is not
// called because it installs listen-only event taps that need Input Monitoring permission.
extension AppDelegate {
    func runUISelfTest(outDir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        var shots: [String] = []
        let initialStatus = "点击开始，按下你想检查的快捷键。"
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        let host = NSHostingView(rootView: ContentView(model: model))
        // Never ordered front: used only as an offscreen backing so SwiftUI lays out and draws.
        let canvas = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 780, height: 710),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        canvas.isReleasedWhenClosed = false
        canvas.appearance = NSAppearance(named: .aqua)
        canvas.contentView = host
        func render(_ name: String, height: CGFloat = 710) -> Bool {
            canvas.setContentSize(NSSize(width: 780, height: height))
            host.frame = NSRect(x: 0, y: 0, width: 780, height: height)
            settle(); host.layoutSubtreeIfNeeded(); settle()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]),
                  (try? data.write(to: outDir.appendingPathComponent(name))) != nil else { return false }
            shots.append(name)
            var dark = 0, light = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) { for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if l < 0.55 { dark += 1 } else if l > 0.9 { light += 1 } } }
            // Real content: expected pixel size, a light background and a meaningful amount of text/ink.
            return rep.pixelsWide >= 780 && rep.pixelsHigh >= Int(height) && data.count > 20_000 && dark > 300 && light > 5_000
        }

        // Menu structure only: built with the same code, never opened.
        buildMenu()
        let main = NSApp.mainMenu
        let tops = main?.items.map(\.title) ?? []
        let detection = main?.items.first { $0.title == "检测" }?.submenu?.items ?? []
        #if APP_STORE
        let refreshKey = "l", sections = ["检测", "窗口", "帮助"]
        #else
        let refreshKey = "", sections = ["检测", "窗口", "帮助", "操作"]
        #endif
        let expected: [(String, String)] = [("开始 / 停止检测", "r"), ("手动选择", "k"), ("刷新结果", refreshKey), ("清空", "\u{8}")]
        checks["menu_structure"] = tops.count == sections.count + 1 && tops.dropFirst().elementsEqual(sections)
            && detection.map(\.title) == expected.map(\.0) && detection.map(\.keyEquivalent) == expected.map(\.1)
        let owned = (main?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { $0.target != nil }
        // Six items belong to this delegate (four detection actions, 显示主窗口, 使用指南与官网). Since 1.0.4 the
        // app menu also carries the shared lifecycle pair, which is wired to the AppLifecycleUI singleton.
        #if APP_STORE
        checks["menu_actions_wired"] = owned.count == 6 && owned.allSatisfy { item in
            guard let action = item.action, let target = item.target as? NSObject else { return false }
            return target.responds(to: action)
        }
        checks["no_store_updater_menu"] = !(main?.items ?? []).flatMap { $0.submenu?.items ?? [] }
            .contains { $0.title.contains("更新") || $0.title.contains("升级") }
        #else
        let lifecycle = owned.filter { $0.target === AppLifecycleUI.shared }
        checks["menu_actions_wired"] = owned.count == 9 && owned.filter { $0.target === self }.count == 6
            && lifecycle.map(\.title) == ["配置与更新…", "检查更新…"]
            && owned.allSatisfy { item in
                guard let action = item.action, let target = item.target as? NSObject else { return false }
                return target.responds(to: action) }
        #endif
        let standard = (main?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem && $0.target == nil }
        checks["menu_standard_actions"] = standard.count == 5 && standard.allSatisfy { $0.action != nil }
        func menuAction(_ title: String) -> Bool {
            guard let item = detection.first(where: { $0.title == title }), let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }

        checks["initial_state"] = model.snapshot == nil && !model.isListening && model.status == initialStatus && !model.showManual
        checks["render_initial"] = render("native-ui-initial.png")

        model.checkPermission()
        checks["permission_status_matches"] = model.status == (model.permissionGranted ? "权限已就绪，可以开始检测。"
            : "尚未获得输入监控权限。授权后如未生效，请退出并重新打开 KeyScope。")

        // "手动选择" (⌘K) toggles the manual card through the same menu action.
        checks["manual_toggle_menu"] = menuAction("手动选择") && model.showManual
        model.control = true; model.option = false; model.shift = true; model.command = true; model.keyCode = 5
        let manual = model.manualShortcut
        checks["manual_shortcut_modifiers"] = manual.keyCode == 5 && manual.modifiers
            == CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue
        checks["render_manual"] = render("native-ui-manual.png")

        // "查询此组合": read-only configuration scan of the chosen combination.
        model.query()
        #if APP_STORE
        checks["query_scans_manual_shortcut"] = model.snapshot?.shortcut == manual && !model.showManual && !model.isListening
            && model.status.hasPrefix("已查询 ") && !(model.snapshot?.notes.isEmpty ?? true)
        #else
        checks["query_scans_manual_shortcut"] = model.snapshot?.shortcut == manual && !model.showManual && !model.isListening
            && model.status == "已查询 \(manual.displayName) 的系统绑定、已知配置与监听软件。"
            && !(model.snapshot?.checkedSources.isEmpty ?? true)
        #endif
        checks["render_result"] = render("native-ui-result.png")
        model.showDetails = true
        checks["render_details"] = render("native-ui-details.png", height: 1100)

        // "刷新结果" (⌘L) rescans the same shortcut.
        model.status = ""
        checks["refresh_menu_rescans"] = menuAction("刷新结果") && model.snapshot?.shortcut == manual
            && model.status.hasPrefix("已查询 ") && !model.isListening

        model.stop()
        checks["stop_idle"] = !model.isListening && model.status == "检测已停止，不再监听按键。"

        // "清空" (⌘⌫) resets results.
        checks["clear_menu_resets"] = menuAction("清空") && model.snapshot == nil
            && !model.showDetails && model.status == initialStatus
        checks["render_cleared"] = render("native-ui-cleared.png")

        // Background (measurement) launch path: the real main window is built without being ordered front.
        let mainWindow = makeWindow()
        checks["background_window_not_shown"] = !mainWindow.isVisible && mainWindow.contentView != nil && makeWindow() === mainWindow
        checks["no_focus_or_visible_window"] = !NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible } && !canvas.isKeyWindow
        canvas.contentView = nil; canvas.close()

        let ok = !checks.isEmpty && checks.values.allSatisfy { $0 }
        let notCovered = [
            "start()/开始检测：会安装只读 CGEvent tap，需要输入监控权限并监听真实按键，自检不调用",
            "按键接收与接收软件归属：需要真实物理按键，由 detection 自测覆盖",
            "打开输入监控设置 / 使用指南 / 查看配置位置：会调用 NSWorkspace 打开外部界面，自检不调用",
            "showWindow 主窗口置前与菜单实际弹出：会抢焦点，只检查菜单结构和动作接线"]
        let payload: [String: Any] = ["ok": ok, "checks": checks, "screenshots": shots, "not_covered": notCovered]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
        return ok
    }
}

// In-process offscreen lifecycle self-test (`--lifecycle-self-test <dir>`): this process is the running window.
#if !APP_STORE
// It runs the same installLifecycle() and buildMenu() a launch runs, with activation policy .prohibited (no Dock
// icon, nothing ordered front, never active), builds the shared「配置与更新」window offscreen, and then keeps the run
// loop turning so the real `keyscope` commands can ask it. Product code never starts a process: the commands are
// started by scripts/accept/lifecycle.sh, each a fresh process, on a private channel (KEYSCOPE_WINDOW_CHANNEL).
// Lines on stdin drive it — `card on|off` sets the value the permission card is drawn from, `background on|off`
// suspends distributed notifications the way AppKit does for a window that is not frontmost, `state` reports, `quit`
// or end of input ends it — and it stops by itself after two minutes of awake time. One JSON line per report.
extension AppDelegate {
    func runLifecycleSelfTest(outDir: URL) -> Bool {
        var checks: [String: Bool] = [:]
        func emit(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        func state(_ event: String) -> [String: Any] {
            ["event": event, "pid": Int(getpid()), "granted": CGPreflightListenEventAccess(), "permissionCard": !model.permissionGranted,
             "answered": WindowPermission.answered, "channel": WindowPermission.testChannel ?? NSNull(),
             "background": DistributedNotificationCenter.default().suspended]
        }
        // An isolated run only: without a private channel this process would answer the owner's own commands.
        guard WindowPermission.testChannel != nil else {
            emit(["event": "refused", "ok": false, "reason": "set KEYSCOPE_WINDOW_CHANNEL to a private channel name"])
            return false
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        installLifecycle()
        buildMenu()
        // The owner types `keyscope status` in a terminal, so the real window is in the background when the question
        // arrives, and AppKit suspends distributed notifications for an app that is not active. This process is never
        // active and AppKit never suspends it, so the test does: the question must get through all the same.
        DistributedNotificationCenter.default().suspended = true
        let appMenu = NSApp.mainMenu?.items.first?.submenu?.items ?? []
        let lifecycle = appMenu.filter { $0.target === AppLifecycleUI.shared }
        checks["menu_has_settings_and_check_for_updates"] = lifecycle.map(\.title) == ["配置与更新…", "检查更新…"]
            && lifecycle.allSatisfy { item in item.action.map { AppLifecycleUI.shared.responds(to: $0) } ?? false }
        // The same shared settings window now includes the portable configuration group.
        // Build it without ordering it in; interactive controls are covered by product-basics.
        let shot = (try? AppLifecycleUI.shared.offscreenSnapshot(to: outDir.appendingPathComponent("lifecycle-settings.png"))) ?? [:]
        checks["settings_window_built_offscreen"] = shot["upgrade_window_offscreen"] == true && shot["upgrade_image_rendered"] == true
            && shot["upgrade_native_titlebar"] == true
        checks["check_for_updates_button_wired"] = shot["upgrade_actual_button_target"] == true
        let cloudSwitch = Mirror(reflecting: AppLifecycleUI.shared).descendant("cloudToggle") as? NSView
        checks["portable_configuration_group_present"] = KeyScopeSettings.shared.configuration.hasSettings && cloudSwitch?.window != nil
        checks["nothing_visible_or_active"] = !NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible }
            && NSApp.activationPolicy() == .prohibited

        var ready = state("ready")
        ready["checks"] = checks
        emit(ready)

        // Commands from the driver, read off the main thread and applied on it.
        var finished = false
        let input = FileHandle.standardInput
        input.readabilityHandler = { handle in
            let data = handle.availableData
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            DispatchQueue.main.async {
                if data.isEmpty { finished = true; return }
                for line in lines {
                    switch line {
                    case "card on": self.model.permissionGranted = false; emit(state("card"))
                    case "card off": self.model.permissionGranted = true; emit(state("card"))
                    case "background on": DistributedNotificationCenter.default().suspended = true; emit(state("background"))
                    case "background off": DistributedNotificationCenter.default().suspended = false; emit(state("background"))
                    case "state": emit(state("state"))
                    case "quit": finished = true
                    default: emit(["event": "unknown", "line": line])
                    }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while !finished && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        input.readabilityHandler = nil

        checks["still_nothing_visible_or_active"] = !NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible }
        let ok = finished && !checks.isEmpty && checks.values.allSatisfy { $0 }
        var done = state("done")
        done["ok"] = ok; done["checks"] = checks; done["ended_by"] = finished ? "driver" : "deadline"
        done["screenshots"] = ["lifecycle-settings.png"]
        done["not_covered"] = ["由 LaunchServices 启动的真实窗口（它才是 KeyScope.app 自己名下的那份权限；本进程由调用方启动，读到的是调用方的）",
                               "菜单实际弹出与「配置与更新…」窗口上屏：会抢焦点，只核对菜单两项、窗口离屏构造与按钮接线",
                               "update check 的联网读取：由 scripts/accept/lifecycle.sh 在允许联网时另测"]
        emit(done)
        return ok
    }
}
#endif
