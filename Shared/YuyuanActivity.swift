import Foundation
import ActivityKit

// 主 App 与灵动岛扩展【共用】的数据结构(两个 target 都编译这个文件)。
// 不用 App Group:Live Activity 的数据由 ActivityKit 直接传给扩展,这里只放纯文本/数字。
struct YuyuanActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var kind: String        // "listen" | "read"
        var title: String       // 歌名 / 书名
        var subtitle: String    // 和 xx 一起听 · 歌手 / 和 xx 一起读 · 第 N 页
        var progress: Double    // 0~1(没有计时信息时用)
        var charName: String
        var imageName: String?  // App Group 共享容器里的图片文件名(歌曲封面/头像),没有就画首字
        var startAt: Date?      // 有开始/结束时间→进度条由系统自己走(不用频繁更新)
        var endAt: Date?
    }
    var startedAt: Date
}

// App Group 共享容器(主 App 写图片,扩展读)
enum YuyuanShared {
    static let group = "group.com.yuyuan.bridge"
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static func imageURL(_ name: String) -> URL? { containerURL?.appendingPathComponent(name) }
}
