import SwiftUI
import AppKit
import Foundation
import UserNotifications
import Charts
import ServiceManagement

// MARK: - Models

struct BalanceInfo: Codable, Identifiable {
    let currency: String
    let total_balance: String
    let granted_balance: String
    let topped_up_balance: String
    var id: String { currency }
}

struct BalanceResponse: Codable {
    let is_available: Bool
    let balance_infos: [BalanceInfo]
}

struct RechargeHistoryEntry: Codable {
    let time: String
    let amount: Double
    let balance_after: Double
    let note: String
}

struct RechargeRecord: Codable {
    var total: Double
    var initial: Double
    var last_balance: Double?
    var history: [RechargeHistoryEntry]
}

struct SessionInfo: Identifiable {
    let id: String
    let title: String
    let cwd: String?
    let start: Date
    let end: Date
    let total: Int
    let input: Int
    let output: Int
    let activeDuration: TimeInterval
}

struct ProjectStat: Identifiable {
    let path: String
    let name: String       // 目录名（英文/路径）
    let title: String      // 中文会话标题（最近一次会话）
    let firstStart: Date
    let lastActive: Date
    let sessionCount: Int
    let totalTokens: Int
    let totalDuration: TimeInterval // 真实运行时长（活跃时间累计）
    let age: TimeInterval           // 项目自创建至今
    var id: String { path }
}

struct RechargeEvent: Identifiable {
    let id: String
    let time: Date
    let amount: Double
}

enum RechargeStore {
    static func loadEvents() -> [RechargeEvent] {
        guard let data = try? Data(contentsOf: AppPaths.rechargeFile),
              let r = try? JSONDecoder().decode(RechargeRecord.self, from: data) else { return [] }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return r.history.enumerated().compactMap { idx, entry in
            guard let d = f.date(from: entry.time) else { return nil }
            return RechargeEvent(id: "recharge-\(idx)", time: d, amount: entry.amount)
        }
    }
}

struct BalanceReading: Codable {
    let t: String // ISO8601 UTC
    let b: Double
}

enum BalanceStore {
    private static let maxEntries = 3000

    static func load() -> [BalanceReading] {
        guard let data = try? Data(contentsOf: AppPaths.balanceHistoryFile),
              let r = try? JSONDecoder().decode([BalanceReading].self, from: data) else { return [] }
        return r
    }

    static func append(balance: Double) {
        var list = load()
        if let last = list.last, abs(last.b - balance) < 0.001 { return }
        let iso = ISO8601DateFormatter()
        list.append(BalanceReading(t: iso.string(from: Date()), b: balance))
        if list.count > maxEntries {
            list.removeFirst(list.count - maxEntries)
        }
        AppPaths.ensureDir()
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: AppPaths.balanceHistoryFile, options: [.atomic])
        }
    }
}

// MARK: - DeepSeek 官网消耗记录（官方 usage/cost 接口，需平台 userToken）

struct PlatformDayUsage: Codable {
    let date: String      // yyyy-MM-dd
    var cost: Double      // 元
    var tokens: Int       // tokens
    var updatedAt: String // ISO8601
}

enum PlatformAPI {
    static var token: String? {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = json["deepseek_platform_token"] as? String, !t.isEmpty else { return nil }
        return t
    }

    static func saveToken(_ t: String) {
        AppPaths.ensureDir()
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        json["deepseek_platform_token"] = t
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: AppPaths.configFile, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
        }
    }

    static func fetchMonthCost(month: Int, year: Int, token: String) async throws -> [String: Double] {
        let url = URL(string: "https://platform.deepseek.com/api/v0/usage/cost?month=\(month)&year=\(year)")!
        let data = try await get(url: url, token: token)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["code"] as? Int) == 0,
              let bizData = ((obj["data"] as? [String: Any])?["biz_data"] as? [[String: Any]])?.first else {
            throw PlatformAPIError.badResponse
        }
        var out: [String: Double] = [:]
        for day in (bizData["days"] as? [[String: Any]] ?? []) {
            guard let date = day["date"] as? String else { continue }
            var total = 0.0
            for model in (day["data"] as? [[String: Any]] ?? []) {
                for item in (model["usage"] as? [[String: Any]] ?? []) {
                    let type = ((item["type"] as? String) ?? "").uppercased()
                    if type == "REQUEST" { continue }
                    if let amt = Double((item["amount"] as? String) ?? "") { total += amt }
                }
            }
            if total > 0 { out[date] = total }
        }
        return out
    }

    static func fetchMonthAmount(month: Int, year: Int, token: String) async throws -> [String: Int] {
        let url = URL(string: "https://platform.deepseek.com/api/v0/usage/amount?month=\(month)&year=\(year)")!
        let data = try await get(url: url, token: token)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["code"] as? Int) == 0,
              let bizData = ((obj["data"] as? [String: Any])?["biz_data"] as? [String: Any]) else {
            throw PlatformAPIError.badResponse
        }
        var out: [String: Int] = [:]
        for day in (bizData["days"] as? [[String: Any]] ?? []) {
            guard let date = day["date"] as? String else { continue }
            var total = 0
            for model in (day["data"] as? [[String: Any]] ?? []) {
                for item in (model["usage"] as? [[String: Any]] ?? []) {
                    let type = ((item["type"] as? String) ?? "").uppercased()
                    if type == "REQUEST" { continue }
                    if let n = Int64((item["amount"] as? String) ?? "") { total += Int(n) }
                }
            }
            if total > 0 { out[date] = total }
        }
        return out
    }

    private static func get(url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 || http.statusCode == 403 { throw PlatformAPIError.invalidToken }
            throw PlatformAPIError.http(http.statusCode)
        }
        return data
    }
}

enum PlatformAPIError: Error, LocalizedError {
    case invalidToken, http(Int), badResponse
    var errorDescription: String? {
        switch self {
        case .invalidToken: return "平台 Token 无效或已过期，请重新接入"
        case .http(let code): return "官网接口 HTTP \(code)"
        case .badResponse: return "官网接口响应异常"
        }
    }
}

enum PlatformStore {
    private static let iso = ISO8601DateFormatter()
    private static var memory: [String: PlatformDayUsage] = [:]
    private static var loaded = false
    private static var lastFetchByMonth: [String: Date] = [:]
    private static let lock = NSLock()

    static func load() -> [String: PlatformDayUsage] {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: AppPaths.platformUsageFile),
               let dict = try? JSONDecoder().decode([String: PlatformDayUsage].self, from: data) {
                memory = dict
            }
        }
        return memory
    }

    static func dayCosts() -> [String: Double] {
        load().mapValues { $0.cost }
    }

    static func dayTokens() -> [String: Int] {
        load().mapValues { $0.tokens }
    }

    private static func withLocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func refreshMonths(from: Date, to: Date, minInterval: TimeInterval = 60, force: Bool = false) async {
        guard let token = PlatformAPI.token else { return }
        let cal = Calendar.current
        guard let end = cal.dateInterval(of: .month, for: to)?.start else { return }
        let maxStart = cal.date(byAdding: .month, value: -24, to: end) ?? end
        let rawStart = cal.dateInterval(of: .month, for: from)?.start ?? end
        let start = max(rawStart, maxStart)
        var months: [(Int, Int)] = []
        var cursor = start
        while cursor <= end {
            let c = cal.dateComponents([.year, .month], from: cursor)
            if let y = c.year, let m = c.month { months.append((m, y)) }
            cursor = cal.date(byAdding: .month, value: 1, to: cursor) ?? cursor.addingTimeInterval(2_592_000)
        }
        if months.count > 24 { months = Array(months.suffix(24)) }
        if months.isEmpty { return }

        for (m, y) in months {
            let key = String(format: "%04d-%02d", y, m)
            let skip = withLocked {
                !force && (lastFetchByMonth[key].map { Date().timeIntervalSince($0) < minInterval } ?? false)
            }
            if skip { continue }
            do {
                let costs = try await PlatformAPI.fetchMonthCost(month: m, year: y, token: token)
                let amounts = try await PlatformAPI.fetchMonthAmount(month: m, year: y, token: token)
                withLocked {
                    for (date, cost) in costs {
                        if var e = memory[date] {
                            e.cost = cost
                            if let t = amounts[date] { e.tokens = t }
                            e.updatedAt = iso.string(from: Date())
                            memory[date] = e
                        } else {
                            memory[date] = PlatformDayUsage(date: date, cost: cost, tokens: amounts[date] ?? 0, updatedAt: iso.string(from: Date()))
                        }
                    }
                    for (date, t) in amounts where memory[date] == nil {
                        memory[date] = PlatformDayUsage(date: date, cost: 0, tokens: t, updatedAt: iso.string(from: Date()))
                    }
                    AppPaths.ensureDir()
                    if let data = try? JSONEncoder().encode(memory) {
                        try? data.write(to: AppPaths.platformUsageFile, options: [.atomic])
                    }
                    lastFetchByMonth[key] = Date()
                }
            } catch {
                withLocked {
                    if error is PlatformAPIError {
                        lastFetchByMonth[key] = nil // 失败可重试
                    }
                }
            }
        }
    }
}

