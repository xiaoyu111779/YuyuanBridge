import Foundation
import EventKit
import UserNotifications
import UIKit

// 这是"跑腿"核心：收到 yuyuanji:// 链接后解析，去调 Apple 的接口。
// 支持三种进来的形式：
//   1) yuyuanji://notify?title=..&body=..&time=..       （手测方便）
//   2) yuyuanji://reminder?title=..&notes=..&time=..     （手测方便）
//   3) yuyuanji://action?b64=<base64 的 JSON>            （芋圆机网页实际用这个）
//      JSON: {"type":"reminder|notify","title":"..","message":"..","time":"ISO或yyyy-MM-dd HH:mm","character":".."}
final class ActionHandler {
    static let shared = ActionHandler()
    private let store = EKEventStore()

    // MARK: 入口
    func handle(url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let host = comps.host ?? ""          // notify / reminder / action
        var q: [String: String] = [:]
        comps.queryItems?.forEach { if let v = $0.value { q[$0.name] = v } }

        // 形式 3：base64 JSON → 拆成字段
        if host == "action", let b64 = q["b64"], let payload = Self.decodeB64JSON(b64) {
            dispatch(type: payload["type"] ?? "notify",
                     title: payload["title"] ?? "",
                     body: payload["message"] ?? payload["notes"] ?? "",
                     timeStr: payload["time"],
                     character: payload["character"],
                     extraAct: payload["act"] ?? "start",
                     extraKind: payload["kind"] ?? "listen",
                     extraProgress: Double(payload["progress"] ?? "") ?? 0)
            return
        }
        // 也允许 action?json=<百分号编码的JSON>
        if host == "action", let js = q["json"], let payload = Self.decodeJSON(js) {
            dispatch(type: payload["type"] ?? "notify",
                     title: payload["title"] ?? "",
                     body: payload["message"] ?? payload["notes"] ?? "",
                     timeStr: payload["time"],
                     character: payload["character"])
            return
        }
        // 形式 1/2：直接用 query 参数
        dispatch(type: host.isEmpty ? "notify" : host,
                 title: q["title"] ?? "",
                 body: q["body"] ?? q["notes"] ?? "",
                 timeStr: q["time"],
                 character: q["character"])
    }

    private func dispatch(type: String, title: String, body: String, timeStr: String?, character: String?, extraAct: String = "start", extraKind: String = "listen", extraProgress: Double = 0) {
        let when = timeStr.flatMap(Self.parseDate)
        let bodyText = [character.map { "\($0)：" } ?? "", body].joined()
        switch type {
        case "wake":
            // 只是被芋圆机唤起来开实时联动,什么都不做
            LiveLink.shared.start()
            AppStore.shared.append("被芋圆机唤起,实时联动已开")
        case "shortcut":
            // 转交给用户自己的快捷指令:title=快捷指令名字,body=传入内容(写备忘录/订闹钟/发消息…都由快捷指令自己定义)
            runShortcut(name: title, input: bodyText.isEmpty ? body : bodyText)
        case "activity":
            // 灵动岛:act=start|update|end,kind=listen|read,title/body/progress 由芋圆机同步
            AppStore.shared.append("收到灵动岛动作:\(extraAct) \(extraKind) 「\(title)」 前台=\(UIApplication.shared.applicationState == .active)")
            ActivityBridge.shared.handle(act: extraAct, kind: extraKind, title: title, subtitle: body, progress: extraProgress, charName: character ?? "")
        case "calendar":
            // 日历日程(EventKit,静默):title=事项,time=开始;默认 1 小时
            guard let when = when else { AppStore.shared.append("写日历:没给时间"); return }
            writeCalendar(title: title.isEmpty ? body : title, notes: bodyText, start: when)
        case "alarm":
            // 真闹钟(iOS 26+ AlarmKit);不支持/失败→回落 提醒事项+到点通知
            guard let when = when else { AppStore.shared.append("定闹钟:没给时间"); return }
            let t = title.isEmpty ? "闹钟" : title
            AlarmBridge.schedule(title: t, at: when) { [weak self] ok, msg in
                AppStore.shared.append(msg)
                if !ok, let self = self {
                    self.writeReminder(title: t, notes: bodyText, due: when)
                    self.scheduleNotification(title: "⏰ " + t, body: bodyText.isEmpty ? t : bodyText, at: when)
                }
            }
        case "reminder":
            writeReminder(title: title.isEmpty ? body : title, notes: bodyText, due: when)
            // 顺带排一条到点通知，这样"提醒"也会主动弹（提醒事项本身到点也会提醒）
            if let when = when { scheduleNotification(title: title.isEmpty ? "提醒" : title, body: bodyText.isEmpty ? title : bodyText, at: when) }
        default: // notify
            if let when = when {
                scheduleNotification(title: title.isEmpty ? (character ?? "芋圆机") : title, body: body.isEmpty ? title : body, at: when)
            } else {
                fireNow(title: title.isEmpty ? (character ?? "芋圆机") : title, body: body.isEmpty ? title : body)
            }
        }
    }

