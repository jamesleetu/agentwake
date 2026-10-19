import Darwin
import Foundation
import IOKit.pwr_mgt

let version = "0.1.0"

// MARK: - Paths & config

let env = ProcessInfo.processInfo.environment
let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/agentwake", isDirectory: true)
let minNotifySeconds = Double(env["AGENTWAKE_MIN_NOTIFY"] ?? "") ?? 30
let maxHoldHours = Double(env["AGENTWAKE_MAX_HOURS"] ?? "") ?? 6
// AGENTWAKE_NOTIFY=0 turns off the desktop banner (e.g. when another tool already notifies); ntfy push is unaffected.
let desktopNotify = !["0", "false", "off", "no"].contains((env["AGENTWAKE_NOTIFY"] ?? "").lowercased())

// MARK: - Localization

let korean = (env["AGENTWAKE_LANG"] ?? Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("ko")
func t(_ ko: String, _ en: String) -> String { korean ? ko : en }

// MARK: - State

struct HoldState: Codable {
    var holderPid: Int32
    var targetPid: Int32
    var startedAt: Date
    var label: String
}

func stateURL(_ key: String) -> URL {
    let safe = key.replacingOccurrences(of: "/", with: "_")
    return stateDir.appendingPathComponent("\(safe).json")
}

func readState(_ url: URL) -> HoldState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(HoldState.self, from: data)
}

func writeState(_ state: HoldState, key: String) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(state) {
        try? data.write(to: stateURL(key), options: .atomic)
    }
}

func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

// MARK: - Power assertion (IOKit)

func createAssertion(_ reason: String) -> IOPMAssertionID? {
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "agentwake: \(reason)" as CFString,
        &id)
    return result == kIOReturnSuccess ? id : nil
}

// MARK: - Process helpers (libproc)

func processName(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buf, UInt32(buf.count))
    return String(cString: buf)
}

func parentPid(_ pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int32(info.pbi_ppid)
}

/// Hook commands run under a shell spawned by Claude Code; walk up to find the claude process itself.
func findClaudeAncestor() -> Int32 {
    var pid = getppid()
    for _ in 0..<10 {
        let name = processName(pid)
        if name == "claude" || name == "claude.exe" { return pid }
        guard let parent = parentPid(pid), parent > 1 else { break }
        pid = parent
    }
    return getppid()
}

// MARK: - Notifications

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 60 { return t("\(s)초", "\(s)s") }
    if s < 3600 { return t("\(s / 60)분 \(s % 60)초", "\(s / 60)m \(s % 60)s") }
    return t("\(s / 3600)시간 \(s % 3600 / 60)분", "\(s / 3600)h \(s % 3600 / 60)m")
}

