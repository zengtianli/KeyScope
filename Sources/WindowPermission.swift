import AppKit

/// The one channel between a running KeyScope window and the `keyscope` command line.
///
/// macOS records Input Monitoring for the responsible process. `keyscope status` started from a terminal or an
/// agent host reads that host's grant, never KeyScope.app's own; only a KeyScope window process can read the app's.
/// So the command asks, and a running window answers: is Input Monitoring allowed for you right now, and are you
/// showing the permission card?
///
/// One distributed notification each way. Nothing is stored and nothing is written on either side; the window's
/// answer is a fresh CGPreflightListenEventAccess() (the call behind 重新检查权限 — it never prompts and adds no entry
/// to System Settings) plus the value its permission card is drawn from. Answering changes nothing the window shows.
/// When no window runs there is nobody to ask, and the command says so instead of guessing.
enum WindowPermission {
    struct Answer {
        let pid: Int32
        /// KeyScope.app's own Input Monitoring, as the window process reads it at the moment it answers.
        let granted: Bool
        /// Whether the window is showing 首次使用：允许输入监控 (drawn from the value it last checked).
        let cardVisible: Bool
    }

    /// Test only: a private channel name, so an isolated run talks to its own self-test process and never to the
    /// owner's running window (and the owner's commands never reach the self-test).
    static let channelVariable = "KEYSCOPE_WINDOW_CHANNEL"
    static var testChannel: String? {
        guard let value = ProcessInfo.processInfo.environment[channelVariable], !value.isEmpty, value.count <= 64,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        return value
    }
    private static var base: String { "cyou.tianli.keyscope.window-permission" + (testChannel.map { "." + $0 } ?? "") }
    private static var question: Notification.Name { Notification.Name(base + ".question") }
    private static var answer: Notification.Name { Notification.Name(base + ".answer") }

    /// A question carries only a random token; the answer repeats it so a command reads its own answer, not another's.
    private static func validToken(_ text: String) -> Bool { UUID(uuidString: text) != nil }

    // MARK: Window side

    private static var listener: NSObjectProtocol?
    /// How many questions this window process has answered (read by the lifecycle self-test).
    private(set) static var answered = 0

    /// Called once per window process (AppDelegate.installLifecycle). `cardVisible` reads the model value the
    /// permission card is drawn from; `granted` is the system's answer for this process, asked again each time.
    static func answerQuestions(cardVisible: @escaping () -> Bool, granted: @escaping () -> Bool = { CGPreflightListenEventAccess() }) {
        guard listener == nil else { return }
        let center = DistributedNotificationCenter.default()
        listener = center.addObserver(forName: question, object: nil, queue: .main) { note in
            guard let token = note.object as? String, validToken(token) else { return }
            let text = "\(token) pid=\(getpid()) granted=\(granted() ? 1 : 0) card=\(cardVisible() ? 1 : 0)"
            center.postNotificationName(answer, object: text, userInfo: nil, deliverImmediately: true)
            answered += 1
        }
    }

    // MARK: Command side

    static let timeout: TimeInterval = 1

    /// Asks every running window once and keeps the run loop turning until each listed process has answered or
    /// `timeout` has passed (counted in awake time). With a test channel there is no list: the first answer ends it.
    /// Returns the answers received, lowest pid first; an older window build does not answer.
    static func ask(_ pids: [Int32], timeout: TimeInterval = WindowPermission.timeout) -> [Answer] {
        let token = UUID().uuidString
        var answers: [Int32: Answer] = [:]
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: answer, object: nil, queue: nil) { note in
            guard let parsed = parse(note.object as? String, token: token) else { return }
            answers[parsed.pid] = parsed
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(question, object: token, userInfo: nil, deliverImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pids.isEmpty ? !answers.isEmpty : pids.allSatisfy({ answers[$0] != nil }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return answers.values.sorted { $0.pid < $1.pid }
    }

    /// "<token> pid=<n> granted=<0|1> card=<0|1>"; anything else, or another command's token, is ignored.
    static func parse(_ text: String?, token: String) -> Answer? {
        guard let words = text?.split(separator: " ").map(String.init), words.count == 4, words[0] == token else { return nil }
        func value(_ word: String, _ key: String) -> Int32? { word.hasPrefix(key + "=") ? Int32(word.dropFirst(key.count + 1)) : nil }
        guard let pid = value(words[1], "pid"), pid > 0, let granted = value(words[2], "granted"), let card = value(words[3], "card"),
              (0...1).contains(granted), (0...1).contains(card) else { return nil }
        return Answer(pid: pid, granted: granted == 1, cardVisible: card == 1)
    }
}
