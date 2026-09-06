import Foundation
import UIKit
import EventKit
import AppIntents

// 主动感知层:后台定时看电量/健康/日历/多久没聊,按规则(冷却/免打扰/每日上限/合并)产出事件;
// 芋圆机开着→事件进发件箱 kind:event(网页用完整上下文生成);关着→出餐台自己生成(有沉默权)。
// 快捷指令自动化通过「报告事件」Intent 把 打开App/到家/出门/闹钟贪睡/运动… 送进来。
final class Sense {
    static let shared = Sense()
    private var timer: Timer? = nil
    private let ud = UserDefaults.standard
    private var pending: [(name: String, detail: String, at: Date)] = []
    private var flushWork: DispatchWorkItem? = nil
    private let ekStore = EKEventStore()

    // MARK: 配置(从芋圆机快照来)
    struct Cfg { var enabled = false, battery = true, sleep = true, steps = true, calendar = true, inactive = true, external = true; var quietStart = "23:30", quietEnd = "08:00"; var dailyCap = 6; var inactiveHours = 5.0 }
    func cfg(for snap: Brain.Snapshot?) -> Cfg {
        var c = Cfg(); guard let s = snap?.sense else { return c }
        c.enabled = (s["enabled"] as? Bool) ?? false; c.battery = (s["battery"] as? Bool) ?? true; c.sleep = (s["sleep"] as? Bool) ?? true; c.steps = (s["steps"] as? Bool) ?? true
        c.calendar = (s["calendar"] as? Bool) ?? true; c.inactive = (s["inactive"] as? Bool) ?? true; c.external = (s["external"] as? Bool) ?? true
        c.quietStart = (s["quietStart"] as? String) ?? "23:30"; c.quietEnd = (s["quietEnd"] as? String) ?? "08:00"
        c.dailyCap = Int((s["dailyCap"] as? Double) ?? Double((s["dailyCap"] as? Int) ?? 6)); c.inactiveHours = (s["inactiveHours"] as? Double) ?? Double((s["inactiveHours"] as? Int) ?? 5)
        return c
    }

