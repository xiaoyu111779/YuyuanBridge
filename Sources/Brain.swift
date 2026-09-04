import Foundation
import UserNotifications
import Security
import AppIntents

// "离线小脑":酒馆关着时也能让角色说话。
// 芋圆机开着时把【API 配置 + 角色人设 + 最近聊天】作为快照同步进来(POST /sync);
// Siri / 定时触发时,App 自己调 OpenAI 兼容接口生成 1~3 条短消息 → 弹系统通知 + 存进发件箱;
// 下次芋圆机打开从 /outbox 拉走、按时间补进微信聊天记录。
final class Brain {
    static let shared = Brain()

    struct Snapshot: Codable {
        var cardKey: String
        var charName: String
        var userName: String
        var sysPrompt: String        // 芋圆机正常私聊回复时的【完整系统提示】(有它就直接用,和在线回复口径一致)
        var persona: String          // 精简线上人设
        var lore: String             // 剧情设定:为什么 ta 能看到/操作 user 的手机
        var recent: [Msg]            // 最近对话(旧→新)
        var story: String            // 主线最新剧情(剧情摘要+最近楼层),酒馆关着时也接得上
        var storyTime: String        // 剧情时间(开了剧情时间才有)
        var apiUrl: String
        var apiModel: String
        var updatedAt: Double
        struct Msg: Codable { var role: String; var text: String; var time: Double? }
    }
    struct Outgoing: Codable { var id: String; var cardKey: String; var charName: String; var text: String; var ts: Double; var delivered: Bool }

    private let fm = FileManager.default
    private var dir: URL { let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("brain", isDirectory: true); try? fm.createDirectory(at: d, withIntermediateDirectories: true); return d }
    private var snapFile: URL { dir.appendingPathComponent("snapshots.json") }
    private var outFile: URL { dir.appendingPathComponent("outbox.json") }
    private let lock = NSLock()

