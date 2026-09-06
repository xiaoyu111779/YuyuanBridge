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
    private var retryQueue: [(name: String, detail: String, at: Date)] = []
    private var retryWork: DispatchWorkItem? = nil
    private func scheduleRetry() { retryWork?.cancel(); let w = DispatchWorkItem { [weak self] in guard let self = self, let snap = Brain.shared.snapshot(forName: "") else { return }; let evs = self.retryQueue; self.retryQueue = []; guard !evs.isEmpty else { return }; self.pending.append(contentsOf: evs); self.flush(cfg: self.cfg(for: snap)) }; retryWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w) }
    private let ekStore = EKEventStore()

    // MARK: 配置(从芋圆机快照来)
    struct Cfg { var enabled = false, battery = true, sleep = true, steps = true, calendar = true, inactive = true, external = true; var quietStart = "23:30", quietEnd = "08:00"; var dailyCap = 6; var inactiveHours = 5.0; var followUps = 2 }
    func cfg(for snap: Brain.Snapshot?) -> Cfg {
        var c = Cfg(); guard let s = snap?.sense else { return c }
        c.enabled = (s["enabled"] as? Bool) ?? false; c.battery = (s["battery"] as? Bool) ?? true; c.sleep = (s["sleep"] as? Bool) ?? true; c.steps = (s["steps"] as? Bool) ?? true
        c.calendar = (s["calendar"] as? Bool) ?? true; c.inactive = (s["inactive"] as? Bool) ?? true; c.external = (s["external"] as? Bool) ?? true
        c.quietStart = (s["quietStart"] as? String) ?? "23:30"; c.quietEnd = (s["quietEnd"] as? String) ?? "08:00"
        c.dailyCap = Int((s["dailyCap"] as? Double) ?? Double((s["dailyCap"] as? Int) ?? 6)); c.inactiveHours = (s["inactiveHours"] as? Double) ?? Double((s["inactiveHours"] as? Int) ?? 5)
        let fuRaw: Any? = s["followUp"] ?? s["followUps"]
        c.followUps = max(1, min(3, Int((fuRaw as? Double) ?? Double((fuRaw as? Int) ?? 2))))
        return c
    }

    func start() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in guard let self = self, !self.retryQueue.isEmpty, let snap = Brain.shared.snapshot(forName: "") else { return }; let evs = self.retryQueue; self.retryQueue = []; self.pending.append(contentsOf: evs); self.flush(cfg: self.cfg(for: snap)) }
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

    // MARK: 活跃度 & 睡眠推断(没手表也能用)
    //  信号:解锁上报 phone_active / 芋圆机在线轮询 / 睡眠专注 sleep_focus_on|off / 就寝 bedtime
    //  规则:专注开或就寝到 → "准备睡"(bedtime_ready);之后连续 ≥2.5h 无任何活跃 → 判"睡了"(静默);再次活跃 → "醒了"(估睡了多久)
    private var lastActiveAt: Date { get { (ud.object(forKey: key("lastActive")) as? Date) ?? .distantPast } set { ud.set(newValue, forKey: key("lastActive")) } }
    private var asleepSince: Date? { get { ud.object(forKey: key("asleepSince")) as? Date } set { ud.set(newValue, forKey: key("asleepSince")) } }
    private var prepSleepAt: Date? { get { ud.object(forKey: key("prepSleep")) as? Date } set { ud.set(newValue, forKey: key("prepSleep")) } }
    func noteActive(source: String) {
        let wasAsleep = asleepSince
        lastActiveAt = Date()
        if let since = wasAsleep {
            asleepSince = nil; prepSleepAt = nil
            let mins = Int(Date().timeIntervalSince(since) / 60)
            if mins >= 60, let snap = Brain.shared.snapshot(forName: ""), cfg(for: snap).enabled, cfg(for: snap).sleep, HealthBridge.shared.sleepMin < 0 { // 有健康 App 的睡眠就不重复
                enqueue(name: "woke_up", detail: "估计睡了 \(mins / 60) 小时 \(mins % 60) 分(按手机没动推断)", cfg: cfg(for: snap))
            }
        }
        // 用户一活跃,所有追问计数清零(回了就不追)
        for k in ["nightowl", "inactive", "bat15", "bat5"] { ud.set(0, forKey: key("fu." + k)) } // 注意:saidsleep 不在此清零——"说了去睡还在动"恰恰以活跃为条件
    }
    private func sleepInference(_ c: Cfg) -> [(String, String, Double)] {
        var out: [(String, String, Double)] = []
        guard c.sleep else { return out }
        let idle = Date().timeIntervalSince(lastActiveAt)
        let h = Calendar.current.component(.hour, from: Date())
        if asleepSince == nil, (prepSleepAt != nil || (h >= 0 && h < 6)), idle >= 2.5 * 3600, lastActiveAt != .distantPast {
            asleepSince = lastActiveAt // 从最后一次活跃算起
            AppStore.shared.append("感知:推断 ta 睡了(手机 \(Int(idle / 60)) 分钟没动)")
        }
        // 夜猫子:凌晨 1~5 点还在活跃(最近 10 分钟内有活跃)且没被判睡 → night_owl(可追问,见 followUp)
        if h >= 0 && h < 5, idle < 600, asleepSince == nil, followUpOK("nightowl", within: 3 * 3600, cfg: c) { out.append(("night_owl", "凌晨 \(h) 点还在用手机", 3)) }
        // 说了去睡却还在动:user 最近一条说"去睡/晚安"(之后没再发消息),20 分钟后手机仍在活跃 → said_sleep_but_awake(可追问)
        if let snap = Brain.shared.snapshot(forName: ""), snap.saidSleepAt > 0 {
            let since = Date().timeIntervalSince1970 - snap.saidSleepAt / 1000
            if since >= 20 * 60, since <= 4 * 3600, idle < 600, asleepSince == nil, followUpOK("saidsleep", within: 4 * 3600, cfg: c) { out.append(("said_sleep_but_awake", "说了去睡,\(Int(since / 60)) 分钟了还在用手机", 4)) }
        }
        return out
    }
    // 追问:同一类事在冷却期内最多说 followUps 次,每次间隔 ≥30 分钟;用户一活跃就清零
    private func followUpOK(_ k: String, within: Double, cfg: Cfg) -> Bool {
        let n = ud.integer(forKey: key("fu." + k))
        let last = firedAt(k) ?? .distantPast
        let sinceLast = Date().timeIntervalSince(last)
        if n == 0 { markFired(k); ud.set(1, forKey: key("fu." + k)); return true }
        if n < cfg.followUps, sinceLast >= 1800, sinceLast <= within { markFired(k); ud.set(n + 1, forKey: key("fu." + k)); return true }
        if sinceLast > within { ud.set(0, forKey: key("fu." + k)) }
        return false
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
            if pct >= 0 && !charging && pct <= 5 && followUpOK("bat5", within: 6 * 3600, cfg: c) { evs.append(("battery_low", "\(pct)%", 6)) }
            else if pct >= 0 && !charging && pct <= 15 && followUpOK("bat15", within: 6 * 3600, cfg: c) { evs.append(("battery_low", "\(pct)%", 6)) }
            if charging, dev.batteryState == .charging, cooled("charging", hours: 3) { evs.append(("battery_charging", "\(pct)%", 3)); markFired("charging") }
            if dev.batteryState == .full, cooled("full", hours: 6) { evs.append(("battery_full", "100%", 6)); markFired("full") }
            if !charging { ud.removeObject(forKey: key("at.charging")) } // 拔了就允许下次插上再说
            if pct > 30 { ud.removeObject(forKey: key("at.bat15")); ud.removeObject(forKey: key("at.bat5")); ud.set(0, forKey: key("fu.bat15")); ud.set(0, forKey: key("fu.bat5")) } // 充回去后下次低电再说
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
        // 睡眠推断(无手表)
        if LiveLink.shared.recentlyPolled(within: 90) { noteActive(source: "yuyuanji") }
        if asleepSince == nil { evs.append(contentsOf: sleepInference(c)) }
        // 好久没理
        if c.inactive, snap.lastUserAt > 0 {
            let gapH = (Date().timeIntervalSince1970 * 1000 - snap.lastUserAt) / 3600000
            if gapH >= c.inactiveHours && followUpOK("inactive", within: max(6, c.inactiveHours) * 3600, cfg: c) { evs.append(("no_reply_hours", String(format: "%.1f", gapH), 6)) }
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
        AppStore.shared.append("快捷指令上报:\(name) \(detail)")
        // 活跃/睡眠信号(不当成要开口的事件)
        if name == "phone_active" { noteActive(source: "unlock"); return }
        if name == "app_opened" {
            AppStore.shared.append("感知:收到打开 App 上报「\(detail.isEmpty ? "?" : detail)」")
            noteActive(source: "app:" + detail)
            ud.set(detail, forKey: key("lastApp")); ud.set(Date(), forKey: key("lastAppAt"))
            // 说了去睡又打开某 App → 立刻提醒(比 said_sleep_but_awake 更具体)
            if let snap = Brain.shared.snapshot(forName: ""), snap.saidSleepAt > 0 {
                let since = Date().timeIntervalSince1970 - snap.saidSleepAt / 1000
                if since >= 3 * 60, since <= 4 * 3600, cfg(for: snap).enabled, cfg(for: snap).sleep, followUpOK("saidsleepapp", within: 4 * 3600, cfg: cfg(for: snap)) {
                    enqueue(name: "said_sleep_but_using_app", detail: "说了睡,又打开了\(detail.isEmpty ? "手机" : detail)", cfg: cfg(for: snap))
                    return
                }
            }
            // v30:普通"打开了某 App"本身就是事件(之前漏了,只在说了睡的情况下才有)——同一 App 30 分钟内只报一次
            let k = "app." + detail
            if let snap = Brain.shared.snapshot(forName: ""), cfg(for: snap).enabled, cfg(for: snap).external {
                if cooled(k, hours: 0.5) { markFired(k); enqueue(name: "app_opened", detail: detail.isEmpty ? "某个 App" : detail, cfg: cfg(for: snap)) }
                else { AppStore.shared.append("感知:「\(detail)」30 分钟内已报过,这次不重复") }
            } else { AppStore.shared.append("感知:主动感知或「快捷指令报告的事」没开,忽略") }
            return
        }
        if name == "sleep_focus_off" { prepSleepAt = nil; noteActive(source: "focus_off"); return }
        if name == "sleep_focus_on" || name == "bedtime" { prepSleepAt = Date(); if let snap = Brain.shared.snapshot(forName: ""), cfg(for: snap).enabled, cfg(for: snap).sleep, cooled("bedtime", hours: 8) { markFired("bedtime"); enqueue(name: "bedtime_ready", detail: name == "bedtime" ? "到就寝时间了" : "开了睡眠专注", cfg: cfg(for: snap)) }; return }
        guard let snap = Brain.shared.snapshot(forName: "") else { AppStore.shared.append("感知:收到「\(name)」但还没同步角色快照"); return }
        let c = cfg(for: snap); guard c.enabled && c.external else { AppStore.shared.append("感知:收到「\(name)」但主动感知/快捷指令事件未开"); return }
        enqueue(name: name, detail: detail, cfg: c)
    }

    // MARK: 合并 + 投递
    // 这些事件要立刻反应,不等合并
    private let instantEvents: Set<String> = ["app_opened", "said_sleep_but_using_app", "said_sleep_but_awake", "late_night_still_awake", "arrived_home", "left_home", "alarm_snoozed", "workout_start", "workout_end", "app_lock_hit"]
    private func enqueue(name: String, detail: String, cfg: Cfg) {
        AppStore.shared.append("感知事件:\(name) \(detail)")
        pending.append((name, detail, Date()))
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush(cfg: cfg) }
        flushWork = w
        let delay: TimeInterval = instantEvents.contains(name) ? 3 : 90   // 即时事件 3s(留一点点合并),其余 90s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    private func flush(cfg: Cfg) {
        let evs = pending; pending = []
        guard !evs.isEmpty else { return }
        if asleepSince != nil, !evs.contains(where: { $0.name == "woke_up" }) { AppStore.shared.append("感知:ta 在睡觉,事件先记着"); Brain.shared.rememberEvents(evs.map { ($0.name, $0.detail, $0.at) }); return }
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
        Brain.shared.generate(charName: nil, trigger: "【刚发生的事·来自 ta 真实手机的感知】\n\(lines)\n这不是 ta 在找你,是你察觉到了这些。按你的人设和你们当前的关系决定要不要开口:不值得说就输出 {\"texts\":[]} 保持沉默;想说就像平时发微信,一两句,别念数据") { ok, out in
            if ok, !out.isEmpty { self.bumpSent() }
            else if !ok { AppStore.shared.append("感知:这次没发成(多半没联网),事件留着待会儿重试"); self.retryQueue.append(contentsOf: evs); self.scheduleRetry() }
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
