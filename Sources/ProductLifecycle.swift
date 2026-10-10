import AppKit

/// KeyScope's side of the shared「配置与更新」layer (AppLifecycle*.swift, byte copies of swift-shared). This file is
/// the one place that names the product and its release channel: the window (`installApp`) and the `keyscope update`
/// commands (`update`) are both built from it, so they read the same channel and report the same version.
///
/// KeyScope has no portable settings. `configuration` is nil on both sides: the window shows no 配置 group, the
/// command line has no `config` commands, and nothing here stores, exports, imports or syncs anything. Two sentences
/// reach the shared command layer and no others: `update check`, which only reads (this app's version and the public
/// release record of the channel), and `update install`, the window's「升级到新版…」through the same installer. It
/// replaces this app only when a newer release exists and the caller passed --yes; it is the one command that writes.
enum ProductLifecycle {
    static let name = "KeyScope · 快捷键侦探"
    /// The one release channel. The window's「检查更新」and the `keyscope update` commands all read it.
    static let updateSource: AppUpdateSource = .github(repository: "zengtianli/KeyScope")

    /// The only sentences this product hands the shared command layer (scripts/accept/privacy.sh reads this line).
    enum UpdateCommand: String, CaseIterable { case check, install }

    // MARK: App side

    /// Called once from a launch (AppDelegate.installLifecycle), and by the lifecycle self-test to run the same code offscreen.
    static func installApp() {
        AppLifecycleUI.install(name: name, configuration: nil, updateSource: updateSource)
    }

    // MARK: Command side

    /// The .app this executable lives in. Through the ~/.local/bin link Bundle.main has no Info.plist or identifier;
    /// version, build and bundle id come from the resolved executable's bundle (the same one `keyscope status` reports).
    /// `update install` replaces exactly this bundle, so it must be the real .app and not the link's folder.
    static var hostBundle: Bundle { HostBundle.current.appURL.flatMap { Bundle(url: $0) } ?? .main }

    /// The shared layer's own sentences for these commands, so the help follows them when they change.
    static var updateSummary: String { sentence(AppLifecycleCLI.helpUpdate, after: "update check") }
    static var installSummary: String { sentence(AppLifecycleCLI.helpInstall(KeyScopeCLI.commandName), after: "update install --yes") }
    private static func sentence(_ line: String, after syntax: String) -> String {
        guard let range = line.range(of: syntax) else { return line.trimmingCharacters(in: .whitespaces) }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// `keyscope update check [--json]` and `keyscope update install --yes [--dry-run] [--json]`. `arguments` follows
    /// the verb `update`; call on the main thread.
    /// Arguments are checked here the way every KeyScope command checks them (unknown options and extra words are
    /// errors; --yes and --dry-run exist for `install` only), so the shared layer only ever receives one of the two
    /// sentences above. Its result is passed on unchanged, inside KeyScope's envelope: `schema` is added, and a
    /// failure also names its reason on stderr.
    static func update(_ arguments: [String]) -> Int32 {
        typealias CLI = KeyScopeCLI
        let named = arguments.first { !$0.hasPrefix("-") }.flatMap(UpdateCommand.init(rawValue:))
        let options = named == .install ? ["--json", "--yes", "--dry-run"] : ["--json"]
        let parsed: CLI.Arguments
        switch CLI.parseArguments(arguments, flags: Set(options), values: [], maxPositionals: 1) {
        case .success(let value): parsed = value
        case .failure(let error): return CLI.usageError(error.message, json: arguments.contains("--json"), command: "update")
        }
        guard let verb = parsed.positionals.first.flatMap(UpdateCommand.init(rawValue:)) else {
            let message = parsed.positionals.first.map { "update 没有「\($0)」这个子命令；只有 keyscope update check 与 keyscope update install" }
                ?? "update 需要子命令：keyscope update check，或 keyscope update install --yes"
            return CLI.usageError(message, json: parsed.json, command: "update")
        }
        var printed: [String] = [], complaints: [String] = []
        var product = AppLifecycleCLI.Product(command: CLI.commandName, name: name, configuration: nil, updateSource: updateSource)
        product.bundle = hostBundle
        product.out = { printed.append($0) }
        product.err = { complaints.append($0) }
        let code = AppLifecycleCLI.run(["update", verb.rawValue] + options.filter(parsed.flags.contains), product: product)
        let text = printed.joined(separator: "\n")
        guard parsed.json else {
            if !text.isEmpty { CLI.writeOut(text + "\n") }
            if !complaints.isEmpty { CLI.writeErr("keyscope: " + complaints.joined(separator: "\n") + "\n") }
            return code
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            // Not expected: the shared layer always prints one object with --json. Say so instead of printing nothing.
            return CLI.fail("update \(verb.rawValue)", code: "failed", message: "\(verb == .check ? "检查更新" : "升级")没有返回可读的结果",
                            exit: code == 0 ? CLI.ExitCode.failure : code, json: true)
        }
        object["schema"] = CLI.schema
        if code != 0, let message = (object["error"] as? [String: Any])?["message"] as? String { CLI.writeErr("keyscope: \(message)\n") }
        CLI.emitJSON(object)
        return code
    }
}
