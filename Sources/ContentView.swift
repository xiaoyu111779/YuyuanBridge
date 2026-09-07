import SwiftUI
import EventKit
import FamilyControls

// 主界面:顶部一个折叠的「使用说明」,下面各功能区不再堆注释
struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var live = LiveLink.shared
    @ObservedObject var lock = LockBridge.shared
    @State private var showHelp = false
    @State private var showPicker = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    DisclosureGroup(isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. 先点下面「权限」里的几项，弹窗都选允许。")
                            Text("2. 打开「保持后台运行」，之后别从多任务把本 App 划掉。它靠后台静音音频保活（约 1~3%/小时），只监听本机、不上网。")
                            Text("3. 回芋圆机：设置 → 手机联动，开总开关。同一台 iPhone 上 char 就能实时知道你电量、步数、睡眠，还能替你设提醒、闹钟、日历、备忘录。")
                            Text("4. 芋圆出餐台：酒馆关着时也能让 ta 发消息。和 ta 聊一句后这里会出现角色名。快捷指令 App → 新建 → 搜「芋圆机助手」→ 选「让当前角色给我发消息」→ 随便起名（如 芋圆机）→ 说「Siri，运行 芋圆机」；也可绑到「轻点背面」或操作按钮。换卡不用改。")
                            Text("5. 电量是系统给的 5% 一档近似值。备忘录需在快捷指令里建一条「创建备忘录」的指令并在芋圆机填名字。")
                            Text("6. 主动感知：芋圆机里开「ta 会主动感知我的手机」后，没电/醒了/熬夜/没出门/明天有安排/好久没理 ta 这些事会自动推给角色，ta 按人设决定说不说。想让 ta 知道「打开了小红书 / 到家 / 出门 / 闹钟贪睡 / 开始运动」：快捷指令 App → 自动化 → 选触发条件（如「打开 App：小红书」）→ 添加操作搜「芋圆机助手」→「向角色报告一件事」→ 事件填 app_opened，备注填 小红书 → 关掉「运行前询问」。到家/出门用「到达/离开」触发，事件填 arrived_home / left_home；闹钟贪睡填 alarm_snoozed；运动填 workout_start / workout_end。")
                        }
                        .font(.footnote).foregroundColor(.secondary).padding(.vertical, 4)
                    } label: {
                        Label("使用说明", systemImage: "questionmark.circle")
                    }
                }

                Section("实时联动") {
                    Toggle(isOn: Binding(get: { live.running }, set: { on in on ? live.start() : live.stop() })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保持后台运行")
                            Text(live.running ? "运行中" + (live.lastServed.isEmpty ? "" : " · 最近被读取 \(live.lastServed)") : "已关闭")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }

                Section("权限") {
                    Button {
                        ActionHandler.shared.requestReminderAccess { ok in
                            store.reminderGranted = ok
                            store.append(ok ? "提醒事项权限：已允许" : "提醒事项权限：被拒绝")
                        }
                    } label: { HStack { Text("提醒事项"); Spacer(); Text(store.reminderGranted ? "✅" : "—") } }
                    Button {
                        ActionHandler.shared.requestNotifyAccess { ok in
                            store.notifyGranted = ok
                            store.append(ok ? "通知权限：已允许" : "通知权限：被拒绝")
                        }
                    } label: { HStack { Text("通知"); Spacer(); Text(store.notifyGranted ? "✅" : "—") } }
                    Button {
                        let st = EKEventStore()
                        if #available(iOS 17.0, *) { st.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { store.calendarGranted = ok; store.append(ok ? "日历权限(读写):已允许" : "日历权限:被拒绝") } } }
                        else { st.requestAccess(to: .event) { ok, _ in DispatchQueue.main.async { store.calendarGranted = ok; store.append(ok ? "日历权限:已允许" : "日历权限:被拒绝") } } }
                    } label: { HStack { Text("日历（读 + 写）"); Spacer(); Text(store.calendarGranted ? "✅" : "—") } }
                    Button {
                        HealthBridge.shared.requestAuth { ok, msg in store.healthGranted = ok; store.append(msg) }
                    } label: { HStack { Text("健康（步数 / 睡眠）"); Spacer(); Text(store.healthGranted ? "✅" : "—") } }
                    Button {
                        AlarmBridge.requestAuth { ok, msg in store.alarmGranted = ok; store.append(msg) }
                    } label: { HStack { Text("闹钟（iOS 26+）"); Spacer(); Text(store.alarmGranted ? "✅" : "—") } }
                }

                // v29:真锁(屏幕使用时间)。需签名带 family-controls 权限;授权失败=签名没带,删掉 Entitlements 里那一行重编即可。
                Section("真锁（屏幕使用时间）") {
                    Button {
                        LockBridge.shared.requestAuth { ok, msg in store.append(msg) }
                    } label: { HStack { Text("授权屏幕使用时间"); Spacer(); Text(lock.authorized ? "✅" : "—") } }
                    Button {
                        showPicker = true
                    } label: { HStack { Text("选要锁的 App / 网站"); Spacer(); Text(lock.hasSelection ? "\(lock.appCount) App · \(lock.categoryCount) 类 · \(lock.webCount) 站" : "未选").font(.footnote).foregroundColor(.secondary) } }
                    .disabled(!lock.authorized)
                    .familyActivityPicker(isPresented: $showPicker, selection: $lock.selection)
                    .onChange(of: showPicker) { open in if !open { LockBridge.shared.saveSelection() } }
                    if lock.isLocked, let u = lock.lockedUntil {
                        Text("锁定中，到 " + Self.hm.string(from: u) + " 自动解锁").font(.footnote).foregroundColor(.orange)
                    }
                    Button("锁 1 分钟（测试）") { LockBridge.shared.lock(minutes: 1, reason: "测试", character: "测试") }
                        .disabled(!lock.authorized || !lock.hasSelection)
                    Button("现在解锁") { LockBridge.shared.unlock(reason: "手动") }
                    Button("检查签名带没带屏幕使用时间权限") { store.append(LockBridge.profileCheck()) }
                    Text("芋圆机 → 设置 → 手机联动 里打开「ta 可以真的锁我的 App」。ta 说「别看了/去睡」时，选定的 App 会立刻盖上系统挡板，到分钟数自动解。选择器里别选本 App 自己，不然解锁只能等到点。").font(.footnote).foregroundColor(.secondary)
                }

                Section("芋圆出餐台") {
                    let names = Brain.shared.charNames
                    if names.isEmpty {
                        Text("还没同步角色。去芋圆机开「手机联动」，和 ta 聊一句。").font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(names, id: \.cardKey) { n in
                            HStack { Text(n.name); Spacer(); Text("已同步").font(.footnote).foregroundColor(.secondary) }
                        }
                        Button("测试：让 \(names.first!.name) 现在发条消息") {
                            Brain.shared.generate(charName: names.first!.name, trigger: "你这会儿突然想起 \(Brain.shared.snapshot(forName: names.first!.name)?.userName ?? "ta"),想给 ta 发几句") { _, _ in }
                        }
                    }
                }

                Section("自测") {
                    Button("弹一条测试通知") {
                        ActionHandler.shared.handle(url: URL(string:
                            "yuyuanji://notify?title=" + enc("测试") + "&body=" + enc("如果你看到这条，通知就通了"))!)
                    }
                    Button("定一个 2 分钟后的真闹钟") {
                        let t = Date().addingTimeInterval(120)
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
                        ActionHandler.shared.handle(url: URL(string:
                            "yuyuanji://alarm?title=" + enc("测试闹钟") + "&time=" + enc(f.string(from: t)))!)
                    }
                    Button("灵动岛测试（显示 20 秒）") {
                        // 自检:安装后的真实包名 / PlugIns 里有没有扩展 / 扩展包名 —— 签名工具改了包名会让扩展不再是子级,系统就不渲染
                        let mainId = Bundle.main.bundleIdentifier ?? "?"
                        var exInfo = "PlugIns:无"
                        if let purl = Bundle.main.builtInPlugInsURL, let items = try? FileManager.default.contentsOfDirectory(at: purl, includingPropertiesForKeys: nil) {
                            let names = items.map { $0.lastPathComponent }
                            exInfo = "PlugIns:" + (names.isEmpty ? "空" : names.joined(separator: ","))
                            if let ex = items.first(where: { $0.pathExtension == "appex" }), let b = Bundle(url: ex) { exInfo += " | 扩展包名:" + (b.bundleIdentifier ?? "?") }
                        }
                        store.append("自检 主App包名:\(mainId) | \(exInfo) | 实时活动允许:\(ActivityBridge.shared.enabled)")
                        ActivityBridge.shared.handle(act: "start", kind: "listen", title: "测试歌曲", subtitle: "和 测试角色 一起听", progress: 0.42, charName: "测", imageSrc: "", duration: 200, position: 84)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { ActivityBridge.shared.end() }
                    }
                    Button("往提醒事项写一条测试") {
                        ActionHandler.shared.handle(url: URL(string:
                            "yuyuanji://reminder?title=" + enc("测试提醒") + "&body=" + enc("来自芋圆机助手"))!)
                    }
                }

                Section("处理日志") {
                    if store.log.isEmpty {
                        Text("还没有收到任何动作。").foregroundColor(.secondary)
                    } else {
                        ForEach(store.log, id: \.self) { line in
                            Text(line).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("芋圆机助手")
        }
        .navigationViewStyle(.stack)
    }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
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
