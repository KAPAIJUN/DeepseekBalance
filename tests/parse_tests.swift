// deepseek用量监控组件 — 解析逻辑单测（无 GUI 依赖，可直接运行）
// 运行：swift tests/parse_tests.swift
// 说明：以下解析函数与 DeepSeekBalance.swift 中的逻辑保持一致，
//       用独立实现验证关键行为，避免引入 AppKit/SwiftUI 依赖。

import Foundation

// MARK: - 极简断言框架
var passed = 0
var failed = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name)")
    }
}
func checkEq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    check(a == b, "\(name)（\(a) == \(b)）")
}

// MARK: - 1. rollout 文件名解析（对应 sessionMetaFromFilename）
func parseRolloutFilename(_ name: String) -> (id: String, date: Date)? {
    let parts = name.split(separator: "-")
    guard parts.count >= 11 else { return nil }
    let dateStr = "\(parts[1])-\(parts[2])-\(parts[3]):\(parts[4]):\(parts[5])"
    var id = parts[6..<11].joined(separator: "-")
    if id.hasSuffix(".jsonl") { id.removeLast(6) }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .current
    guard let date = f.date(from: dateStr) else { return nil }
    return (id, date)
}

let goodName = "rollout-2026-08-18T17-28-50-01a01433-bf4a-7151-9ac4-044ecff7a9d9.jsonl"
let parsed = parseRolloutFilename(goodName)
check(parsed != nil, "合法文件名可解析")
if let p = parsed {
    checkEq(p.id, "01a01433-bf4a-7151-9ac4-044ecff7a9d9", "session id 提取")
    let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.date)
    checkEq(comps.year, 2026, "日期年份")
    checkEq(comps.month, 8, "日期月份")
    checkEq(comps.day, 18, "日期日")
    checkEq(comps.hour, 17, "日期小时")
    checkEq(comps.minute, 28, "日期分钟")
}
check(parseRolloutFilename("foo") == nil, "非法文件名返回 nil")
check(parseRolloutFilename("rollout-2026-08-18T17-28") == nil, "字段不足返回 nil")

// MARK: - 2. Gregorian 日历下年份正确（非公历系统防御）
do {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = TimeZone(secondsFromGMT: 0)
    guard let d = f.date(from: "2569-08-18") else { fatalError("日期解析失败") }
    let year = Calendar(identifier: .gregorian).dateComponents([.year], from: d).year
    checkEq(year, 2569, "Gregorian 年份（2569 不被佛历偏移）")
}

// MARK: - 3. 设置初始充值后不重复累计（对应 setInitialRecharge + trackRecharge）
struct RechargeRecord {
    var total: Double
    var initial: Double
    var last_balance: Double?
    var history: [String]
}
func setInitial(_ amount: Double, into r: inout RechargeRecord, toppedUp: Double) {
    r.total = amount
    r.initial = amount
    r.last_balance = toppedUp // 重新基线化，避免后续重复累计
}
func trackRecharge(_ current: Double, into r: inout RechargeRecord) {
    if let last = r.last_balance {
        let delta = current - last
        if delta > 0.001 { r.total += delta }
    }
    r.last_balance = current
}

var rec = RechargeRecord(total: 0, initial: 0, last_balance: nil, history: [])
setInitial(100, into: &rec, toppedUp: 88.0)
trackRecharge(88.0, into: &rec)   // 余额不变 → 不累计
checkEq(rec.total, 100, "初始充值 100 后余额不变，total 保持 100")
trackRecharge(95.0, into: &rec)   // 真实充值 +7
checkEq(rec.total, 107, "真实充值 +7 后 total=107")
trackRecharge(95.0, into: &rec)   // 余额不变 → 不重复累计
checkEq(rec.total, 107, "再次相同余额不重复累计")

// MARK: - 4. 上海时区文件名时间 == 文件内 meta UTC 时刻
do {
    let sh = TimeZone(identifier: "Asia/Shanghai")!
    let lf = DateFormatter()
    lf.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    lf.locale = Locale(identifier: "en_US_POSIX")
    lf.calendar = Calendar(identifier: .gregorian)
    lf.timeZone = sh
    // 与应用一致：先带小数秒解析，失败再回退无小数秒
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let nofrac = ISO8601DateFormatter()
    nofrac.formatOptions = [.withInternetDateTime]

    guard let local = lf.date(from: "2026-08-18T17:28:50"),
          let utc = frac.date(from: "2026-08-18T09:28:50Z") ?? nofrac.date(from: "2026-08-18T09:28:50Z") else {
        fatalError("时间解析失败")
    }
    check(abs(local.timeIntervalSince(utc)) < 1, "上海 17:28:50 == UTC 09:28:50")
}

// MARK: - 汇总
print("----")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
