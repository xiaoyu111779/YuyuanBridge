import Foundation
import ActivityKit

// 主 App 与灵动岛扩展【共用】的数据结构(两个 target 都编译这个文件)。
// 不用 App Group:Live Activity 的数据由 ActivityKit 直接传给扩展,这里只放纯文本/数字。
struct YuyuanActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var kind: String        // "listen" | "read"
        var title: String       // 歌名 / 书名
        var subtitle: String    // 和 xx 一起听 · 歌手 / 和 xx 一起读 · 第 N 页
        var progress: Double    // 0~1
        var charName: String
    }
    var startedAt: Date
}
