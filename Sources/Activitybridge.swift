import Foundation
import ActivityKit
import UIKit

// 灵动岛(Live Activity)控制。iOS 规则:只能在 App【前台】启动,后台只能更新/结束。
// 所以:后台收到 start → 记成"待办",App 一到前台自动补起;已有活动时收到 start → 当 update;切歌不再重启。
final class ActivityBridge {
    static let shared = ActivityBridge()
    private var current: Activity<YuyuanActivityAttributes>? = nil
    private var pending: YuyuanActivityAttributes.ContentState? = nil
    private var observing = false

    var enabled: Bool { if #available(iOS 16.2, *) { return ActivityAuthorizationInfo().areActivitiesEnabled } else { return false } }

    private func observeForeground() {
        if observing { return }; observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let p = self.pending else { return }
            if #available(iOS 16.2, *) { self.start(p) }
        }
    }

    func handle(act: String, kind: String, title: String, subtitle: String, progress: Double, charName: String) {
        guard #available(iOS 16.2, *) else { AppStore.shared.append("灵动岛需要 iOS 16.2+"); return }
        observeForeground()
        let state = YuyuanActivityAttributes.ContentState(kind: kind, title: title, subtitle: subtitle, progress: max(0, min(1, progress)), charName: charName)
        switch act {
        case "end":
            pending = nil; end()
        default:
            // start 与 update 一律:有活动→更新;没活动→前台就起,后台就记待办
            if let a = current, a.activityState == .active {
                Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                current = nil
                if UIApplication.shared.applicationState == .active { start(state) }
                else { pending = state; AppStore.shared.append("灵动岛:App 在后台不能新起,已记下,下次打开 App 自动显示「\(state.title)」") }
            }
        }
    }
    @available(iOS 16.2, *)
    private func start(_ state: YuyuanActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { AppStore.shared.append("灵动岛:系统未允许实时活动(设置→芋圆机助手→实时活动)"); return }
        endAll()
        do {
            current = try Activity.request(attributes: YuyuanActivityAttributes(startedAt: Date()), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            pending = nil
            AppStore.shared.append("灵动岛:已显示「\(state.title)」")
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