    // MARK: 日历(EventKit)
    private func writeCalendar(title: String, notes: String, start: Date) {
        let req: (@escaping (Bool) -> Void) -> Void = { done in
            if #available(iOS 17.0, *) { self.store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } } }
            else { self.store.requestAccess(to: .event) { ok, _ in DispatchQueue.main.async { done(ok) } } }
        }
        req { [weak self] ok in
            guard let self = self else { return }
            guard ok else { AppStore.shared.append("写日历失败:没有权限"); return }
            let ev = EKEvent(eventStore: self.store)
            ev.title = title.isEmpty ? "(无标题)" : title
            ev.notes = notes
            ev.startDate = start
            ev.endDate = start.addingTimeInterval(3600)
            ev.calendar = self.store.defaultCalendarForNewEvents
            ev.addAlarm(EKAlarm(relativeOffset: -15 * 60))
            do { try self.store.save(ev, span: .thisEvent, commit: true); AppStore.shared.append("已写入日历:\(ev.title ?? "")") }
            catch { AppStore.shared.append("写日历出错:\(error.localizedDescription)") }
        }
    }

    // MARK: 快捷指令转交
    private func runShortcut(name: String, input: String) {
        guard !name.isEmpty else { AppStore.shared.append("快捷指令:没给名字"); return }
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? name
        let i = input.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? input
        guard let u = URL(string: "shortcuts://run-shortcut?name=\(n)&input=text&text=\(i)") else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(u, options: [:]) { ok in
                AppStore.shared.append(ok ? "已转交快捷指令「\(name)」" : "打不开快捷指令「\(name)」(名字对吗?)")
            }
        }
    }

    // MARK: 提醒事项（EventKit）
    func requestReminderAccess(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            store.requestFullAccessToReminders { ok, _ in DispatchQueue.main.async { done(ok) } }
        } else {
            store.requestAccess(to: .reminder) { ok, _ in DispatchQueue.main.async { done(ok) } }
        }
    }

    private func writeReminder(title: String, notes: String, due: Date?) {
        requestReminderAccess { [weak self] ok in
            guard let self = self else { return }
            guard ok else { AppStore.shared.append("写提醒失败：没有权限"); return }
            let r = EKReminder(eventStore: self.store)
            r.title = title.isEmpty ? "（无标题）" : title
            r.notes = notes
            r.calendar = self.store.defaultCalendarForNewReminders()
            if let due = due {
                r.dueDateComponents = Calendar.current.dateComponents(
                    [.year,.month,.day,.hour,.minute], from: due)
                r.addAlarm(EKAlarm(absoluteDate: due))
            }
            do {
                try self.store.save(r, commit: true)
                AppStore.shared.append("已写入提醒：\(r.title ?? "")")
            } catch {
                AppStore.shared.append("写提醒出错：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 通知（UserNotifications）
    func requestNotifyAccess(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound,.badge]) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    private func fireNow(title: String, body: String) {
        scheduleNotification(title: title, body: body, at: Date().addingTimeInterval(1))
    }

    private func scheduleNotification(title: String, body: String, at date: Date) {
        requestNotifyAccess { ok in
            guard ok else { AppStore.shared.append("弹通知失败：没有权限"); return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            let interval = max(1, date.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: trigger)
            UNUserNotificationCenter.current().add(req) { err in
                if let err = err { AppStore.shared.append("通知出错：\(err.localizedDescription)") }
                else { AppStore.shared.append("已排通知：\(title)（\(Int(interval))秒后）") }
            }
        }
    }

    // MARK: 工具
    private static func decodeB64JSON(_ b64: String) -> [String: String]? {
        // 兼容 base64url
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return jsonToStringMap(data)
    }
    private static func decodeJSON(_ s: String) -> [String: String]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return jsonToStringMap(data)
    }
    private static func jsonToStringMap(_ data: Data) -> [String: String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = "\(v)" }
        return out
    }
    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm"] {
            let f = DateFormatter(); f.dateFormat = fmt; f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