enum PlatformSetup {
    private final class FieldController: NSObject {
        let field: NSTextField
        init(field: NSTextField) { self.field = field }
        @objc func readPasteboard() {
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                field.stringValue = s
            }
        }
    }

    @MainActor
    static func promptAndSave(model: BalanceModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "接入 DeepSeek 官网记录"
        alert.informativeText = "浏览器登录 platform.deepseek.com → 开发者工具 Console 输入 localStorage.getItem('userToken') 回车，复制返回的字符串。\n可点「读取剪贴板」自动填入，或手动粘贴。Token 仅存本机 config.json（权限 600）。"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "粘贴 userToken…"
        let pasteBtn = NSButton(title: "读取剪贴板", target: nil, action: nil)
        pasteBtn.bezelStyle = .rounded
        pasteBtn.frame = NSRect(x: 0, y: 0, width: 120, height: 26)
        let stack = NSStackView(views: [field, pasteBtn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 70)
        alert.accessoryView = stack

        let ctrl = FieldController(field: field)
        pasteBtn.target = ctrl
        pasteBtn.action = #selector(FieldController.readPasteboard)

        alert.addButton(withTitle: "保存并刷新")
        alert.addButton(withTitle: "取消")
        withExtendedLifetime(ctrl) {
            alert.window.initialFirstResponder = field
            field.becomeFirstResponder()
            if alert.runModal() == .alertFirstButtonReturn {
                let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { model.savePlatformToken(t) }
            }
        }
    }
}

enum TextPrompt {
    @MainActor
    static func prompt(title: String, informative: String, placeholder: String, okTitle: String = "保存") -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "取消")
        var result: String? = nil
        withExtendedLifetime(field) {
            alert.window.initialFirstResponder = field
            field.becomeFirstResponder()
            if alert.runModal() == .alertFirstButtonReturn {
                let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { result = t }
            }
        }
        return result
    }
}

enum APIKeySetup {
    @MainActor
    static func promptAndSave(model: BalanceModel) {
        if let key = TextPrompt.prompt(
            title: "设置 DeepSeek API Key",
            informative: "在 https://platform.deepseek.com/api_keys 创建 API Key，粘贴到下方。\nKey 仅保存在本机 config.json（权限 600），不上传。",
            placeholder: "sk-…") {
            model.saveAPIKey(key)
        }
    }
}

enum LaunchItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func setEnabled(_ on: Bool) throws {
        if #available(macOS 13.0, *) {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } else {
            throw NSError(domain: "DeepSeekBalance", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要 macOS 13 或更高版本"])
        }
    }
}

enum TokenStatsParser {
    private static let tokenKeyData = Data("total_token_usage".utf8)
    private static let cwdKeyData = Data("\"cwd\"".utf8)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func collectSessions() -> [SessionInfo] {
        let fm = FileManager.default
        let sessionsRoot = AppPaths.sessionsRoot
        let titleMap = loadSessionTitleMap()
        guard let en = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SessionInfo] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"),
                  let meta = sessionMetaFromFilename(name),
                  let usage = sessionInfoFromFile(url) else { continue }
            result.append(SessionInfo(
                id: meta.id,
                title: titleMap[meta.id] ?? "未命名会话",
                cwd: usage.cwd,
                start: meta.date,
                end: usage.end,
                total: usage.total,
                input: usage.input,
                output: usage.output,
                activeDuration: usage.active
            ))
        }
        return result.sorted { $0.start > $1.start }
    }

    static func collectProjects() -> [ProjectStat] {
        let sessions = collectSessions()
        var groups: [String: [SessionInfo]] = [:]
        for s in sessions {
            groups[s.cwd ?? "未知项目", default: []].append(s)
        }
        var result: [ProjectStat] = []
        for (path, list) in groups {
            let name = path == "未知项目" ? path : (path as NSString).lastPathComponent
            let latest = list.max { $0.end < $1.end } ?? list.first
            let title = (latest?.title.isEmpty ?? true) ? name : latest!.title
            let firstStart = list.map(\.start).min() ?? .distantPast
            result.append(ProjectStat(
                path: path,
                name: name,
                title: title,
                firstStart: firstStart,
                lastActive: list.map(\.end).max() ?? .distantPast,
                sessionCount: list.count,
                totalTokens: list.reduce(0) { $0 + $1.total },
                totalDuration: list.reduce(0) { $0 + $1.activeDuration },
                age: max(0, Date().timeIntervalSince(firstStart))
            ))
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    private static func sessionMetaFromFilename(_ name: String) -> (id: String, date: Date)? {
        let parts = name.split(separator: "-")
        guard parts.count >= 11 else { return nil }
        let dateStr = "\(parts[1])-\(parts[2])-\(parts[3]):\(parts[4]):\(parts[5])"
        var id = parts[6..<11].joined(separator: "-")
        if id.hasSuffix(".jsonl") { id.removeLast(6) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let date = f.date(from: dateStr) else { return nil }
        return (id, date)
    }

    private static func sessionInfoFromFile(_ url: URL) -> (cwd: String?, end: Date, total: Int, input: Int, output: Int, active: TimeInterval)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var cwd: String? = nil
        var lastTimestampRaw: String? = nil
        var total = 0, input = 0, output = 0
        var lastEvent: Date? = nil
        var active: TimeInterval = 0
        let idleThreshold: TimeInterval = 300 // 事件间隔 > 5 分钟视为空闲
        var leftover = Data()

        func findCwd(_ value: Any) -> String? {
            if let dict = value as? [String: Any] {
                if let c = dict["cwd"] as? String { return c }
                for v in dict.values { if let c = findCwd(v) { return c } }
            } else if let arr = value as? [Any] {
                for v in arr { if let c = findCwd(v) { return c } }
            }
            return nil
        }

        func process(_ line: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let ts = obj["timestamp"] as? String {
                lastTimestampRaw = ts
                if let d = isoFormatter.date(from: ts) ?? isoFormatterNoFrac.date(from: ts) {
                    if let prev = lastEvent {
                        let delta = d.timeIntervalSince(prev)
                        if delta > 0 && delta <= idleThreshold {
                            active += delta
                        }
                    }
                    lastEvent = d
                }
            }
            if cwd == nil, let c = findCwd(obj) { cwd = c }
            if let payload = obj["payload"] as? [String: Any],
               let info = payload["info"] as? [String: Any],
               let ttu = info["total_token_usage"] as? [String: Any] {
                total = ttu["total_tokens"] as? Int ?? total
                input = ttu["input_tokens"] as? Int ?? input
                output = ttu["output_tokens"] as? Int ?? output
            }
        }

        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0A) {
                let line = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                process(line)
            }
        }
        if !leftover.isEmpty { process(leftover) }

        guard let raw = lastTimestampRaw else { return nil }
        let end = isoFormatter.date(from: raw) ?? isoFormatterNoFrac.date(from: raw) ?? Date()
        return (cwd, end, total, input, output, active)
    }

    private static func loadSessionTitleMap() -> [String: String] {
        let idx = AppPaths.sessionIndexFile
        guard let content = try? String(contentsOf: idx, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let title = obj["thread_name"] as? String else { continue }
            map[id] = title // 后写覆盖，取最新标题
        }
        return map
    }
}

