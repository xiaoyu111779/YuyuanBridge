import Foundation
import UserNotifications
import Security

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
        var persona: String          // 精简线上人设
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
                            persona: (obj["persona"] as? String) ?? "", recent: Array(recent.suffix(30)),
                            story: (obj["story"] as? String) ?? "", storyTime: (obj["storyTime"] as? String) ?? "",
                            apiUrl: (obj["apiUrl"] as? String) ?? "", apiModel: (obj["apiModel"] as? String) ?? "",
                            updatedAt: Date().timeIntervalSince1970)
        if let key = obj["apiKey"] as? String, !key.isEmpty { Keychain.set(key, for: "apikey." + cardKey) }
        snapshots[cardKey] = snap
        UserDefaults.standard.set(cardKey, forKey: "brain.lastCard")
        persist()
        AppStore.shared.append("已同步快照:\(charName)(\(recent.count) 条对话)")
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
        let sys = """
你现在是「\(snap.charName)」,正在用微信和「\(snap.userName)」聊天。以下是你的线上人设与说话方式:
\(snap.persona.isEmpty ? "(按最近对话的口吻来)" : snap.persona)

\(snap.story.isEmpty ? "" : "【主线最新剧情(你们俩的故事走到哪了,旧→新;以此为准,微信消息要接得上这里的进展)】\n\(snap.story)\n")\(snap.storyTime.isEmpty ? "" : "【剧情时间】\(snap.storyTime)\n")
【场景】\(trigger)。\(snap.userName) 现在不在酒馆里,你要主动给 ta 发 1~3 条【很短】的微信消息(每条 1~2 句,像真人发微信,不要一大段,不要旁白,不要动作描写,不要引号包裹,不要出现你自己的名字前缀)。内容要贴合上面主线剧情的最新进展和你们的关系,不要凭空另起一段。
【输出格式】只输出一个 JSON 数组,每个元素是一条消息的文本,例如 ["起了吗","今天记得吃早饭"]。不要输出别的。
"""
        var messages: [[String: String]] = [["role": "system", "content": sys]]
        for m in snap.recent.suffix(20) {
            let role = (m.role == "me" || m.role == "user") ? "user" : "assistant"
            messages.append(["role": role, "content": m.text])
        }
        messages.append(["role": "user", "content": "(\(trigger)。请按格式输出。)"])
        let body: [String: Any] = ["model": snap.apiModel, "messages": messages, "temperature": 0.9, "max_tokens": 300]
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
            guard !lines.isEmpty else { AppStore.shared.append("离线小脑:模型没说出话来"); DispatchQueue.main.async { done(false, ["模型没返回内容"]) }; return }
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
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r1 = t.range(of: "["), let r2 = t.range(of: "]", options: .backwards), r1.lowerBound < r2.upperBound {
            let js = String(t[r1.lowerBound..<r2.upperBound])
            if let d = js.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] {
                let out = arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !out.isEmpty { return Array(out.prefix(3)) }
            }
        }
        t = t.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        return t.split(whereSeparator: { $0 == "\n" }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
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
