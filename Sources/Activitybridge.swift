import Foundation
import ActivityKit
import UIKit

// 灵动岛(Live Activity)控制。iOS 规则:只能在 App【前台】启动,后台只能更新/结束。
// 后台收到 start → 记待办,App 一到前台自动补起;已有活动时收到 start → 当 update。
// 图片:主 App 把歌曲封面/头像下载(或解 data:)到 App Group 共享容器,扩展从里面读;没有 App Group 权限就回落画首字。
final class ActivityBridge {
    static let shared = ActivityBridge()
    private var current: Activity<YuyuanActivityAttributes>? = nil
    private var pending: YuyuanActivityAttributes.ContentState? = nil
    private var observing = false
    private var lastImageKey = ""
    private var lastImageName: String? = nil

    var enabled: Bool { if #available(iOS 16.2, *) { return ActivityAuthorizationInfo().areActivitiesEnabled } else { return false } }

    private func observeForeground() {
        if observing { return }; observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let p = self.pending else { return }
            if #available(iOS 16.2, *) { self.start(p) }
        }
    }

    // imageSrc:歌曲封面(优先)或头像;http(s) 或 data:image/...;base64,...
    func handle(act: String, kind: String, title: String, subtitle: String, progress: Double, charName: String, imageSrc: String, duration: Double, position: Double) {
        guard #available(iOS 16.2, *) else { AppStore.shared.append("灵动岛需要 iOS 16.2+"); return }
        observeForeground()
        if act == "end" { pending = nil; end(); return }
        var startAt: Date? = nil, endAt: Date? = nil
        if duration > 0 { startAt = Date().addingTimeInterval(-max(0, position)); endAt = startAt!.addingTimeInterval(duration) }
        prepareImage(imageSrc) { [weak self] name in
            guard let self = self else { return }
            let state = YuyuanActivityAttributes.ContentState(kind: kind, title: title, subtitle: subtitle, progress: max(0, min(1, progress)), charName: charName, imageName: name, startAt: startAt, endAt: endAt)
            if let a = self.current, a.activityState == .active {
                Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                self.current = nil
                if UIApplication.shared.applicationState == .active { self.start(state) }
                else { self.pending = state; AppStore.shared.append("灵动岛:App 在后台不能新起,已记下,下次打开 App 自动显示「\(state.title)」") }
            }
        }
    }

    // 把图片放进共享容器;同一张图不重复下载
    private func prepareImage(_ src: String, done: @escaping (String?) -> Void) {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let dir = YuyuanShared.containerURL else { done(nil); return }
        if s == lastImageKey, let n = lastImageName { done(n); return }
        let name = "island_" + String(abs(s.hashValue)) + ".png"
        let dest = dir.appendingPathComponent(name)
        let finish: (Data?) -> Void = { data in
            guard let data = data, let img = UIImage(data: data) else { DispatchQueue.main.async { done(nil) }; return }
            // 缩到 160px 见方,扩展渲染快、也省内存
            let side: CGFloat = 160
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
                let r = min(side / max(img.size.width, 1), side / max(img.size.height, 1)); let w = img.size.width * r, h = img.size.height * r
                img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            }
            guard let png = out.pngData() else { DispatchQueue.main.async { done(nil) }; return }
            do { try png.write(to: dest, options: .atomic); self.lastImageKey = s; self.lastImageName = name; DispatchQueue.main.async { done(name) } }
            catch { DispatchQueue.main.async { done(nil) } }
        }
        if s.hasPrefix("data:") {
            if let comma = s.firstIndex(of: ","), let d = Data(base64Encoded: String(s[s.index(after: comma)...])) { finish(d) } else { done(nil) }
        } else if let u = URL(string: s), s.hasPrefix("http") {
            URLSession.shared.dataTask(with: u) { d, _, _ in finish(d) }.resume()
        } else { done(nil) }
    }

    @available(iOS 16.2, *)
    private func start(_ state: YuyuanActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { AppStore.shared.append("灵动岛:系统未允许实时活动(设置→芋圆机助手→实时活动)"); return }
        endAll()
        do {
            current = try Activity.request(attributes: YuyuanActivityAttributes(startedAt: Date()), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            pending = nil
            AppStore.shared.append("灵动岛:已显示「\(state.title)」" + (state.imageName == nil ? "(无图:App Group 不可用或没给图)" : ""))
        } catch {
            pending = state
            AppStore.shared.append("灵动岛启动失败:\(error.localizedDescription)(已记下,下次打开 App 自动显示)")
        }
    }
    func end() {
        guard #available(iOS 16.2, *) else { return }
        if let a = current { Task { await a.end(nil, dismissalPolicy: .immediate) }; current = nil }
        endAll()
    }
    @available(iOS 16.2, *)
    private func endAll() { for a in Activity<YuyuanActivityAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } } }
}