    func start() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        AppStore.shared.append("主动感知:已启动")
    }

    // MARK: 规则工具
    private func key(_ k: String) -> String { "sense." + k }
    private func firedAt(_ k: String) -> Date? { ud.object(forKey: key("at." + k)) as? Date }
    private func markFired(_ k: String) { ud.set(Date(), forKey: key("at." + k)) }
    private func cooled(_ k: String, hours: Double) -> Bool { guard let t = firedAt(k) else { return true }; return Date().timeIntervalSince(t) > hours * 3600 }
    private func todayKey() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }
    private func sentToday() -> Int { ud.string(forKey: key("day")) == todayKey() ? ud.integer(forKey: key("count")) : 0 }
    private func bumpSent() { if ud.string(forKey: key("day")) != todayKey() { ud.set(todayKey(), forKey: key("day")); ud.set(0, forKey: key("count")) }; ud.set(sentToday() + 1, forKey: key("count")) }
    private func inQuiet(_ c: Cfg) -> Bool {
        func mins(_ s: String) -> Int { let p = s.split(separator: ":"); return (Int(p.first ?? "0") ?? 0) * 60 + (p.count > 1 ? (Int(p[1]) ?? 0) : 0) }
        let now = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let a = mins(c.quietStart), b = mins(c.quietEnd)
        return a <= b ? (now >= a && now < b) : (now >= a || now < b)
    }

    // MARK: 检测
    func tick() {
        guard let snap = Brain.shared.snapshot(forName: "") else { return }
        let c = cfg(for: snap); guard c.enabled else { return }
        var evs: [(String, String, Double)] = [] // name, detail, cooldownHours
        // 电量
        if c.battery {
            let dev = UIDevice.current; let pct = dev.batteryLevel < 0 ? -1 : Int((dev.batteryLevel * 100).rounded())
            let charging = dev.batteryState == .charging || dev.batteryState == .full
            if pct >= 0 && !charging && pct <= 5 && cooled("bat5", hours: 6) { evs.append(("battery_low", "\(pct)%", 6)); markFired("bat5") }
            else if pct >= 0 && !charging && pct <= 15 && cooled("bat15", hours: 6) { evs.append(("battery_low", "\(pct)%", 6)); markFired("bat15") }
            if charging, dev.batteryState == .charging, cooled("charging", hours: 3) { evs.append(("battery_charging", "\(pct)%", 3)); markFired("charging") }
            if dev.batteryState == .full, cooled("full", hours: 6) { evs.append(("battery_full", "100%", 6)); markFired("full") }
            if !charging { ud.removeObject(forKey: key("at.charging")) } // 拔了就允许下次插上再说
            if pct > 30 { ud.removeObject(forKey: key("at.bat15")); ud.removeObject(forKey: key("at.bat5")) } // 充回去后下次低电再说
        }
        // 睡眠(醒了 / 睡太少)
        if c.sleep {
            HealthBridge.shared.refresh()
            let sm = HealthBridge.shared.sleepMin; let h = Calendar.current.component(.hour, from: Date())
            if sm >= 0 && h >= 5 && h <= 12 && ud.string(forKey: key("wakeDay")) != todayKey() {
                ud.set(todayKey(), forKey: key("wakeDay"))
                evs.append(("sleep_end", "昨晚睡了 \(sm / 60) 小时 \(sm % 60) 分", 24))
                if sm < 300 { evs.append(("sleep_short", "\(sm / 60)h\(sm % 60)m", 24)) }
            }
        }
        // 步数(晚 8 点后)
        if c.steps {
            let st = HealthBridge.shared.steps; let h = Calendar.current.component(.hour, from: Date())
            if st >= 0 && h >= 20 && ud.string(forKey: key("stepsDay")) != todayKey() {
                if st < 800 { ud.set(todayKey(), forKey: key("stepsDay")); evs.append(("steps_low", "\(st) 步", 24)) }
                else if st > 15000 { ud.set(todayKey(), forKey: key("stepsDay")); evs.append(("steps_high", "\(st) 步", 24)) }
            }
        }
        // 日历:明天有安排(20-22点提一次)/ 1 小时内开始 / 刚结束
        if c.calendar { evs.append(contentsOf: calendarEvents()) }
        // 好久没理
        if c.inactive, snap.lastUserAt > 0 {
            let gapH = (Date().timeIntervalSince1970 * 1000 - snap.lastUserAt) / 3600000
            if gapH >= c.inactiveHours && cooled("inactive", hours: max(6, c.inactiveHours)) { evs.append(("no_reply_hours", String(format: "%.1f", gapH), 6)); markFired("inactive") }
        }
        for e in evs { enqueue(name: e.0, detail: e.1, cfg: c) }
    }

    private func calendarEvents() -> [(String, String, Double)] {
        var out: [(String, String, Double)] = []
        let auth = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) { guard auth == .fullAccess else { return out } } else { guard auth == .authorized else { return out } }
        let now = Date(); let cal = Calendar.current
        let pred = ekStore.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
        for ev in ekStore.events(matching: pred) where !ev.isAllDay {
            let id = ev.eventIdentifier ?? "ev"
            let start = ev.startDate ?? now, end = ev.endDate ?? start
            let h = cal.component(.hour, from: now)
            if cal.isDateInTomorrow(start), h >= 20, h <= 22, cooled("cal.tmr." + id, hours: 48) { markFired("cal.tmr." + id); out.append(("calendar_tomorrow", "\(ev.title ?? "") @ \(f.string(from: start))", 48)) }
            let untilStart = start.timeIntervalSince(now)
            if untilStart > 0 && untilStart <= 3600, cooled("cal.soon." + id, hours: 48) { markFired("cal.soon." + id); out.append(("calendar_soon", "\(ev.title ?? "") @ \(f.string(from: start))", 48)) }
            let sinceEnd = now.timeIntervalSince(end)
            if sinceEnd >= 0 && sinceEnd <= 1800, cooled("cal.done." + id, hours: 48) { markFired("cal.done." + id); out.append(("calendar_done", ev.title ?? "", 48)) }
        }
        return out
    }

    // 快捷指令报告的事件
    func external(name: String, detail: String) {
        guard let snap = Brain.shared.snapshot(forName: "") else { AppStore.shared.append("感知:收到「\(name)」但还没同步角色快照"); return }
        let c = cfg(for: snap); guard c.enabled && c.external else { AppStore.shared.append("感知:收到「\(name)」但主动感知/快捷指令事件未开"); return }
        enqueue(name: name, detail: detail, cfg: c)
    }

    // MARK: 合并 + 投递
    private func enqueue(name: String, detail: String, cfg: Cfg) {
        AppStore.shared.append("感知事件:\(name) \(detail)")
        pending.append((name, detail, Date()))
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush(cfg: cfg) }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: w) // 90s 内的事件合成一次
    }
    private func flush(cfg: Cfg) {
        let evs = pending; pending = []
        guard !evs.isEmpty else { return }
        let webOnline = LiveLink.shared.recentlyPolled(within: 60)
        // 免打扰:sleep_end 例外;其余攒着当上下文(不主动说),但仍给网页当上下文
        let quiet = inQuiet(cfg) && !evs.contains(where: { $0.name == "sleep_end" })
        let capped = sentToday() >= cfg.dailyCap
        if webOnline {
            let sn = Brain.shared.snapshot(forName: "")
            for e in evs { Brain.shared.enqueueOutgoing(Brain.Outgoing(id: UUID().uuidString, cardKey: sn?.cardKey ?? "", charName: sn?.charName ?? "", text: e.detail, ts: e.at.timeIntervalSince1970, delivered: false, kind: "event", title: e.name)) }
            if !quiet && !capped { bumpSent() }
            AppStore.shared.append("感知:\(evs.count) 条事件已交给芋圆机(\(quiet ? "免打扰,仅作上下文" : capped ? "今日已达上限,仅作上下文" : "可主动开口"))")
            return
        }
        if quiet || capped { AppStore.shared.append("感知:\(quiet ? "免打扰时段" : "今日上限已到"),事件先记着不主动说"); Brain.shared.rememberEvents(evs.map { ($0.name, $0.detail, $0.at) }); return }
        Brain.shared.rememberEvents(evs.map { ($0.name, $0.detail, $0.at) })
        let lines = evs.map { "- \($0.name)\($0.detail.isEmpty ? "" : " = \($0.detail)")" }.joined(separator: "\n")
        Brain.shared.generate(charName: nil, trigger: "【刚发生的事·来自 ta 真实手机的感知】\n\(lines)\n这不是 ta 在找你,是你察觉到了这些。按你的人设和你们当前的关系决定要不要开口:不值得说就输出 {\"texts\":[]} 保持沉默;想说就像平时发微信,一两句,别念数据") { ok, lines in
            if ok, !lines.isEmpty { self.bumpSent() }
        }
    }
}

// 「报告事件」——给快捷指令自动化用:打开某App / 到家 / 出门 / 闹钟贪睡 / 运动开始结束 / 自定义
struct ReportEventIntent: AppIntent {
    static var title: LocalizedStringResource = "向角色报告一件事"
    static var description = IntentDescription("给快捷指令自动化用:比如「打开小红书时」「到家时」「闹钟贪睡时」运行本动作,角色就会知道。")
    static var openAppWhenRun: Bool = false
    @Parameter(title: "事件", default: "app_opened") var event: String
    @Parameter(title: "备注", default: "") var detail: String
    static var parameterSummary: some ParameterSummary { Summary("报告 \(\.$event) \(\.$detail)") }
    func perform() async throws -> some IntentResult {
        Sense.shared.external(name: event, detail: detail)
        return .result()
    }
}
