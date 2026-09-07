import Foundation
import ActivityKit
import UIKit

// 灵动岛(Live Activity)控制。iOS 规则:只能在 App【前台】启动,后台只能更新/结束。v29:先更新文字/计时条、封面后补(见 handle)。
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
    // v29:【先更新、图后补】——文字/计时条立刻 update(用已缓存的图,没有就先无图),封面另开线程下(8s 超时,失败 10 分钟不重试,同一张不重复下),到了再补一次。
    //   以前是先下图再 update:海外访问网易云图床慢或失败(默认 60s 才超时)时,每条 update 都被压后 60s、并且乱序落地→灵动岛长时间停在上一首/条不走。
    private var latestState: YuyuanActivityAttributes.ContentState? = nil
    private var inflight: Set<String> = []
    private var failedAt: [String: Date] = [:]
    func handle(act: String, kind: String, title: String, subtitle: String, progress: Double, charName: String, imageSrc: String, duration: Double, position: Double) {
        guard #available(iOS 16.2, *) else { AppStore.shared.append("灵动岛需要 iOS 16.2+"); return }
        observeForeground()
        if act == "end" { pending = nil; latestState = nil; end(); return }
        var startAt: Date? = nil, endAt: Date? = nil
        if duration > 0 { startAt = Date().addingTimeInterval(-max(0, position)); endAt = startAt!.addingTimeInterval(duration) }
        let src = imageSrc.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = cachedImageName(src)
        let state = YuyuanActivityAttributes.ContentState(kind: kind, title: title, subtitle: subtitle, progress: max(0, min(1, progress)), charName: charName, imageName: cached, startAt: startAt, endAt: endAt)
        latestState = state
        apply(state)
        if cached == nil, !src.isEmpty { prepareImage(src) { [weak self] name in
            guard let self = self, let name = name, var st = self.latestState else { return }
            st.imageName = name; self.latestState = st
            if #available(iOS 16.2, *) { self.apply(st) }
        } }
    }

    @available(iOS 16.2, *)
    private func apply(_ state: YuyuanActivityAttributes.ContentState) {
        if let a = self.current, a.activityState == .active {
            Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            self.current = nil
            if UIApplication.shared.applicationState == .active { self.start(state) }
            else { self.pending = state; AppStore.shared.append("灵动岛:App 在后台不能新起,已记下,下次打开 App 自动显示「\(state.title)」") }
        }
    }

    // 稳定哈希(Swift 的 hashValue 每次启动随机,跨启动就认不出缓存文件)
    private static func stableName(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "island_" + String(h, radix: 16) + ".png"
    }
    private func cachedImageName(_ src: String) -> String? {
        guard !src.isEmpty, let dir = YuyuanShared.containerURL else { return nil }
        if src == lastImageKey, let n = lastImageName { return n }
        let name = Self.stableName(src)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { lastImageKey = src; lastImageName = name; return name }
        return nil
    }

    // 把图片放进共享容器;同一张图不重复下载;失败 10 分钟内不再试
    private func prepareImage(_ src: String, done: @escaping (String?) -> Void) {
        let s = src
        guard !s.isEmpty, let dir = YuyuanShared.containerURL else { done(nil); return }
        if let n = cachedImageName(s) { done(n); return }
        if inflight.contains(s) { return }
        if let f = failedAt[s], Date().timeIntervalSince(f) < 600 { return }
        inflight.insert(s)
        let name = Self.stableName(s)
        let dest = dir.appendingPathComponent(name)
        let finish: (Data?) -> Void = { data in
            DispatchQueue.main.async { self.inflight.remove(s) }
            guard let data = data, let img = UIImage(data: data) else { DispatchQueue.main.async { self.failedAt[s] = Date(); done(nil) }; return }
            // 缩到 160px 见方,扩展渲染快、也省内存
            let side: CGFloat = 160
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
                let r = min(side / max(img.size.width, 1), side / max(img.size.height, 1)); let w = img.size.width * r, h = img.size.height * r
                img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            }
            guard let png = out.pngData() else { DispatchQueue.main.async { self.failedAt[s] = Date(); done(nil) }; return }
            do { try png.write(to: dest, options: .atomic); DispatchQueue.main.async { self.lastImageKey = s; self.lastImageName = name; done(name) } }
            catch { DispatchQueue.main.async { self.failedAt[s] = Date(); done(nil) } }
        }
        if s.hasPrefix("data:") {
            if let comma = s.firstIndex(of: ","), let d = Data(base64Encoded: String(s[s.index(after: comma)...])) { finish(d) } else { inflight.remove(s); done(nil) }
        } else if let u = URL(string: s), s.hasPrefix("http") {
            var req = URLRequest(url: u); req.timeoutInterval = 8
            URLSession.shared.dataTask(with: req) { d, _, _ in finish(d) }.resume()
        } else { inflight.remove(s); done(nil) }
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
