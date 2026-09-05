import WidgetKit
import SwiftUI
import ActivityKit

@main
struct YuyuanWidgetBundle: WidgetBundle {
    var body: some Widget { YuyuanLiveActivity() }
}

// 灵动岛 + 锁屏的实时活动界面(MVP:名字首字圆标 + 标题 + 副标题 + 进度条;头像需 App Group,下一步再加)
struct YuyuanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: YuyuanActivityAttributes.self) { ctx in
            // 锁屏 / 横幅
            HStack(spacing: 12) {
                Avatar(name: ctx.state.charName, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.state.title).font(.headline).lineLimit(1)
                    Text(ctx.state.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    ProgressView(value: ctx.state.progress).tint(ctx.state.kind == "listen" ? .pink : .orange)
                }
                Image(systemName: ctx.state.kind == "listen" ? "music.note" : "book.fill").foregroundColor(.secondary)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Avatar(name: ctx.state.charName, size: 44).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) { Image(systemName: ctx.state.kind == "listen" ? "music.note" : "book.fill").font(.title2).foregroundColor(.pink).padding(.trailing, 6) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.state.title).font(.subheadline.bold()).lineLimit(1)
                        Text(ctx.state.subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: ctx.state.progress).tint(.pink).padding(.horizontal, 6) }
            } compactLeading: {
                Avatar(name: ctx.state.charName, size: 22)
            } compactTrailing: {
                Image(systemName: ctx.state.kind == "listen" ? "music.note" : "book.fill").foregroundColor(.pink)
            } minimal: {
                Avatar(name: ctx.state.charName, size: 22)
            }
        }
    }
}

struct Avatar: View {
    let name: String; let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.96, green: 0.78, blue: 0.85), Color(red: 0.75, green: 0.80, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(name.prefix(1))).font(.system(size: size * 0.48, weight: .bold)).foregroundColor(.white)
        }.frame(width: size, height: size)
    }
}
