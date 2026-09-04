import SwiftUI

// 极简界面：这个 App 平时不用打开看，界面只是给你首次授权 + 调试用。
// - 两个按钮：请求"提醒事项"权限、请求"通知"权限（首次点会弹系统同意框）
// - 一个"自测"按钮：本地模拟收到一条 reminder，验证链路
// - 下方日志：显示最近处理了什么
struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var live = LiveLink.shared

    var body: some View {
        NavigationView {
            List {
                Section("实时联动（芋圆机在这台 iPhone 上时，char 能实时知道电量）") {
                    Toggle(isOn: Binding(get: { live.running }, set: { on in on ? live.start() : live.stop() })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保持后台运行 · 本机服务")
                            Text(live.running ? "运行中 127.0.0.1:\(LiveLink.port)" + (live.lastServed.isEmpty ? "" : " · 最近被读取 \(live.lastServed)") : "已关闭（开了后请勿从多任务划掉本 App）")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    Text("原理：后台播放静音音频保活（约 1~3%/小时），只监听本机回环地址、不上网。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("权限（首次各点一次，弹窗选'允许'）") {
                    Button {
                        ActionHandler.shared.requestReminderAccess { ok in
                            store.reminderGranted = ok
                            store.append(ok ? "提醒事项权限：已允许" : "提醒事项权限：被拒绝")
                        }
                    } label: {
                        HStack { Text("请求「提醒事项」权限")
                            Spacer(); Text(store.reminderGranted ? "✅" : "—") }
                    }
                    Button {
                        ActionHandler.shared.requestNotifyAccess { ok in
                            store.notifyGranted = ok
                            store.append(ok ? "通知权限：已允许" : "通知权限：被拒绝")
                        }
                    } label: {
                        HStack { Text("请求「通知」权限")
                            Spacer(); Text(store.notifyGranted ? "✅" : "—") }
                    }
                    Button {
                        AlarmBridge.requestAuth { ok, msg in store.alarmGranted = ok; store.append(msg) }
                    } label: {
                        HStack { Text("请求「闹钟」权限（iOS 26+ 真闹钟）")
                            Spacer(); Text(store.alarmGranted ? "✅" : "—") }
                    }
                }

                Section("自测（不依赖芋圆机，先验证 App 本身能用）") {
                    Button("① 立刻弹一条测试通知") {
                        ActionHandler.shared.handle(url: URL(string:
                            "yuyuanji://notify?title=" + enc("测试") +
                            "&body=" + enc("芋圆机助手通了 🎉"))!)
                    }
                    Button("③ 定一个 2 分钟后的真闹钟测试") {
                        let t = Date().addingTimeInterval(120)
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
                        ActionHandler.shared.handle(url: URL(string:
                            "yuyuanji://alarm?title=" + enc("测试闹钟") + "&time=" + enc(f.string(from: t)))!)
                    }
                    Button("② 往提醒事项写一条测试") {
                        ActionHandler.shared.handle(url: URL(string:
                            "yuyuanji://reminder?title=" + enc("带护照") +
                            "&notes=" + enc("陆言之：明早记得把护照带上"))!)
                    }
                }

                Section("处理日志") {
                    if store.log.isEmpty {
                        Text("（还没有记录）").foregroundColor(.secondary)
                    } else {
                        ForEach(store.log, id: \.self) { Text($0).font(.footnote) }
                    }
                }
            }
            .navigationTitle("芋圆机助手")
        }
        .navigationViewStyle(.stack)
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
    }
}

extension CharacterSet {
    // 用于给 URL 查询值做百分号编码
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&=?#")
        return cs
    }()
}
