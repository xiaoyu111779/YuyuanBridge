import SwiftUI
import UserNotifications

// App 入口。它做两件事：
// 1) 展示一个简单的状态/授权界面（首次用来点"同意提醒/通知权限"、看日志）
// 2) 接住 yuyuanji://... 链接，交给 ActionHandler 处理（写提醒/弹通知）
@main
struct YuyuanBridgeApp: App {
    @StateObject private var store = AppStore.shared

    init() {
        // 关键：不设这个 delegate，App 在【前台】时 iOS 会把本地通知静默掉（只进通知中心、不弹横幅）
        UNUserNotificationCenter.current().delegate = NotifyDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                // 芋圆机网页点 yuyuanji://... 会唤起本 App 并走这里
                .onOpenURL { url in
                    ActionHandler.shared.handle(url: url)
                }
        }
    }
}

// 让通知在 App 前台时也弹横幅+响铃+进列表（iOS 14+ 用 banner/list；老系统用 alert）
final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifyDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
    // 用户点了通知：把标题记进日志（以后可扩展成点通知跳回芋圆机）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        AppStore.shared.append("点了通知：\(response.notification.request.content.title)")
        completionHandler()
    }
}

// 全局小状态：只用来在界面上显示"最近收到的动作 / 权限状态"，方便你调试。
final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published var log: [String] = []          // 最近的处理日志（新在最前）
    @Published var reminderGranted: Bool = false
    @Published var notifyGranted: Bool = false

    func append(_ line: String) {
        DispatchQueue.main.async {
            let ts = Self.timeFmt.string(from: Date())
            self.log.insert("[\(ts)] \(line)", at: 0)
            if self.log.count > 50 { self.log.removeLast(self.log.count - 50) }
        }
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