// MARK: - 路径

enum AppPaths {
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeepSeekBalance", isDirectory: true)
    }
    static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static var sessionsRoot: URL { codexHome.appendingPathComponent("sessions") }
    static var sessionIndexFile: URL { codexHome.appendingPathComponent("session_index.jsonl") }
    static var stateFile: URL { supportDir.appendingPathComponent("state.json") }
    static var rechargeFile: URL { supportDir.appendingPathComponent("recharge.json") }
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var balanceHistoryFile: URL { supportDir.appendingPathComponent("balance_history.json") }
    static var platformUsageFile: URL { supportDir.appendingPathComponent("platform_usage.json") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}

// MARK: - 静态资源（只解码一次，避免每次弹窗重复加载）

enum AppAssets {
    static let whaleGirl: NSImage? = {
        if let img = Bundle.main.image(forResource: "whalegirl-full") { return img }
        if let img = Bundle.main.image(forResource: "whalegirl-a") { return img }
        return Bundle.main.image(forResource: "deepseek-icon")
    }()
}

// MARK: - 通知代理（前台也弹横幅）

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 可观察模型

@MainActor
final class BalanceModel: ObservableObject {
    @Published var totalBalance: String = "—"
    @Published var currency: String = "CNY"
    @Published var toppedUp: String = "—"
    @Published var granted: String = "—"
    @Published var totalRecharge: String = "—"
    @Published var consumedTokens: String = "—"
    @Published var available: Bool? = nil
    @Published var lastUpdated: String = "尚未刷新"
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var isLowBalance: Bool = false
    @Published var isActive: Bool = false // Codex 正在大量消耗 tokens
    @Published var platformConnected: Bool = false // 已接入官网记录
    @Published var apiKeyConfigured: Bool = false // 已配置 API Key
    @Published var menuShowWhale: Bool = false // 菜单栏是否显示 🐋（默认关闭，紧凑不易被挤掉）

    private var timer: Timer?
    private var activityToken: NSObjectProtocol? // 禁用 App Nap，保证定时器准时
    private(set) var refreshInterval: TimeInterval = 300 // 默认 5 分钟，可配置
    private let notificationDelegate = NotificationDelegate()

    private let fastInterval: TimeInterval = 5
    private let activityWindow: TimeInterval = 30 // 会话文件 30 秒内有写入视为活跃
    private var lastRefreshTime: Date = .distantPast
    private var lastPlatformFetch: Date = .distantPast // 官网记录节流（60 秒）
    private var lastTokenScan: Date = .distantPast
    private let tokenScanInterval: TimeInterval = 30 // tokens 每 30 秒重扫，余额 5 秒实时
    private var lowBalanceNotified = false
    let lowBalanceThreshold: Double = 1.0 // 低于 1 元提醒

    var onTitleChanged: (() -> Void)?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private struct TokenCacheEntry { let mtime: Date; let tokens: Int }
    private static var tokenCache: [String: TokenCacheEntry] = [:]

    var currencySymbol: String {
        currency == "CNY" ? "¥" : (currency == "USD" ? "$" : "\(currency) ")
    }

    var menuTitle: String {
        if isLoading && totalBalance == "—" { return "…" }
        if errorMessage != nil && totalBalance == "—" { return "⚠️ ¥--" }
        var title = (menuShowWhale ? "🐋 " : "") + "\(currencySymbol)\(totalBalance)"
        if isActive { title += " ⚡" }
        if isLowBalance { title += " ⚠️" }
        return title
    }

