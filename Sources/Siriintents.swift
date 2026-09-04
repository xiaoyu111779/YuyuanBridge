import Foundation
import AppIntents

// 角色实体:Siri 能听懂的"角色名",来自芋圆机同步过来的快照(同步过哪几张卡就认哪几个名字)
struct CharacterEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "角色")
    static var defaultQuery = CharacterQuery()
    var id: String            // cardKey
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct CharacterQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CharacterEntity] {
        Brain.shared.charNames.filter { identifiers.contains($0.cardKey) }.map { CharacterEntity(id: $0.cardKey, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [CharacterEntity] {
        Brain.shared.charNames.filter { $0.name.contains(string) || string.contains($0.name) }.map { CharacterEntity(id: $0.cardKey, name: $0.name) }
    }
    func suggestedEntities() async throws -> [CharacterEntity] {
        Brain.shared.charNames.map { CharacterEntity(id: $0.cardKey, name: $0.name) }
    }
}

// 「让角色给我发消息」:Siri / 快捷指令 / 轻点背面 / 操作按钮 都能触发;不需要打开 App,后台跑
struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "让角色给我发消息"
    static var description = IntentDescription("让芋圆机里的角色主动给你发一条微信(酒馆不用开着,下次打开会补进聊天记录)")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "角色") var character: CharacterEntity?

    static var parameterSummary: some ParameterSummary { Summary("让\(\.$character)给我发消息") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = character?.name
        let result: (Bool, [String]) = await withCheckedContinuation { cont in
            Brain.shared.generate(charName: name, trigger: "\(Brain.shared.snapshot(forName: name ?? "")?.userName ?? "ta") 想你了,让你给 ta 发几句") { ok, lines in cont.resume(returning: (ok, lines)) }
        }
        let who = name ?? (Brain.shared.charNames.first?.name ?? "角色")
        if result.0 { return .result(dialog: "\(who)发来了消息:\(result.1.first ?? "")") }
        return .result(dialog: "没发成:\(result.1.first ?? "未知错误")")
    }
}

// 「让当前角色给我发消息」:不用选角色,自动用芋圆机当前正在玩的那张卡(快照最新同步的角色)——只建一条快捷指令,换卡不用改
struct SendCurrentIntent: AppIntent {
    static var title: LocalizedStringResource = "让当前角色给我发消息"
    static var description = IntentDescription("不用选角色:自动用你在芋圆机里当前正在玩的角色。建一条快捷指令随便起名,换卡也不用改。")
    static var openAppWhenRun: Bool = false
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cur = Brain.shared.snapshot(forName: "")
        let name = cur?.charName
        let result: (Bool, [String]) = await withCheckedContinuation { cont in
            Brain.shared.generate(charName: name, trigger: "\(cur?.userName ?? "ta") 想你了,让你给 ta 发几句") { ok, lines in cont.resume(returning: (ok, lines)) }
        }
        if result.0 { return .result(dialog: "\(name ?? "角色")发来了消息:\(result.1.first ?? "")") }
        return .result(dialog: "没发成:\(result.1.first ?? "未知错误")")
    }
}

// 让 Siri 直接认这个短语(Apple 规定短语里必须带 App 名;Info.plist 里给 App 起了别名「芋圆机」)
struct YuyuanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendCurrentIntent(),
            phrases: ["让ta给我发消息 \(.applicationName)", "\(.applicationName) 让ta给我发消息", "\(.applicationName) 发消息"],
            shortTitle: "让当前角色发消息",
            systemImageName: "message.badge.filled.fill"
        )
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "让\(\.$character)给我发消息 \(.applicationName)",
                "\(.applicationName) 让\(\.$character)给我发消息",
                "叫\(\.$character)发条消息 \(.applicationName)",
                "\(.applicationName) 叫\(\.$character)发消息"
            ],
            shortTitle: "让角色发消息",
            systemImageName: "message.fill"
        )
    }
}
