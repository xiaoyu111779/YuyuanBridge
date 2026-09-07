import Foundation
import SwiftUI
import UserNotifications
import FamilyControls
import ManagedSettings

// v29:真锁——屏幕使用时间接口(FamilyControls + ManagedSettings)。
//   流程:用户在本 App 里 ①授权「屏幕使用时间」 ②用系统选择器挑要锁的 App/类别/网站(选择结果只是不透明 token,本 App 也看不出是哪些);
//   之后芋圆机发 {type:"lock",minutes:N} → 本 App【在后台也能】给这些 App 盖上系统挡板,N 分钟后自动解;{type:"unlock"} 立刻解。
//   需要 Entitlements 里的 com.apple.developer.family-controls;签名工具/描述文件不带这个权限时,授权会报错(不会崩),把那一行删掉重编即可退回软锁。
//   自保:锁定截止时间存 UserDefaults,App 被杀后重启会补做解锁;界面上永远有「现在解锁」。选择器里别选本 App 自己。
final class LockBridge: ObservableObject {
    static let shared = LockBridge()
    private let store = ManagedSettingsStore()
    private let ud = UserDefaults.standard
    private var unlockWork: DispatchWorkItem? = nil

    @Published var selection = FamilyActivitySelection()
    @Published var authorized: Bool = false
    @Published var lockedUntil: Date? = nil

    private init() {
        if let raw = ud.data(forKey: "lock.selection"), let s = try? JSONDecoder().decode(FamilyActivitySelection.self, from: raw) { selection = s }
        if let t = ud.object(forKey: "lock.until") as? Double, t > 0 { lockedUntil = Date(timeIntervalSince1970: t) }
        refreshAuth()
    }

    // MARK: 状态
    var appCount: Int { selection.applicationTokens.count }
    var categoryCount: Int { selection.categoryTokens.count }
    var webCount: Int { selection.webDomainTokens.count }
    var hasSelection: Bool { appCount + categoryCount + webCount > 0 }
    var isLocked: Bool { if let u = lockedUntil { return u > Date() }; return false }

    func refreshAuth() {
        let st = AuthorizationCenter.shared.authorizationStatus
        let ok = (st == .approved)
        DispatchQueue.main.async { self.authorized = ok }
    }

    // 给 /status 用:,"lock":{"auth":true,"apps":3,"until":1725700000}
    func statusFragment() -> String {
        let st = AuthorizationCenter.shared.authorizationStatus
        let auth = (st == .approved)
        let n = appCount + categoryCount + webCount
        let until = isLocked ? Int(lockedUntil!.timeIntervalSince1970) : 0
        return ",\"lock\":{\"auth\":\(auth),\"apps\":\(n),\"until\":\(until)}"
    }

    // MARK: 授权(iOS 16+ 个人授权:会弹系统面板,可能要输锁屏密码)
    func requestAuth(_ done: @escaping (Bool, String) -> Void) {
        if #available(iOS 16.0, *) {
            Task {
                do {
                    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    self.refreshAuth()
                    DispatchQueue.main.async { done(true, "屏幕使用时间:已授权") }
                } catch {
                    self.refreshAuth()
                    DispatchQueue.main.async { done(false, "屏幕使用时间授权失败:\(error.localizedDescription)(多半是签名没带 family-controls 权限)") }
                }
            }
        } else {
            done(false, "真锁需要 iOS 16+")
        }
    }

    func saveSelection() {
        if let raw = try? JSONEncoder().encode(selection) { ud.set(raw, forKey: "lock.selection") }
        AppStore.shared.append("真锁:已选 \(appCount) 个 App、\(categoryCount) 个类别、\(webCount) 个网站")
        // 正在锁定时改了选择→按新选择重新盖一次
        if isLocked { applyShield() }
    }

    // MARK: 锁 / 解
    func lock(minutes: Int, reason: String, character: String) {
        refreshAuth()
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { AppStore.shared.append("真锁:没授权屏幕使用时间,忽略"); return }
        guard hasSelection else { AppStore.shared.append("真锁:还没选要锁的 App,忽略"); return }
        let m = max(1, min(480, minutes))
        let until = Date().addingTimeInterval(TimeInterval(m * 60))
        DispatchQueue.main.async { self.lockedUntil = until }
        ud.set(until.timeIntervalSince1970, forKey: "lock.until")
        applyShield()
        scheduleUnlock(at: until)
        AppStore.shared.append("真锁:\(character.isEmpty ? "角色" : character) 锁了选定的 App,\(m) 分钟后自动解" + (reason.isEmpty ? "" : "(\(reason))"))
        notify(title: (character.isEmpty ? "芋圆机" : character) + " 把你的 App 锁了", body: (reason.isEmpty ? "" : reason + "。") + "\(m) 分钟后自动解锁;急用可打开芋圆机助手点「现在解锁」。")
    }

    func unlock(reason: String = "") {
        unlockWork?.cancel(); unlockWork = nil
        store.clearAllSettings()
        DispatchQueue.main.async { self.lockedUntil = nil }
        ud.removeObject(forKey: "lock.until")
        AppStore.shared.append("真锁:已解锁" + (reason.isEmpty ? "" : "(\(reason))"))
    }

    // App 启动时调:过了点就解;没过就补一个定时器(App 被杀过、定时器丢了)
    func restore() {
        guard let u = lockedUntil else { return }
        if u <= Date() { unlock(reason: "到点·启动时补解") }
        else { applyShield(); scheduleUnlock(at: u) }
    }

    private func applyShield() {
        if selection.applicationTokens.isEmpty { store.shield.applications = nil } else { store.shield.applications = selection.applicationTokens }
        if selection.categoryTokens.isEmpty { store.shield.applicationCategories = nil } else { store.shield.applicationCategories = ShieldSettings.ActivityCategoryPolicy.specific(selection.categoryTokens) }
        if selection.webDomainTokens.isEmpty { store.shield.webDomains = nil } else { store.shield.webDomains = selection.webDomainTokens }
    }

    private func scheduleUnlock(at until: Date) {
        unlockWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.unlock(reason: "到点") }
        unlockWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, until.timeIntervalSinceNow), execute: w)
    }

    // 自检:读签名后打进包里的 embedded.mobileprovision,看描述文件到底带没带 family-controls(签名工具会把没有的权限剥掉/或装不上)
    static func profileCheck() -> String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"), let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "包里没有 embedded.mobileprovision(没经过正式签名?)" }
        guard let s0 = raw.range(of: Data("<?xml".utf8)), let e0 = raw.range(of: Data("</plist>".utf8)) else { return "描述文件读不出 plist" }
        let plistData = raw[s0.lowerBound..<e0.upperBound]
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { return "描述文件 plist 解析失败" }
        let ent = (obj["Entitlements"] as? [String: Any]) ?? [:]
        let name = (obj["Name"] as? String) ?? "?"
        let team = ((obj["TeamName"] as? String) ?? "?")
        let fc = ent["com.apple.developer.family-controls"] != nil
        let hk = ent["com.apple.developer.healthkit"] != nil
        let ag = ent["com.apple.security.application-groups"] != nil
        let keys = ent.keys.sorted().joined(separator: ", ")
        return "描述文件「\(name)」团队「\(team)」 family-controls:\(fc ? "有✅" : "没有❌") healthkit:\(hk ? "有" : "无") app-groups:\(ag ? "有" : "无") | 全部权限键:\(keys)"
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        let req = UNNotificationRequest(identifier: "yc-lock-" + UUID().uuidString, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}