    func start() {
        guard timer == nil else { return }
        refreshInterval = Self.loadRefreshInterval()
        menuShowWhale = Self.loadMenuShowWhale()
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "DeepSeek 余额实时刷新"
            )
        }
        setupNotifications()
        Task { await refresh() }
        scheduleTimer()
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        refreshInterval = max(30, seconds)
        Self.saveRefreshInterval(refreshInterval)
        scheduleTimer()
        onTitleChanged?()
    }

    // MARK: 菜单栏紧凑模式（🐋 开关）

    func setMenuShowWhale(_ on: Bool) {
        menuShowWhale = on
        AppPaths.ensureDir()
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            cfg = json
        }
        cfg["menu_show_whale"] = on
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? data.write(to: AppPaths.configFile, options: [.atomic])
        }
        onTitleChanged?()
    }

    static func loadMenuShowWhale() -> Bool {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = json["menu_show_whale"] as? Bool else { return false }
        return v
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: fastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.adaptiveTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func adaptiveTick() async {
        let active = Self.codexActive(within: activityWindow)
        isActive = active
        let sinceLast = Date().timeIntervalSince(lastRefreshTime)
        if active && sinceLast >= fastInterval {
            await refresh()
        } else if !active && sinceLast >= refreshInterval {
            await refresh()
        }
    }

    static func codexActive(within window: TimeInterval) -> Bool {
        let fm = FileManager.default
        let sessionsRoot = AppPaths.sessionsRoot
        guard let en = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let cutoff = Date().addingTimeInterval(-window)
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime > cutoff {
                return true
            }
        }
        return false
    }

    // MARK: 刷新间隔配置（config.json，可被菜单调整）

    static func loadRefreshInterval() -> TimeInterval {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let secs = json["refresh_interval_seconds"] as? Double,
              secs >= 30 else { return 300 }
        return secs
    }

    static func saveRefreshInterval(_ seconds: TimeInterval) {
        AppPaths.ensureDir()
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            cfg = json
        }
        cfg["refresh_interval_seconds"] = seconds
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? data.write(to: AppPaths.configFile, options: [.atomic])
        }
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func refresh() async {
        if isLoading { return }
        isLoading = true
        lastRefreshTime = Date()
        defer {
            isLoading = false
            onTitleChanged?()
        }

        let now = Date()
        if now.timeIntervalSince(lastTokenScan) >= tokenScanInterval {
            consumedTokens = Self.formatCount(Self.countConsumedTokens())
            lastTokenScan = now
        }

        apiKeyConfigured = Self.loadDeepSeekKey() != nil
        guard let key = Self.loadDeepSeekKey() else {
            errorMessage = "未找到 DeepSeek API Key（点击弹窗「API Key → 设置」配置）"
            writeState(extra: ["error": errorMessage ?? ""])
            return
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData // 禁用缓存，拿最新余额
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                errorMessage = "HTTP \(http.statusCode): \(body.prefix(120))"
                writeState(extra: ["error": errorMessage ?? "", "http": http.statusCode])
                return
            }
            let decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
            let infos = decoded.balance_infos
            let preferred = infos.first { $0.currency == "CNY" && (Double($0.total_balance) ?? 0) > 0 }
                ?? infos.first { (Double($0.total_balance) ?? 0) > 0 }
                ?? infos.first
            if let info = preferred {
                totalBalance = info.total_balance
                currency = info.currency
                toppedUp = info.topped_up_balance
                granted = info.granted_balance
                if let top = Double(info.topped_up_balance) {
                    trackRecharge(currentToppedUp: top)
                }
            }
            available = decoded.is_available
            errorMessage = nil
            lastUpdated = Self.timeFormatter.string(from: Date())
            checkLowBalance()
            if let bal = Double(totalBalance) {
                BalanceStore.append(balance: bal)
            }
            if PlatformAPI.token != nil {
                platformConnected = true
                if Date().timeIntervalSince(lastPlatformFetch) >= 60 {
                    lastPlatformFetch = Date()
                    Task { await PlatformStore.refreshMonths(from: Date(), to: Date(), minInterval: 60) }
                }
            } else {
                platformConnected = false
            }
            writeState()
        } catch {
            errorMessage = "请求失败：\(error.localizedDescription)"
            writeState(extra: ["error": errorMessage ?? ""])
        }
    }

    // MARK: 充值记录（本地累计）

    private func trackRecharge(currentToppedUp: Double) {
        let record = Self.loadRechargeRecord()
        guard var r = record else {
            let baseline = RechargeRecord(total: 0, initial: 0, last_balance: currentToppedUp, history: [])
            Self.saveRechargeRecord(baseline)
            totalRecharge = Self.fmt2(baseline.total)
            return
        }
        if let last = r.last_balance {
            let delta = currentToppedUp - last
            if delta > 0.001 {
                r.total += delta
                r.history.append(RechargeHistoryEntry(
                    time: Self.dateTimeFormatter.string(from: Date()),
                    amount: delta,
                    balance_after: currentToppedUp,
                    note: "检测到余额增加"
                ))
            }
        }
        r.last_balance = currentToppedUp
        Self.saveRechargeRecord(r)
        totalRecharge = Self.fmt2(r.total)
    }

    static func loadRechargeRecord() -> RechargeRecord? {
        guard let data = try? Data(contentsOf: AppPaths.rechargeFile),
              let r = try? JSONDecoder().decode(RechargeRecord.self, from: data) else { return nil }
        return r
    }

    static func saveRechargeRecord(_ r: RechargeRecord) {
        AppPaths.ensureDir()
        if let data = try? JSONEncoder().encode(r) {
            try? data.write(to: AppPaths.rechargeFile, options: [.atomic])
        }
    }

    static func fmt2(_ d: Double) -> String {
        String(format: "%.2f", d)
    }

    // MARK: 配置（API Key / 初始充值）

    func saveAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        AppPaths.ensureDir()
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            cfg = json
        }
        cfg["deepseek_api_key"] = k
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? data.write(to: AppPaths.configFile, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
        }
        apiKeyConfigured = true
        Task { await refresh() }
    }

    func setInitialRecharge(_ amount: Double) {
        guard amount >= 0 else { return }
        var r = Self.loadRechargeRecord() ?? RechargeRecord(total: 0, initial: 0, last_balance: nil, history: [])
        r.total = amount
        r.initial = amount
        if r.history.isEmpty {
            r.history.append(RechargeHistoryEntry(
                time: Self.dateTimeFormatter.string(from: Date()),
                amount: amount,
                balance_after: Double(toppedUp) ?? 0,
                note: "初始充值（手动记录）"
            ))
        }
        Self.saveRechargeRecord(r)
        totalRecharge = Self.fmt2(amount)
    }

    // MARK: 官网记录接入

    func savePlatformToken(_ t: String) {
        PlatformAPI.saveToken(t)
        platformConnected = !t.isEmpty
        Task { await refresh() }
    }

    // MARK: 低余额提醒

    private func checkLowBalance() {
        guard currency == "CNY", let bal = Double(totalBalance) else { return }
        if bal < lowBalanceThreshold {
            isLowBalance = true
            if !lowBalanceNotified {
                lowBalanceNotified = true
                sendLowBalanceNotification(balance: bal)
            }
        } else {
            isLowBalance = false
            lowBalanceNotified = false
        }
    }

    private func sendLowBalanceNotification(balance: Double) {
        let content = UNMutableNotificationContent()
        content.title = "DeepSeek 余额不足"
        content.body = String(format: "当前余额 ¥%.2f，已低于 ¥%.0f，请及时充值。", balance, lowBalanceThreshold)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "deepseek-low-balance",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: 消耗 token 统计（mtime 缓存）

    static func countConsumedTokens() -> Int {
        let fm = FileManager.default
        let sessionsRoot = AppPaths.sessionsRoot
        guard let en = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return autoreleasepool { () -> Int in
            var total = 0
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let path = url.path
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? Date.distantPast
                if let cached = tokenCache[path], cached.mtime == mtime {
                    total += cached.tokens
                    continue
                }
                let tokens = tokensInFile(url)
                tokenCache[path] = TokenCacheEntry(mtime: mtime, tokens: tokens)
                total += tokens
            }
            tokenCache = tokenCache.filter { fm.fileExists(atPath: $0.key) }
            return total
        }
    }

    private static let tokenKeyData = Data("total_token_usage".utf8)

    private static func tokensInFile(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        var last: Int? = nil
        var leftover = Data()

        func process(_ line: Data) {
            guard !line.isEmpty,
                  line.range(of: tokenKeyData) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let info = payload["info"] as? [String: Any],
                  let ttu = info["total_token_usage"] as? [String: Any],
                  let tt = ttu["total_tokens"] as? Int else { return }
            last = tt
        }

        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0A) {
                let line = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                process(line)
            }
        }
        if !leftover.isEmpty { process(leftover) }
        return last ?? 0
    }

    static func formatCount(_ n: Int) -> String {
        countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Key 读取

    static func loadDeepSeekKey() -> String? {
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let k = json["deepseek_api_key"] as? String, !k.isEmpty {
            return k
        }
        if let k = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !k.isEmpty { return k }
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codexbar/config.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]] else { return nil }
        for p in providers where (p["id"] as? String) == "deepseek" {
            if let ta = p["tokenAccounts"] as? [String: Any],
               let accounts = ta["accounts"] as? [[String: Any]],
               let idx = ta["activeIndex"] as? Int,
               accounts.indices.contains(idx),
               let token = accounts[idx]["token"] as? String,
               !token.isEmpty {
                return token
            }
        }
        return nil
    }

    // MARK: 状态落盘（直接用当前模型值；出错时自然保留上一次正常值）

    func writeState(extra: [String: Any] = [:]) {
        AppPaths.ensureDir()
        var payload: [String: Any] = extra
        payload["balance"] = totalBalance
        payload["currency"] = currency
        payload["topped_up"] = toppedUp
        payload["granted"] = granted
        payload["total_recharge"] = totalRecharge
        payload["consumed_tokens"] = consumedTokens
        payload["is_available"] = available ?? false
        payload["is_low_balance"] = isLowBalance
        payload["is_active"] = isActive
        payload["platform_connected"] = platformConnected
        payload["updated_at"] = lastUpdated
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: AppPaths.stateFile, options: [.atomic])
        }
    }
}

// MARK: - Tokens 消耗图表窗口

enum ChartRange: String, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays, threeMonths, sixMonths, oneYear, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "今日"
        case .sevenDays: return "7天"
        case .thirtyDays: return "30天"
        case .threeMonths: return "3月"
        case .sixMonths: return "6月"
        case .oneYear: return "1年"
        case .all: return "全部"
        }
    }
}

enum BucketGranularity {
    case hour, day, week, month
}

struct BucketStat: Identifiable {
    let start: Date
    let total: Int
    var id: Date { start }
}

struct SpendPoint: Identifiable {
    let start: Date
    let spend: Double
    var id: Date { start }
}

struct ProjectBucketStat: Identifiable {
    let id = UUID()
    let name: String
    let tokens: Int
}

struct SpendRecord: Identifiable {
    let id = UUID()
    let time: Date
    let amount: Double
}

