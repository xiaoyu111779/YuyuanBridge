import Foundation
import ActivityKit

// 灵动岛(Live Activity)控制:芋圆机发 activity start/update/end 过来,这里起/更/结束
final class ActivityBridge {
    static let shared = ActivityBridge()
    private var current: Activity<YuyuanActivityAttributes>? = nil

    var enabled: Bool { if #available(iOS 16.2, *) { return ActivityAuthorizationInfo().areActivitiesEnabled } else { return false } }

    func handle(act: String, kind: String, title: String, subtitle: String, progress: Double, charName: String) {
        guard #available(iOS 16.2, *) else { AppStore.shared.append("灵动岛需要 iOS 16.2+"); return }
        let state = YuyuanActivityAttributes.ContentState(kind: kind, title: title, subtitle: subtitle, progress: max(0, min(1, progress)), charName: charName)
        switch act {
        case "end":
            end()
        case "update":
            if let a = current { Task { await a.update(ActivityContent(state: state, staleDate: nil)) } }
            else { start(state) }
        default:
            start(state)
        }
    }
    @available(iOS 16.2, *)
    private func start(_ state: YuyuanActivityAttributes.ContentState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { AppStore.shared.append("灵动岛:系统未允许实时活动(设置→芋圆机助手→实时活动)"); return }
        do {
            current = try Activity.request(attributes: YuyuanActivityAttributes(startedAt: Date()), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            AppStore.shared.append("灵动岛:已显示「\(state.title)」")
        } catch { AppStore.shared.append("灵动岛启动失败:\(error.localizedDescription)") }
    }
    func end() {
        guard #available(iOS 16.2, *) else { return }
        if let a = current { Task { await a.end(nil, dismissalPolicy: .immediate) }; current = nil }
        // 顺手把系统里可能残留的旧活动也收掉
        for a in Activity<YuyuanActivityAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}