    // MARK: 快照
    private(set) var snapshots: [String: Snapshot] = [:]   // cardKey → snapshot
    init() { load() }
    private func load() {
        if let d = try? Data(contentsOf: snapFile), let m = try? JSONDecoder().decode([String: Snapshot].self, from: d) { snapshots = m }
        if let d = try? Data(contentsOf: outFile), let o = try? JSONDecoder().decode([Outgoing].self, from: d) { outbox = o }
    }
    private func persist() {
        lock.lock(); defer { lock.unlock() }
        if let d = try? JSONEncoder().encode(snapshots) { try? d.write(to: snapFile, options: [.atomic, .completeFileProtection]) }
        if let d = try? JSONEncoder().encode(outbox) { try? d.write(to: outFile, options: [.atomic, .completeFileProtection]) }
    }
    // base64url(JSON) → 存快照;JSON 里的 apiKey 单独进 Keychain,不落文件
    func saveSnapshot(b64: String) -> Bool {
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let cardKey = obj["cardKey"] as? String, !cardKey.isEmpty, let charName = obj["charName"] as? String else { return false }
        let recent = ((obj["recent"] as? [[String: Any]]) ?? []).compactMap { m -> Snapshot.Msg? in
            guard let r = m["role"] as? String, let t = m["text"] as? String else { return nil }
            return Snapshot.Msg(role: r, text: t, time: m["time"] as? Double)
        }
        let snap = Snapshot(cardKey: cardKey, charName: charName, userName: (obj["userName"] as? String) ?? "我",
                            sysPrompt: (obj["sysPrompt"] as? String) ?? "", persona: (obj["persona"] as? String) ?? "", lore: (obj["lore"] as? String) ?? "", recent: Array(recent.suffix(30)),
                            story: (obj["story"] as? String) ?? "", storyTime: (obj["storyTime"] as? String) ?? "",
                            apiUrl: (obj["apiUrl"] as? String) ?? "", apiModel: (obj["apiModel"] as? String) ?? "",
                            updatedAt: Date().timeIntervalSince1970)
        if let key = obj["apiKey"] as? String, !key.isEmpty { Keychain.set(key, for: "apikey." + cardKey) }
        snapshots[cardKey] = snap
        UserDefaults.standard.set(cardKey, forKey: "brain.lastCard")
        persist()
        YuyuanShortcuts.updateAppShortcutParameters()   // 关键:角色名是动态参数,不刷新 Siri 不认识
        return true
    }
    var charNames: [(cardKey: String, name: String)] { snapshots.values.sorted { $0.updatedAt > $1.updatedAt }.map { ($0.cardKey, $0.charName) } }
    func snapshot(forName name: String) -> Snapshot? {
        if let s = snapshots.values.first(where: { $0.charName == name }) { return s }
        if let last = UserDefaults.standard.string(forKey: "brain.lastCard"), let s = snapshots[last] { return s }
        return snapshots.values.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    // MARK: 发件箱
    private(set) var outbox: [Outgoing] = []
    func outboxJSON() -> String {
        let pending = outbox.filter { !$0.delivered }
        let arr: [[String: Any]] = pending.map { ["id": $0.id, "cardKey": $0.cardKey, "charName": $0.charName, "text": $0.text, "ts": $0.ts] }
        let d = (try? JSONSerialization.data(withJSONObject: ["ok": true, "items": arr])) ?? Data("{\"ok\":true,\"items\":[]}".utf8)
        return String(data: d, encoding: .utf8) ?? "{\"ok\":true,\"items\":[]}"
    }
    func ack(ids: [String]) {
        let set = Set(ids)
        outbox = outbox.map { var o = $0; if set.contains(o.id) { o.delivered = true }; return o }
        outbox = outbox.filter { !$0.delivered || Date().timeIntervalSince1970 - $0.ts < 7 * 86400 }
        persist()
    }

    // MARK: 生成(Siri/定时 用)
    // trigger: 触发说明,如 "user 通过 Siri 让你给 ta 发条消息"
    func generate(charName: String?, trigger: String, done: @escaping (Bool, [String]) -> Void) {
        guard let snap = snapshot(forName: charName ?? "") else { done(false, ["还没同步过角色快照:先在芋圆机里开「手机联动」并聊一句"]); return }
        let key = Keychain.get("apikey." + snap.cardKey) ?? ""
        guard !snap.apiUrl.isEmpty, !key.isEmpty, !snap.apiModel.isEmpty else { done(false, ["快照里没有可用的 API 配置(芋圆机里先配好副 API)"]); return }
        // 自己最近发过的离线消息(发件箱,24h 内,同一张卡)也接进对话——不然下次 Siri 看不到上一条说了啥
        let mineRecent = outbox.filter { $0.cardKey == snap.cardKey && Date().timeIntervalSince1970 - $0.ts < 86400 }.suffix(10)
        var convo: [Snapshot.Msg] = snap.recent
        for o in mineRecent { convo.append(Snapshot.Msg(role: "npc", text: o.text, time: o.ts * 1000)) }
        var recentBlock = ""
        if !convo.isEmpty {
            let lines = convo.suffix(24).map { m -> String in
                let who = (m.role == "me" || m.role == "user") ? snap.userName : snap.charName
                return who + ":" + m.text
            }
            recentBlock = "【你们最近的微信聊天记录(旧→新,含你刚才在 ta 不在时发过的)】\n" + lines.joined(separator: "\n") + "\n"
        }
        let storyBlock = snap.story.isEmpty ? "" : "【主线最新剧情(你们俩的故事走到哪了,旧→新;以此为准,微信消息要接得上这里的进展)】\n\(snap.story)\n"
        let timeBlock = snap.storyTime.isEmpty ? "" : "【剧情时间】\(snap.storyTime)\n"
        let loreBlock = snap.lore.isEmpty ? "" : "【剧情设定】\(snap.lore)\n"
        let offlineRule = """
【离线补充·最高优先】\(snap.userName) 现在【不在酒馆里】,你是【主动新发】1~3 条很短的微信(每条 1~2 句),不是回复 ta;绝不重复聊天记录里说过的话;不写思路/方案/分析/旁白/元话术。
【输出】只输出一个 JSON 对象:{"texts":["第一条","第二条"]},texts 里每个元素是一条消息正文;不要别的字段、不要 markdown、不要解释。
"""
        let sys: String
        if !snap.sysPrompt.isEmpty {
            // 用芋圆机正常私聊回复的那套完整系统提示(口径一致),替换宏,再接离线补充
            let base = snap.sysPrompt
                .replacingOccurrences(of: "{{user}}", with: snap.userName)
                .replacingOccurrences(of: "{{char}}", with: snap.charName)
            sys = base + "\n\n" + loreBlock + timeBlock + recentBlock + offlineRule
        } else {
            sys = """
你现在是「\(snap.charName)」,正在用微信和「\(snap.userName)」聊天。以下是你的线上人设与说话方式:
\(snap.persona.isEmpty ? "(按最近对话的口吻来)" : snap.persona)

\(loreBlock)\(storyBlock)\(timeBlock)
\(recentBlock)
【世界内铁律】你说的每个字都是「\(snap.charName)」本人发的微信。绝对禁止任何旁白、剧本口吻或元话术。
\(offlineRule)
"""
        }
        var messages: [[String: String]] = [["role": "system", "content": sys]]
        messages.append(["role": "user", "content": "(\(trigger)。现在按【离线补充】的要求主动发消息,只输出 JSON。)"])
        let body: [String: Any] = ["model": snap.apiModel, "messages": messages, "temperature": 0.9, "max_tokens": 1500]
        var base = snap.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), let payload = try? JSONSerialization.data(withJSONObject: body) else { done(false, ["API 地址不合法"]); return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.httpBody = payload
        AppStore.shared.append("离线小脑:正在让 \(snap.charName) 说话…")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { AppStore.shared.append("离线小脑失败:\(err.localizedDescription)"); DispatchQueue.main.async { done(false, [err.localizedDescription]) }; return }
            guard let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { DispatchQueue.main.async { done(false, ["API 没返回 JSON"]) }; return }
            let content = (((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
            let lines = Self.parseLines(content)
            guard !lines.isEmpty else { AppStore.shared.append("离线小脑:模型没说出话来(原文:" + String(content.prefix(60)) + ")"); DispatchQueue.main.async { done(false, ["模型没返回内容"]) }; return }
            let now = Date().timeIntervalSince1970
            for (i, t) in lines.enumerated() {
                self.outbox.append(Outgoing(id: UUID().uuidString, cardKey: snap.cardKey, charName: snap.charName, text: t, ts: now + Double(i), delivered: false))
                self.notify(title: snap.charName, body: t, delay: Double(i) * 2 + 0.5)
            }
            self.persist()
            AppStore.shared.append("\(snap.charName) 发了 \(lines.count) 条:\(lines.first ?? "")")
            DispatchQueue.main.async { done(true, lines) }
        }.resume()
    }
    private static func parseLines(_ s: String) -> [String] {
        var t = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        // 首选:芋圆机同款 {"texts":[...]} JSON 对象
        if let o1 = t.firstIndex(of: "{"), let o2 = t.lastIndex(of: "}"), o1 < o2 {
            let js = String(t[o1...o2])
            if let d = js.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let arr = obj["texts"] as? [Any] {
                let out = arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 1 && $0.count <= 200 }
                if !out.isEmpty { return Array(out.prefix(3)) }
            }
        }
        // 万一还是给了 JSON 数组:抠出所有引号里的字符串
        if let r1 = t.firstIndex(of: "["), let r2 = t.lastIndex(of: "]"), r1 < r2 {
            let inner = String(t[t.index(after: r1)..<r2])
            let quoted = Self.regexAll(inner, pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
            if quoted.count >= 1 { t = quoted.joined(separator: "\n") }
        }
        // 优先:只认行首 >> 的行(思路/方案/分析没标记→天然丢弃)
        let marked = t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(">>") || $0.hasPrefix("》》") || $0.hasPrefix("＞＞") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \"“”「」")) }
            .filter { $0.count >= 2 && $0.count <= 120 }
        if !marked.isEmpty { return Array(marked.prefix(3)) }
        let junk = ["**", "constraints", "output", "format", "json", "assistant", "system", "user:", "```", "玩家", "用户", "模型", "系统", "ai ", "助手", "测试", "剧情", "正文", "结尾", "续写", "旁白", "回话", "角色扮演", "第三人称", "思路", "方案", "选项", "分析", "步骤", "策略", "备选", "候选", "版本", "总结", "综上", "如下", "以下", "首先", "其次", "最后", "消息一", "消息二", "消息三", "第一条", "第二条", "第三条"]
        var out: [String] = []
        for raw in t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var l = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            // 去编号/项目符号/引号/括号
            l = l.replacingOccurrences(of: "^([0-9]+[\\.、)]|[-*•]|\\[|\\])\\s*", with: "", options: .regularExpression)
            l = l.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’「」[]]、,，"))
            l = l.trimmingCharacters(in: .whitespacesAndNewlines)
            if l.isEmpty || l.count < 2 { continue }
            let low = l.lowercased()
            if junk.contains(where: { low.contains($0) }) { continue }
            if l.range(of: "^[\\p{Han}\\p{L}\\p{N}]", options: .regularExpression) == nil { continue }  // 不是以文字开头(纯符号)→丢
            if l.hasSuffix(":") || l.hasSuffix("：") { continue }   // 标题行(思路一:)→丢
            if l.count > 90 { continue }                               // 微信消息不会这么长,长的多半是分析
            out.append(l)
            if out.count >= 3 { break }
        }
        return out
    }
    private static func regexAll(_ s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil }
    }
    private func notify(title: String, body: String, delay: Double) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(0.5, delay), repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// 极简 Keychain(存 API Key,不落明文文件)
enum Keychain {
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "YuyuanBridge", kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "YuyuanBridge", kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