struct TokenChartView: View {
    @State private var sessions: [SessionInfo] = []
    @State private var rechargeEvents: [RechargeEvent] = []
    @State private var balanceHistory: [BalanceReading] = []
    @State private var range: ChartRange = .thirtyDays
    @State private var loading = false
    @State private var showCNY = false
    @State private var hoveredDate: Date?
    @State private var hoverX: CGFloat?
    @State private var platformCosts: [String: Double] = [:] // 官网每日消耗（元）
    @State private var platformTokens: [String: Int] = [:]   // 官网每日 tokens

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH时"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy年MM月"; return f
    }()
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()
    private static let dayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar.current
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else if sessions.isEmpty {
                Text("暂无会话数据").foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 300)
            } else {
                summaryRow
                chart
                Divider()
                if showCNY {
                    Text(platformCosts.isEmpty ? ("余额变动估算记录" + historyStartText) : "DeepSeek 官网消耗记录（按日，与官网一致）")
                        .font(.caption).foregroundColor(.secondary)
                }
                sessionList
            }
        }
        .padding(14)
        .frame(width: 700, height: 680)
        .task {
            load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                silentRefresh()
            }
        }
    }

    private func silentRefresh() {
        let start = rangeStart
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TokenStatsParser.collectSessions()
            let recharges = RechargeStore.loadEvents()
            let history = BalanceStore.load()
            let platform = PlatformStore.load()
            DispatchQueue.main.async {
                self.sessions = stats
                self.rechargeEvents = recharges
                self.balanceHistory = history
                self.platformCosts = platform.mapValues { $0.cost }
                self.platformTokens = platform.mapValues { $0.tokens }
            }
            Task {
                await PlatformStore.refreshMonths(from: start, to: Date(), minInterval: 60, force: false)
                let p = PlatformStore.load()
                await MainActor.run {
                    self.platformCosts = p.mapValues { $0.cost }
                    self.platformTokens = p.mapValues { $0.tokens }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Tokens 消耗统计").font(.headline)
            Spacer()
            Menu {
                ForEach(ChartRange.allCases) { r in
                    Button(r.label) { range = r }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(range.label)
                    Image(systemName: "chevron.down")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.gray.opacity(0.12)))
            }
            Picker("", selection: $showCNY) {
                Text("Tokens").tag(false)
                Text("人民币").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            Button {
                load()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: 范围与聚合

    private var rangeStart: Date {
        let cal = Calendar.current
        switch range {
        case .today:
            // 最近 24 小时滚动窗口（跨零点也能正确显示）
            return cal.date(byAdding: .hour, value: -23, to: Date()) ?? .distantPast
        case .sevenDays:
            return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date())) ?? .distantPast
        case .thirtyDays:
            return cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: Date())) ?? .distantPast
        case .threeMonths:
            return cal.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
        case .sixMonths:
            return cal.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        case .oneYear:
            return cal.date(byAdding: .month, value: -12, to: Date()) ?? .distantPast
        case .all:
            return sessions.map(\.start).min() ?? .distantPast
        }
    }

    private var granularity: BucketGranularity {
        switch range {
        case .today: return .hour
        case .sevenDays, .thirtyDays: return .day
        case .threeMonths: return .week
        case .sixMonths, .oneYear, .all: return .month
        }
    }

    private var inRangeSessions: [SessionInfo] {
        let start = rangeStart
        return sessions.filter { $0.start >= start }
    }

    private func bucketStart(_ date: Date) -> Date {
        let cal = Calendar.current
        switch granularity {
        case .hour: return cal.dateInterval(of: .hour, for: date)?.start ?? date
        case .day: return cal.startOfDay(for: date)
        case .week: return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
        case .month: return cal.dateInterval(of: .month, for: date)?.start ?? cal.startOfDay(for: date)
        }
    }

    private var buckets: [BucketStat] {
        let cal = Calendar.current
        var map: [Date: Int] = [:]
        for s in inRangeSessions {
            map[bucketStart(s.start), default: 0] += s.total
        }
        var result: [BucketStat] = []
        let today = cal.startOfDay(for: Date())
        switch granularity {
        case .hour:
            var cursor = bucketStart(rangeStart)
            for _ in 0..<24 {
                result.append(BucketStat(start: cursor, total: map[cursor] ?? 0))
                cursor = cal.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600)
            }
        case .day, .week, .month:
            var cursor = bucketStart(rangeStart)
            while cursor <= today {
                result.append(BucketStat(start: cursor, total: map[cursor] ?? 0))
                let step: Calendar.Component = granularity == .week ? .weekOfYear : (granularity == .month ? .month : .day)
                cursor = cal.date(byAdding: step, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
            }
        }
        return result
    }

    /// 稀疏数据时自动缩放到有数据的区间（留少量边距），避免柱图卡在边缘
    private var effectiveChartDomain: ClosedRange<Date>? {
        let all = buckets
        guard let first = all.first, let last = all.last else { return nil }
        let dataStarts: [Date]
        if showCNY {
            dataStarts = spendBuckets.map { $0.start }
        } else {
            dataStarts = all.filter { $0.total > 0 }.map { $0.start }
        }
        guard let dFirst = dataStarts.min(), let dLast = dataStarts.max() else { return nil }
        let total = last.start.timeIntervalSince(first.start)
        let span = dLast.timeIntervalSince(dFirst)
        let pad: TimeInterval
        switch granularity {
        case .hour: pad = 3 * 3600
        case .day: pad = 2 * 86400
        case .week: pad = 7 * 86400
        case .month: pad = 30 * 86400
        }
        let isSparse = span <= 0 || total <= 0 || span / total < 0.6
        guard isSparse else { return nil }
        let start = max(first.start, dFirst.addingTimeInterval(-pad))
        let end = min(last.start, dLast.addingTimeInterval(pad))
        return start...end
    }

    /// 图表 X 轴范围：稀疏时缩放，否则完整区间（含半桶边距，避免首尾柱被裁）
    private var chartDomain: ClosedRange<Date> {
        if let d = effectiveChartDomain { return d }
        let all = buckets
        guard let first = all.first, let last = all.last else {
            let now = Date()
            return now...now
        }
        let step = all.count > 1 ? last.start.timeIntervalSince(first.start) / Double(all.count - 1) : 86400
        return first.start.addingTimeInterval(-step / 2)...last.start.addingTimeInterval(step / 2)
    }

    private var spendBuckets: [SpendPoint] {
        if !platformCosts.isEmpty { return platformSpendBuckets }
        return balanceDropBuckets
    }

    private var platformSpendBuckets: [SpendPoint] {
        var map: [Date: Double] = [:]
        for (dateStr, cost) in platformCosts where cost > 0.0005 {
            guard let d = Self.dayDateFormatter.date(from: dateStr) else { continue }
            map[bucketStart(d), default: 0] += cost
        }
        if granularity == .hour {
            // 官网按日，窗口跨零点时取窗口内全部日期的总和
            let windowOfficial = platformCosts.values.reduce(0) { $0 + $1 }
            let drops = todayBalanceDrops()
            let sumDrops = drops.reduce(0) { $0 + $1.1 }
            if windowOfficial > 0.0005 {
                if sumDrops > 0.0005 {
                    var hourly: [Date: Double] = [:]
                    for (t, amt) in drops {
                        hourly[bucketStart(t), default: 0] += windowOfficial * amt / sumDrops
                    }
                    return buckets.compactMap { b in
                        guard let v = hourly[b.start], v > 0.0005 else { return nil }
                        return SpendPoint(start: b.start, spend: v)
                    }
                }
                let nowBucket = bucketStart(Date())
                return buckets.compactMap { b in
                    guard b.start == nowBucket else { return nil }
                    return SpendPoint(start: b.start, spend: windowOfficial)
                }
            }
            return balanceDropBuckets
        }
        return buckets.compactMap { b in
            guard let v = map[b.start], v > 0.0005 else { return nil }
            return SpendPoint(start: b.start, spend: v)
        }
    }

    private var balanceDropBuckets: [SpendPoint] {
        let readings = balanceHistory.sorted { $0.t < $1.t }
        guard readings.count >= 2 else { return [] }
        let iso = ISO8601DateFormatter()
        var map: [Date: Double] = [:]
        for i in 1..<readings.count {
            let prev = readings[i - 1], cur = readings[i]
            guard let curD = iso.date(from: cur.t) else { continue }
            let drop = prev.b - cur.b
            guard drop > 0.0005 else { continue }
            let bucket = bucketStart(curD)
            map[bucket, default: 0] += drop
        }
        return buckets.compactMap { b in
            guard let v = map[b.start], v > 0.0005 else { return nil }
            return SpendPoint(start: b.start, spend: v)
        }
    }

    private func todayBalanceDrops() -> [(Date, Double)] {
        let readings = balanceHistory.sorted { $0.t < $1.t }
        let iso = ISO8601DateFormatter()
        let cutoff = rangeStart
        var drops: [(Date, Double)] = []
        for i in 1..<readings.count {
            let prev = readings[i - 1], cur = readings[i]
            guard let curD = iso.date(from: cur.t), curD >= cutoff else { continue }
            let drop = prev.b - cur.b
            if drop > 0.0005 { drops.append((curD, drop)) }
        }
        return drops
    }

    private var platformSpendInRange: Double {
        spendBuckets.reduce(0) { $0 + $1.spend }
    }

    private var allSpendBuckets: [SpendPoint] {
        var map: [Date: Double] = [:]
        for sp in spendBuckets { map[sp.start] = sp.spend }
        return buckets.map { SpendPoint(start: $0.start, spend: map[$0.start] ?? 0) }
    }

    private var spendRecords: [SpendRecord] {
        if !platformCosts.isEmpty {
            let start = rangeStart
            let end = Date().addingTimeInterval(86400)
            var records: [SpendRecord] = []
            for (dateStr, cost) in platformCosts where cost > 0.0005 {
                guard let d = Self.dayDateFormatter.date(from: dateStr),
                      d >= start, d <= end else { continue }
                records.append(SpendRecord(time: d, amount: cost))
            }
            return records.sorted { $0.time > $1.time }
        }
        let readings = balanceHistory.sorted { $0.t < $1.t }
        let iso = ISO8601DateFormatter()
        var records: [SpendRecord] = []
        for i in 1..<readings.count {
            let prev = readings[i - 1], cur = readings[i]
            guard let curD = iso.date(from: cur.t) else { continue }
            let drop = prev.b - cur.b
            guard drop > 0.0005 else { continue }
            records.append(SpendRecord(time: curD, amount: drop))
        }
        return records.reversed()
    }

    private var historyStartText: String {
        guard let first = balanceHistory.sorted(by: { $0.t < $1.t }).first,
              let d = ISO8601DateFormatter().date(from: first.t) else { return "" }
        return "，自 " + Self.dateTimeFormatter.string(from: d) + " 起"
    }

    private var inRangeRecharges: [RechargeEvent] {
        let start = rangeStart
        let end = Date().addingTimeInterval(60)
        return rechargeEvents.filter { $0.time >= start && $0.time <= end }
    }

    // MARK: 单位与格式（股票常用：万/亿）

    static func compactNumber(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return "\(Int(n))"
    }

    // MARK: 汇总

    private var summaryRow: some View {
        if showCNY {
            let peak = spendBuckets.max { $0.spend < $1.spend }
            return HStack(spacing: 18) {
                statItem("总消耗(元)", String(format: "¥%.2f", platformSpendInRange))
                statItem("记录点数", "\(spendBuckets.count)")
                statItem("平均", String(format: "¥%.2f", spendBuckets.isEmpty ? 0 : platformSpendInRange / Double(spendBuckets.count)))
                statItem("峰值", peak.map { "\(bucketLabel($0.start)) ¥\(String(format: "%.2f", $0.spend))" } ?? "—")
            }
        } else {
            let total = inRangeSessions.reduce(0) { $0 + $1.total }
            let peak = buckets.max { $0.total < $1.total }
            return HStack(spacing: 18) {
                statItem("总消耗", BalanceModel.formatCount(total))
                statItem("会话数", "\(inRangeSessions.count)")
                statItem("平均", BalanceModel.formatCount(buckets.isEmpty ? 0 : total / buckets.count))
                statItem("峰值", peak.map { "\(bucketLabel($0.start)) \(BalanceModel.formatCount($0.total))" } ?? "—")
            }
        }
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.callout).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func bucketLabel(_ d: Date) -> String {
        switch granularity {
        case .hour: return Self.hourFormatter.string(from: d)
        case .day, .week: return Self.dayFormatter.string(from: d)
        case .month: return Self.monthFormatter.string(from: d)
        }
    }

    // MARK: 图表

    private var xAxisStride: Calendar.Component {
        switch granularity {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var xAxisCount: Int {
        switch range {
        case .today: return 3
        case .sevenDays: return 1
        case .thirtyDays: return 5
        case .threeMonths: return 2
        case .sixMonths: return 2
        case .oneYear: return 2
        case .all: return 4
        }
    }

    @ViewBuilder
    private var chart: some View {
        if showCNY {
            cnyChart
        } else {
            tokenChart
        }
    }

    private var tokenChart: some View {
        Chart {
            ForEach(buckets) { b in
                BarMark(
                    x: .value("时间", b.start),
                    y: .value("Tokens", b.total)
                )
                .foregroundStyle(isHovered(b.start) ? Color.orange : Color.blue.opacity(0.85))
                .cornerRadius(isHovered(b.start) ? 4 : 2)
            }
            ForEach(inRangeRecharges) { r in
                rechargeRule(r)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: xAxisStride, count: xAxisCount)) { _ in
                AxisGridLine()
                if granularity == .month {
                    AxisValueLabel(format: .dateTime.month())
                } else if granularity == .hour {
                    AxisValueLabel(format: .dateTime.hour())
                } else {
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(Self.compactNumber(d)).font(.caption2)
                    }
                }
            }
        }
        .chartXScale(domain: chartDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let date: Date = proxy.value(atX: location.x, as: Date.self) {
                                let b = nearestBucket(to: date)
                                hoveredDate = b?.start
                                hoverX = b.flatMap { barCenterX(for: $0.start, proxy: proxy) }
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                if let hb = nearestBucket(), let x = hoverX, showTooltip(for: hb) {
                    tooltipView(hb, spend: hoverSpend())
                        .position(x: tooltipX(for: x, inWidth: geo.size.width), y: 18)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 210)
        .overlay(alignment: .topTrailing) {
            legend("消耗", .blue)
        }
    }

    private var cnyChart: some View {
        Group {
            if spendBuckets.isEmpty {
                Text(platformCosts.isEmpty ? "该时段暂无平台消耗记录\n（余额历史自记录之日起积累）" : "该时段暂无官网消耗记录")
                    .font(.callout).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 210)
            } else {
                Chart {
                    ForEach(allSpendBuckets) { sp in
                        BarMark(
                            x: .value("时间", sp.start),
                            y: .value("消耗(元)", sp.spend)
                        )
                        .foregroundStyle(isHovered(sp.start) ? Color.orange : Color.blue.opacity(0.85))
                        .cornerRadius(isHovered(sp.start) ? 4 : 2)
                    }
                    ForEach(inRangeRecharges) { r in
                        rechargeRule(r)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: xAxisStride, count: xAxisCount)) { _ in
                        AxisGridLine()
                        if granularity == .month {
                            AxisValueLabel(format: .dateTime.month())
                        } else if granularity == .hour {
                            AxisValueLabel(format: .dateTime.hour())
                        } else {
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text(String(format: "¥%.2f", d)).font(.caption2)
                            }
                        }
                    }
                }
                .chartXScale(domain: chartDomain)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if let date: Date = proxy.value(atX: location.x, as: Date.self) {
                                        let b = nearestBucket(to: date)
                                        hoveredDate = b?.start
                                        hoverX = b.flatMap { barCenterX(for: $0.start, proxy: proxy) }
                                    }
                                case .ended:
                                    hoveredDate = nil
                                }
                            }
                        if let hb = nearestBucket(), let x = hoverX, showTooltip(for: hb) {
                            tooltipView(hb, spend: hoverSpend())
                                .position(x: tooltipX(for: x, inWidth: geo.size.width), y: 18)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 210)
            }
        }
        .overlay(alignment: .topTrailing) {
            legend("消耗(元)", .blue)
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            legendItem(label, color)
            legendItem("充值", .red)
        }
        .font(.caption2)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.1)))
        .padding(4)
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 8, height: 8).cornerRadius(2)
            Text(label).foregroundColor(.secondary)
        }
    }

    @ChartContentBuilder
    private func rechargeRule(_ r: RechargeEvent) -> some ChartContent {
        RuleMark(x: .value("充值", r.time))
            .foregroundStyle(Color.red)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .annotation(position: .top) {
                Text("¥\(BalanceModel.fmt2(r.amount))")
                    .font(.caption2).bold()
                    .foregroundColor(.red)
                    .padding(.horizontal, 3)
            }
    }

    // MARK: 悬停详情（修正定位：吸附柱体中心 + 与悬停同坐标系）

    private func nearestBucket(to date: Date) -> BucketStat? {
        buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    private func nearestBucket() -> BucketStat? {
        guard let d = hoveredDate else { return nil }
        return nearestBucket(to: d)
    }

    private func isHovered(_ start: Date) -> Bool {
        nearestBucket()?.start == start
    }

    private func barCenterX(for start: Date, proxy: ChartProxy) -> CGFloat? {
        guard let idx = buckets.firstIndex(where: { $0.start == start }) else { return nil }
        guard let startX = proxy.position(forX: start) else { return nil }
        if idx + 1 < buckets.count {
            let nextStart = buckets[idx + 1].start
            if let nextX = proxy.position(forX: nextStart) {
                return (startX + nextX) / 2
            }
        }
        if buckets.count > 1,
           let x0 = proxy.position(forX: buckets[0].start),
           let x1 = proxy.position(forX: buckets[1].start) {
            let width = x1 - x0
            return startX + width / 2
        }
        return startX
    }

    private func hoverSpend() -> Double? {
        guard let hb = nearestBucket() else { return nil }
        if let sp = spendBuckets.first(where: { $0.start == hb.start }) { return sp.spend }
        return showCNY ? 0 : nil
    }

    private static let tooltipHalfWidth: CGFloat = 110

    /// 提示框 X 定位：能居中就居中；边缘放不下就翻到柱子一侧，保证对准柱子且不超出窗口
    private func tooltipX(for barCenter: CGFloat, inWidth width: CGFloat) -> CGFloat {
        let half = Self.tooltipHalfWidth
        let margin: CGFloat = 8
        guard width > half * 2 + margin * 2 else { return width / 2 }
        if barCenter - half >= margin && barCenter + half <= width - margin {
            return barCenter
        }
        if barCenter + half > width - margin {
            // 右侧放不下：移到柱子左侧
            return max(half + margin, barCenter - half - margin)
        }
        // 左侧放不下：移到柱子右侧
        return min(width - half - margin, barCenter + half + margin)
    }

    /// 只有悬停在有数据的柱体上才显示提示框（人民币模式空桶不弹，避免对不准）
    private func showTooltip(for b: BucketStat) -> Bool {
        if showCNY {
            return spendBuckets.contains { $0.start == b.start }
        }
        return true
    }

    private func tooltipView(_ b: BucketStat, spend: Double?) -> some View {
        let projects = perProjectBreakdown(for: b.start)
        return VStack(alignment: .leading, spacing: 4) {
            Text(bucketLabel(b.start)).font(.caption).bold()
            HStack {
                Text("总消耗").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(BalanceModel.formatCount(b.total)).font(.caption).monospacedDigit()
            }
            if let s = spend, showCNY {
                HStack {
                    Text(platformCosts.isEmpty ? "余额变动" : "官网记录").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "¥%.2f", s)).font(.caption).monospacedDigit()
                }
            }
            Divider()
            Text(showCNY ? "各项目消耗(元)" : "各项目消耗").font(.caption2).foregroundColor(.secondary)
            ForEach(projects) { p in
                HStack(spacing: 4) {
                    Text(p.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if showCNY, let s = spend, b.total > 0 {
                        Text(String(format: "¥%.2f", s * Double(p.tokens) / Double(b.total)))
                            .font(.caption).monospacedDigit()
                    } else {
                        Text(BalanceModel.formatCount(p.tokens)).font(.caption).monospacedDigit()
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .shadow(radius: 4)
    }

    private func perProjectBreakdown(for bucketDate: Date) -> [ProjectBucketStat] {
        var groups: [String: (tokens: Int, title: String, latest: Date)] = [:]
        for s in inRangeSessions where bucketStart(s.start) == bucketDate {
            let key = s.cwd ?? "未知项目"
            let display = s.title.isEmpty ? (key as NSString).lastPathComponent : s.title
            var g = groups[key] ?? (0, display, s.start)
            g.tokens += s.total
            if s.start > g.latest {
                g.latest = s.start
                g.title = display
            }
            groups[key] = g
        }
        return groups
            .map { ProjectBucketStat(name: $0.value.title, tokens: $0.value.tokens) }
            .sorted { $0.tokens > $1.tokens }
    }

    // MARK: 会话列表

    @ViewBuilder
    private var sessionList: some View {
        if showCNY {
            spendRecordList
        } else {
            sessionTokenList
        }
    }

    private var sessionTokenList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(inRangeSessions) { s in
                    HStack(spacing: 8) {
                        Text(s.title).lineLimit(1).font(.callout)
                        Spacer()
                        Text(Self.dateTimeFormatter.string(from: s.start))
                            .font(.caption).foregroundColor(.secondary)
                        Text(BalanceModel.formatCount(s.total))
                            .font(.callout).monospacedDigit()
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var spendRecordList: some View {
        Group {
            if spendRecords.isEmpty {
                Text(platformCosts.isEmpty ? "暂无平台消耗记录（余额历史自记录之日起积累）" : "暂无官网消耗记录")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(spendRecords.prefix(30)) { r in
                            HStack {
                                Text(Self.dateTimeFormatter.string(from: r.time))
                                    .font(.callout).foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "-¥%.2f", r.amount))
                                    .font(.callout).monospacedDigit().foregroundColor(.red)
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
                        if spendRecords.count > 30 {
                            Text("仅显示最近 30 条，共 \(spendRecords.count) 条")
                                .font(.caption2).foregroundColor(.secondary).padding(.top, 4)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func load() {
        loading = true
        let start = rangeStart
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TokenStatsParser.collectSessions()
            let recharges = RechargeStore.loadEvents()
            let history = BalanceStore.load()
            let platform = PlatformStore.load()
            DispatchQueue.main.async {
                sessions = stats
                rechargeEvents = recharges
                balanceHistory = history
                platformCosts = platform.mapValues { $0.cost }
                platformTokens = platform.mapValues { $0.tokens }
                hoveredDate = nil
                hoverX = nil
                loading = false
            }
            Task {
                await PlatformStore.refreshMonths(from: start, to: Date(), minInterval: 60, force: true)
                let p = PlatformStore.load()
                await MainActor.run {
                    platformCosts = p.mapValues { $0.cost }
                    platformTokens = p.mapValues { $0.tokens }
                }
            }
        }
    }
}

// MARK: - 项目详情窗口

struct ProjectDetailView: View {
    @State private var projects: [ProjectStat] = []
    @State private var loading = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目详情").font(.headline)
                Spacer()
                Button {
                    load()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }

            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else if projects.isEmpty {
                Text("暂无项目数据").foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 300)
            } else {
                summaryRow
                Divider()
                projectList
            }
        }
        .padding(16)
        .frame(width: 660, height: 600)
        .onAppear { load() }
    }

    private var summaryRow: some View {
        let totalTokens = projects.reduce(0) { $0 + $1.totalTokens }
        let totalDuration = projects.reduce(0) { $0 + $1.totalDuration }
        let sessionCount = projects.reduce(0) { $0 + $1.sessionCount }
        return HStack(spacing: 20) {
            statItem("项目数", "\(projects.count)")
            statItem("会话数", "\(sessionCount)")
            statItem("总 Tokens", BalanceModel.formatCount(totalTokens))
            statItem("总耗时", Self.durationText(totalDuration))
        }
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.callout).fontWeight(.semibold).monospacedDigit()
        }
    }

    private var sortedProjects: [ProjectStat] {
        projects.sorted { $0.totalTokens > $1.totalTokens }
    }

    private var maxTokens: Int { sortedProjects.first?.totalTokens ?? 1 }

    private func barShare(_ p: ProjectStat) -> Double {
        maxTokens > 0 ? Double(p.totalTokens) / Double(maxTokens) : 0
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(sortedProjects) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(p.title).font(.headline).lineLimit(1)
                            Spacer()
                            Text(BalanceModel.formatCount(p.totalTokens))
                                .font(.headline).monospacedDigit()
                            Text("tokens").font(.caption).foregroundColor(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.gray.opacity(0.12))
                                Capsule().fill(Color.blue.opacity(0.85))
                                    .frame(width: max(6, geo.size.width * barShare(p)))
                            }
                        }
                        .frame(height: 7)
                        Text(p.path)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 16) {
                            infoItem("开始时间", Self.dateFormatter.string(from: p.firstStart))
                            infoItem("最后活动", Self.dateFormatter.string(from: p.lastActive))
                            infoItem("会话数", "\(p.sessionCount)")
                            infoItem("运行耗时", Self.durationText(p.totalDuration))
                            infoItem("创建至今", Self.durationText(p.age))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }

    static func durationText(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h)小时\(m)分" }
        if m > 0 { return "\(m)分\(sec)秒" }
        return "\(sec)秒"
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TokenStatsParser.collectProjects()
            DispatchQueue.main.async {
                projects = stats
                loading = false
            }
        }
    }
}

