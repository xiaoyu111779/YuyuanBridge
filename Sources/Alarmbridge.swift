import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

// 真·原生闹钟(iOS 26+ AlarmKit):和系统时钟闹钟一样——全屏响铃、静音模式也响、能停止/贪睡。
// 排闹钟只是调 API,不需要 App 在前台,所以走芋圆机的静默本机路(/action)就行。
// 低于 iOS 26 或未授权 → 回落成"提醒事项 + 到点通知"(软闹钟)。
enum AlarmBridge {
    // 申请授权(首次弹系统框)
    static func requestAuth(_ done: @escaping (Bool, String) -> Void) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task {
                do {
                    let st = try await AlarmManager.shared.requestAuthorization()
                    let ok = (st == .authorized)
                    DispatchQueue.main.async { done(ok, ok ? "闹钟权限:已允许" : "闹钟权限:被拒绝(去 设置→芋圆机助手 打开)") }
                } catch {
                    DispatchQueue.main.async { done(false, "闹钟权限出错:\(error.localizedDescription)") }
                }
            }
            return
        }
        #endif
        done(false, "闹钟需要 iOS 26+(当前系统不支持,已改用提醒+通知)")
    }

    // 排一个一次性闹钟。成功回 true;不支持/失败回 false(调用方回落软闹钟)
    static func schedule(title: String, at date: Date, done: @escaping (Bool, String) -> Void) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task {
                do {
                    let mgr = AlarmManager.shared
                    var st = mgr.authorizationState
                    if st == .notDetermined { st = try await mgr.requestAuthorization() }
                    guard st == .authorized else { DispatchQueue.main.async { done(false, "闹钟权限未允许") }; return }
                    let stop = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
                    let snooze = AlarmButton(text: "稍后", textColor: .white, systemImageName: "moon.zzz.fill")
                    let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title.isEmpty ? "闹钟" : title),
                                                        stopButton: stop,
                                                        secondaryButton: snooze,
                                                        secondaryButtonBehavior: .countdown)
                    let presentation = AlarmPresentation(alert: alert)
                    let attrs = AlarmAttributes<YuyuanAlarmMeta>(presentation: presentation, tintColor: Color.orange)
                    let cfg = AlarmManager.AlarmConfiguration(
                        countdownDuration: .init(preAlert: nil, postAlert: 9 * 60),   // "稍后"=9 分钟后再响
                        schedule: .fixed(date),
                        attributes: attrs,
                        sound: .default)
                    _ = try await mgr.schedule(id: UUID(), configuration: cfg)
                    DispatchQueue.main.async { done(true, "已定真闹钟:\(title) @ \(Self.fmt.string(from: date))") }
                } catch {
                    DispatchQueue.main.async { done(false, "定闹钟失败:\(error.localizedDescription)") }
                }
            }
            return
        }
        #endif
        done(false, "闹钟需要 iOS 26+")
    }

    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct YuyuanAlarmMeta: AlarmMetadata {}   // 不需要附加数据,给个空结构体满足泛型
#endif