func findExecutable(_ name: String) -> String? {
    let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin"]
    return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func runQuietly(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func notify(title: String, message: String) {
    if !desktopNotify {
        // skip the banner, fall through to the optional push
    } else if let tn = findExecutable("terminal-notifier") {
        runQuietly(tn, ["-title", title, "-message", message, "-sound", "Glass", "-group", "agentwake"])
    } else {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        runQuietly("/usr/bin/osascript", ["-e", "display notification \"\(esc(message))\" with title \"\(esc(title))\" sound name \"Glass\""])
    }

    // Optional iPhone push via ntfy.sh (free): set AGENTWAKE_NTFY_TOPIC and subscribe in the ntfy app.
    if let topic = env["AGENTWAKE_NTFY_TOPIC"], !topic.isEmpty,
       let url = URL(string: "https://ntfy.sh/\(topic)") {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = message.data(using: .utf8)
        req.setValue(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "agentwake", forHTTPHeaderField: "Title")
        req.setValue("utf-8", forHTTPHeaderField: "X-Title-Encoding")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }
}

// MARK: - Detached holder process

/// Spawns `agentwake hold ...` in its own session with stdio on /dev/null,
/// so Claude Code doesn't wait on it and it survives the hook's exit.
func spawnDetachedHolder(_ args: [String]) -> Int32? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    for fd in [0, 1, 2] {
        posix_spawn_file_actions_addopen(&actions, Int32(fd), "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    let argv = ([exe] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, &attr, argv, environ)
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    return rc == 0 ? pid : nil
}

/// Holds the assertion until SIGTERM, the target process exits (kqueue), or the timeout.
func runHolder(key: String, targetPid: Int32, label: String) -> Never {
    guard let assertion = createAssertion(label) else { exit(1) }
    writeState(HoldState(holderPid: getpid(), targetPid: targetPid, startedAt: Date(), label: label), key: key)

    func finish() -> Never {
        IOPMAssertionRelease(assertion)
        if readState(stateURL(key))?.holderPid == getpid() {
            try? FileManager.default.removeItem(at: stateURL(key))
        }
        exit(0)
    }

    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { finish() }
    term.resume()

    let exitWatch = DispatchSource.makeProcessSource(identifier: targetPid, eventMask: .exit, queue: .main)
    exitWatch.setEventHandler { finish() }
    exitWatch.resume()
    if !isAlive(targetPid) { finish() }

    DispatchQueue.main.asyncAfter(deadline: .now() + maxHoldHours * 3600) { finish() }
    dispatchMain()
}

// MARK: - Commands

/// Claude Code hook entry point. Reads the hook JSON from stdin.
func hookCommand(_ action: String) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    let session = json["session_id"] as? String ?? "pid-\(findClaudeAncestor())"
    let cwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    let project = URL(fileURLWithPath: cwd).lastPathComponent
    let key = "claude-\(session)"
    let existing = readState(stateURL(key)).flatMap { isAlive($0.holderPid) ? $0 : nil }

    switch action {
    case "start":
        if existing != nil { return }
        _ = spawnDetachedHolder(["hold", "--key", key, "--pid", String(findClaudeAncestor()), "--label", project])
    case "stop":
        guard let state = existing else { return }
        kill(state.holderPid, SIGTERM)
        let elapsed = Date().timeIntervalSince(state.startedAt)
        if elapsed >= minNotifySeconds {
            let failed = (json["hook_event_name"] as? String) == "StopFailure"
            notify(title: failed ? t("⚠️ Claude 작업 실패", "⚠️ Claude task failed") : t("✅ Claude 작업 완료", "✅ Claude task done"),
                   message: "\(state.label) · \(formatDuration(elapsed))")
        }
    default:
        usage()
    }
}

/// `agentwake run -- cmd args...`: keeps the Mac awake while a command runs.
func runCommand(_ args: [String]) -> Never {
    guard !args.isEmpty else { usage() }
    let label = args.joined(separator: " ")
    let assertion = createAssertion(label)
    let start = Date()

    let p = Process()
    p.executableURL = URL(fileURLWithPath: findExecutable(args[0]) ?? args[0])
    p.arguments = Array(args.dropFirst())
    // Ctrl-C reaches the child via the shared process group; just don't die before it does.
    signal(SIGINT, SIG_IGN)
    do { try p.run() } catch {
        fputs(t("agentwake: \(args[0]) 실행 실패: ", "agentwake: failed to run \(args[0]): ") + error.localizedDescription + "\n", stderr)
        exit(127)
    }
    p.waitUntilExit()
    if let assertion { IOPMAssertionRelease(assertion) }

    let elapsed = Date().timeIntervalSince(start)
    let code = p.terminationStatus
    if elapsed >= minNotifySeconds {
        notify(title: code == 0 ? t("✅ 완료", "✅ Done") : t("❌ 실패 (exit \(code))", "❌ Failed (exit \(code))"),
               message: "\(label) · \(formatDuration(elapsed))")
    }
    exit(code)
}

/// `agentwake wait <pid>`: keeps awake until an already-running process exits.
func waitCommand(_ pidString: String) -> Never {
    guard let pid = Int32(pidString), isAlive(pid) else {
        fputs(t("agentwake: 프로세스 \(pidString)를 찾을 수 없습니다\n", "agentwake: no such process \(pidString)\n"), stderr)
        exit(1)
    }
    let name = processName(pid)
    let assertion = createAssertion("pid \(pid) \(name)")
    let start = Date()
    print(t("⏳ \(name) (pid \(pid)) 종료까지 잠자기 방지 중…", "⏳ Keeping awake until \(name) (pid \(pid)) exits…"))

    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler {
        if let assertion { IOPMAssertionRelease(assertion) }
        notify(title: t("✅ 프로세스 종료", "✅ Process exited"), message: "\(name) · \(formatDuration(Date().timeIntervalSince(start)))")
        exit(0)
    }
    source.resume()
    dispatchMain()
}

func statusCommand() {
    let files = (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? []
    var active = 0
    for url in files where url.pathExtension == "json" {
        guard let s = readState(url) else { continue }
        if !isAlive(s.holderPid) {
            try? FileManager.default.removeItem(at: url)
            continue
        }
        active += 1
        let elapsed = formatDuration(Date().timeIntervalSince(s.startedAt))
        print(t("☕️ \(s.label)  ·  \(elapsed) 경과  ·  claude pid \(s.targetPid)",
                "☕️ \(s.label)  ·  \(elapsed) elapsed  ·  claude pid \(s.targetPid)"))
    }
    if active == 0 { print(t("💤 잠자기 방지 중인 작업 없음", "💤 Nothing is keeping the Mac awake")) }
}

// MARK: - Claude Code settings integration

let hookEvents: [(event: String, action: String)] = [
    ("UserPromptSubmit", "start"), ("Stop", "stop"), ("StopFailure", "stop"), ("SessionEnd", "stop"),
]

func settingsURL() -> URL {
    let dir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    return dir.appendingPathComponent("settings.json")
}

/// The path hooks should call. Symlinks are kept on purpose: Homebrew's /opt/homebrew/bin link
/// survives upgrades, while the resolved Cellar path would break on the next version.
func selfPathForHooks() -> String {
    let arg0 = CommandLine.arguments[0]
    if arg0.contains("/") { return URL(fileURLWithPath: arg0).standardizedFileURL.path }
    return findExecutable(arg0) ?? arg0
}

func shellQuote(_ s: String) -> String {
    s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+".contains($0) }) ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func isAgentwakeHook(_ entry: Any) -> Bool {
    guard let command = (entry as? [String: Any])?["command"] as? String else { return false }
    return command.contains("agentwake") && (command.contains("hook start") || command.contains("hook stop"))
}

/// Removes our hooks from every event, dropping matcher groups and events left empty.
func strippingAgentwakeHooks(_ hooks: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
        let kept = groups.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [Any] else { return group }
            let remaining = entries.filter { !isAgentwakeHook($0) }
            if remaining.isEmpty { return nil }
            var g = group
            g["hooks"] = remaining
            return g
        }
        if !kept.isEmpty { result[event] = kept }
    }
    return result
}

func loadSettings(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fputs(t("❌ \(url.path)를 JSON으로 읽을 수 없어 수정하지 않았습니다\n",
                "❌ \(url.path) is not valid JSON; left untouched\n"), stderr)
        exit(1)
    }
    return obj
}