// MARK: - SwiftUI 弹窗内容

struct ContentView: View {
    @ObservedObject var model: BalanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let full = AppAssets.whaleGirl {
                HStack {
                    Spacer()
                    Image(nsImage: full)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 110)
                    Spacer()
                }
            }
            HStack {
                Text("DeepSeek 余额").font(.headline)
                Spacer()
                if model.isLowBalance {
                    Text("⚠️ 低于 ¥\(Int(model.lowBalanceThreshold))").font(.callout).foregroundColor(.red)
                } else if model.available == true {
                    Text("● 可用").font(.callout).foregroundColor(.green)
                } else if model.available == false {
                    Text("● 不可用").font(.callout).foregroundColor(.red)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(model.currencySymbol).font(.title2).foregroundColor(.secondary)
                Text(model.totalBalance).font(.system(size: 36, weight: .bold, design: .rounded))
                Spacer()
            }
            Divider()
            if !model.apiKeyConfigured {
                Text("⚠️ 未配置 API Key，余额无法刷新")
                    .font(.caption).foregroundColor(.orange)
            }
            apiKeyRow
            row("总充值金额", model.totalRecharge)
            row("消耗 tokens", model.consumedTokens)
            platformRow
            row("货币", model.currency)
            row("更新时间", model.lastUpdated)
            if let err = model.errorMessage {
                Text(err).font(.caption).foregroundColor(.red).lineLimit(3)
            }
            Divider()
            HStack {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                Spacer()
                Button {
                    if let url = URL(string: "https://platform.deepseek.com/top_up") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("充值", systemImage: "yensign.circle")
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
    }

    private var platformRow: some View {
        HStack {
            Text("官网记录").foregroundColor(.secondary)
            Spacer()
            if model.platformConnected {
                Text("已接入 ✓").fontWeight(.medium).foregroundColor(.green)
            } else {
                Button("接入…") {
                    PlatformSetup.promptAndSave(model: model)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
        .font(.callout)
    }

    private var apiKeyRow: some View {
        HStack {
            Text("API Key").foregroundColor(.secondary)
            Spacer()
            if model.apiKeyConfigured {
                Text("已设置 ✓").fontWeight(.medium).foregroundColor(.green)
            } else {
                Button("设置…") {
                    APIKeySetup.promptAndSave(model: model)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
        .font(.callout)
    }
}

// MARK: - App 入口（AppKit NSStatusItem）

@main
@MainActor
final class DeepSeekBalanceApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var chartWindow: NSWindow?
    private var projectWindow: NSWindow?
    private let model = BalanceModel()

    static func main() {
        let app = NSApplication.shared
        let delegate = DeepSeekBalanceApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 无 Dock 图标
        setupStatusItem()
        model.onTitleChanged = { [weak self] in
            self?.statusItem?.button?.title = self?.model.menuTitle ?? ""
        }
        model.start()
    }

    deinit {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = model.menuTitle
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
            return
        }
        showPopover()
    }

    private func showPopover() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }

        let p = NSPopover()
        p.behavior = .applicationDefined // 不自动关闭，由点击菜单栏按钮/点击外部控制

        let width: CGFloat = 280
        var height: CGFloat = 430
        if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            height = min(height, max(300, screen.visibleFrame.height - 30))
        }
        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.sizingOptions = .preferredContentSize
        hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        p.contentSize = NSSize(width: width, height: height)
        p.contentViewController = hosting
        popover = p
        if let button = statusItem.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        if let p = popover, p.isShown {
            p.performClose(nil)
        }
        popover = nil
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(withTitle: "刷新余额", action: #selector(refreshNow), keyEquivalent: "r")

        let current = model.refreshInterval
        let intervalMenu = NSMenu()
        let i1 = intervalMenu.addItem(withTitle: "每 1 分钟", action: #selector(setInterval1m), keyEquivalent: "")
        i1.state = current == 60 ? .on : .off
        let i5 = intervalMenu.addItem(withTitle: "每 5 分钟", action: #selector(setInterval5m), keyEquivalent: "")
        i5.state = current == 300 ? .on : .off
        let i15 = intervalMenu.addItem(withTitle: "每 15 分钟", action: #selector(setInterval15m), keyEquivalent: "")
        i15.state = current == 900 ? .on : .off
        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Tokens 消耗图表…", action: #selector(openTokenChart), keyEquivalent: "t")
        menu.addItem(withTitle: "项目详情…", action: #selector(openProjectDetail), keyEquivalent: "p")
        menu.addItem(withTitle: "接入官网记录…", action: #selector(setupPlatformToken), keyEquivalent: "")
        menu.addItem(withTitle: "设置 API Key…", action: #selector(setupAPIKey), keyEquivalent: "")
        menu.addItem(withTitle: "设置初始充值金额…", action: #selector(setInitialRecharge), keyEquivalent: "")
        let launchItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchItem), keyEquivalent: "")
        launchItem.state = LaunchItem.isEnabled ? .on : .off
        menu.addItem(launchItem)
        let whaleItem = NSMenuItem(title: "菜单栏显示 🐋", action: #selector(toggleWhale), keyEquivalent: "")
        whaleItem.state = model.menuShowWhale ? .on : .off
        menu.addItem(whaleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func openTokenChart() {
        let hosting = NSHostingController(rootView: TokenChartView())
        if let w = chartWindow {
            w.contentViewController = hosting
            w.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tokens 消耗统计"
            window.setContentSize(NSSize(width: 700, height: 680))
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            chartWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openProjectDetail() {
        let hosting = NSHostingController(rootView: ProjectDetailView())
        if let w = projectWindow {
            w.contentViewController = hosting
            w.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "项目详情"
            window.setContentSize(NSSize(width: 660, height: 600))
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            projectWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func setInterval1m() { model.setRefreshInterval(60) }
    @objc private func setInterval5m() { model.setRefreshInterval(300) }
    @objc private func setInterval15m() { model.setRefreshInterval(900) }

    @objc private func refreshNow() {
        Task { @MainActor in await model.refresh() }
    }

    @objc private func setupPlatformToken() {
        PlatformSetup.promptAndSave(model: model)
    }

    @objc private func setupAPIKey() {
        APIKeySetup.promptAndSave(model: model)
    }

    @objc private func setInitialRecharge() {
        if let s = TextPrompt.prompt(
            title: "设置初始充值金额",
            informative: "输入你已充值的总金额（元）。仅本机记录，用于累计充值统计。",
            placeholder: "例如 20",
            okTitle: "保存") {
            let cleaned = s
                .replacingOccurrences(of: "¥", with: "")
                .replacingOccurrences(of: "￥", with: "")
            if let amount = Double(cleaned), amount >= 0 {
                model.setInitialRecharge(amount)
            }
        }
    }

    @objc private func toggleWhale() {
        model.setMenuShowWhale(!model.menuShowWhale)
    }

    @objc private func toggleLaunchItem() {
        do {
            try LaunchItem.setEnabled(!LaunchItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机自启设置失败"
            alert.informativeText = error.localizedDescription + "\n请确认应用已安装到 /Applications 并重新打开后再试。"
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
