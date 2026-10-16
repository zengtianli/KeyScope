import AppKit
#if !APP_STORE
enum ProductLifecycle {
    static let name = "KeyScope · 快捷键侦探"
    static var hostBundle: Bundle { HostBundle.current.appURL.flatMap { Bundle(url:$0) } ?? .main }
    static var updateSource: AppUpdateSource {
        if hostBundle.bundleIdentifier?.hasPrefix("test.tianli.keyscope.basics.") == true,
           ProcessInfo.processInfo.environment["KEYSCOPE_BASICS_FIXTURE"] == "1",
           ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil { return .privateCloud(channel:"isolated") }
        return .github(repository:"zengtianli/KeyScope")
    }
    enum UpdateCommand: String, CaseIterable { case check, install, options }
    static func installApp() {
        let settings = KeyScopeSettings.shared
        AppLifecycleUI.shared.productGroups = { settings.groups() }
        AppLifecycleUI.shared.willShow = { settings.refreshControls() }
        AppLifecycleUI.install(name:name,configuration:settings.configuration,updateSource:updateSource)
        AppLifecycleCLI.follow(settings.configuration)
    }
    static var updateSummary: String { AppLifecycleCLI.helpUpdate.replacingOccurrences(of: #"^\s*update check\s+"#, with:"", options:.regularExpression) }
    static var installSummary: String { AppLifecycleCLI.helpInstall(KeyScopeCLI.commandName).replacingOccurrences(of: #"^\s*update install --yes\s+"#, with:"", options:.regularExpression) }
    static func update(_ arguments:[String]) -> Int32 {
        guard let first = arguments.first, let verb = UpdateCommand(rawValue:first) else {
            return KeyScopeCLI.usageError("用法：keyscope update check|install|options；keyscope help update 查看完整说明",json:arguments.contains("--json"),command:"update")
        }
        let flags: Set<String> = verb == .check ? ["--json"] : ["--json","--yes","--dry-run"]
        let values: Set<String> = verb == .options ? ["--auto-check","--auto-download","--auto-install","--interval","--channel","--skip","--remind"] : []
        switch KeyScopeCLI.parseArguments(arguments,flags:flags,values:values,maxPositionals:1) {
        case .failure(let error): return KeyScopeCLI.usageError(error.message,json:arguments.contains("--json"),command:"update")
        case .success: return run(["update"] + arguments)
        }
    }
    static func run(_ arguments:[String]) -> Int32 {
        var printed:[String] = [];var errors:[String] = []
        var product = AppLifecycleCLI.Product(command:KeyScopeCLI.commandName,name:name,
            configuration:KeyScopeSettings.shared.configuration,updateSource:updateSource)
        product.bundle = hostBundle;product.out = { printed.append($0) };product.err = { errors.append($0) }
        let code = AppLifecycleCLI.run(arguments,product:product)
        let output = printed.joined(separator:"\n")
        if arguments.contains("--json"),var object = (try? JSONSerialization.jsonObject(with:Data(output.utf8))) as? [String:Any] {
            object["schema"] = KeyScopeCLI.schema;KeyScopeCLI.emitJSON(object)
            if code != 0,let error = object["error"] as? [String:Any],let message = error["message"] as? String { errors.append(message) }
        } else if !output.isEmpty { KeyScopeCLI.writeOut(output + "\n") }
        if !errors.isEmpty { KeyScopeCLI.writeErr(errors.map { "keyscope: " + $0 }.joined(separator:"\n") + "\n") }
        return code
    }
}
#endif