func saveSettings(_ settings: [String: Any], to url: URL) {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        let backup = url.appendingPathExtension("agentwake.bak")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: url, to: backup)
        print(t("   백업: \(backup.path)", "   Backup: \(backup.path)"))
    }
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
    try! data.write(to: url, options: .atomic)
}

func installHooks(quiet: Bool) {
    let url = settingsURL()
    var settings = loadSettings(url)
    var hooks = strippingAgentwakeHooks(settings["hooks"] as? [String: Any] ?? [:])
    let exe = shellQuote(selfPathForHooks())
    for (event, action) in hookEvents {
        let prefix = quiet && action == "stop" ? "AGENTWAKE_NOTIFY=0 " : ""
        let entry: [String: Any] = ["type": "command", "command": "\(prefix)\(exe) hook \(action) 2>/dev/null || true", "timeout": 10]
        var groups = hooks[event] as? [[String: Any]] ?? []
        groups.append(["hooks": [entry]])
        hooks[event] = groups
    }
    settings["hooks"] = hooks
    saveSettings(settings, to: url)
    print(t("✅ Claude Code hook 연결 완료: \(url.path)", "✅ Claude Code hooks installed: \(url.path)"))
    print(t("   새 Claude Code 세션부터 적용됩니다 (실행 중인 세션은 /hooks를 한 번 열면 반영)",
            "   Takes effect in new sessions (open /hooks once to reload a running session)"))
}

func uninstallHooks() {
    let url = settingsURL()
    var settings = loadSettings(url)
    guard let hooks = settings["hooks"] as? [String: Any] else {
        print(t("연결된 hook이 없습니다", "No agentwake hooks found"))
        return
    }
    let stripped = strippingAgentwakeHooks(hooks)
    if stripped.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = stripped }
    saveSettings(settings, to: url)
    print(t("🗑  agentwake hook 제거 완료", "🗑  agentwake hooks removed"))
}

func usage() -> Never {
    print(t("""
    agentwake \(version) — 작업이 도는 동안만 Mac 잠자기를 막고, 끝나면 알려줍니다

      agentwake install-hooks [--quiet]  Claude Code에 연결 (--quiet: 완료 알림 끄기)
      agentwake uninstall-hooks          Claude Code 연결 해제
      agentwake run -- <명령...>          명령 실행 중 잠자기 방지 + 완료 알림
      agentwake wait <pid>               이미 실행 중인 프로세스가 끝날 때까지 방지
      agentwake status                   현재 잠자기 방지 중인 Claude 세션

    환경 변수: AGENTWAKE_MIN_NOTIFY(초, 기본 30)  AGENTWAKE_MAX_HOURS(기본 6)
               AGENTWAKE_NOTIFY=0(데스크톱 알림 끄기)  AGENTWAKE_NTFY_TOPIC(ntfy.sh 푸시)
               AGENTWAKE_LANG=en|ko
    """, """
    agentwake \(version) — keeps your Mac awake while agents and commands run, and tells you when they finish

      agentwake install-hooks [--quiet]  Connect to Claude Code (--quiet: no done notifications)
      agentwake uninstall-hooks          Disconnect from Claude Code
      agentwake run -- <command...>      Keep awake while a command runs, notify when done
      agentwake wait <pid>               Keep awake until a running process exits
      agentwake status                   Show Claude sessions currently keeping the Mac awake

    Environment: AGENTWAKE_MIN_NOTIFY (seconds, default 30)  AGENTWAKE_MAX_HOURS (default 6)
                 AGENTWAKE_NOTIFY=0 (no desktop banner)  AGENTWAKE_NTFY_TOPIC (ntfy.sh push)
                 AGENTWAKE_LANG=en|ko
    """))
    exit(2)
}

// MARK: - Entry

var argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "run":
    argv.removeFirst()
    if argv.first == "--" { argv.removeFirst() }
    runCommand(argv)
case "wait" where argv.count == 2:
    waitCommand(argv[1])
case "status":
    statusCommand()
case "hook" where argv.count == 2:
    hookCommand(argv[1])
case "install-hooks":
    installHooks(quiet: argv.contains("--quiet"))
case "uninstall-hooks":
    uninstallHooks()
case "--version", "-v":
    print(version)
case "hold":
    var opts: [String: String] = [:]
    var i = 1
    while i + 1 < argv.count { opts[argv[i]] = argv[i + 1]; i += 2 }
    guard let key = opts["--key"], let pid = Int32(opts["--pid"] ?? "") else { exit(2) }
    runHolder(key: key, targetPid: pid, label: opts["--label"] ?? key)
default:
    usage()
}
