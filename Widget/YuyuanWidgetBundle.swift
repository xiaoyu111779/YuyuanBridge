import WidgetKit
import SwiftUI
import ActivityKit
import UIKit

@main
struct YuyuanWidgetBundle: WidgetBundle {
    var body: some Widget { YuyuanLiveActivity() }
}

// 淡蓝主题
let ycBlue = Color(red: 0.55, green: 0.75, blue: 0.98)
let ycBlueSoft = Color(red: 0.72, green: 0.85, blue: 1.0)

struct YuyuanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: YuyuanActivityAttributes.self) { ctx in
            // 锁屏 / 横幅
            HStack(spacing: 12) {
                CoverView(state: ctx.state, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.state.title).font(.headline).lineLimit(1)
                    Text(ctx.state.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    ProgressBar(state: ctx.state)
                }
                KindIcon(kind: ctx.state.kind).font(.title3)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { CoverView(state: ctx.state, size: 46).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) { KindIcon(kind: ctx.state.kind).font(.title2).padding(.trailing, 6) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.state.title).font(.subheadline.bold()).lineLimit(1)
                        Text(ctx.state.subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) { ProgressBar(state: ctx.state).padding(.horizontal, 6) }
            } compactLeading: {
                CoverView(state: ctx.state, size: 22)
            } compactTrailing: {
                KindIcon(kind: ctx.state.kind)
            } minimal: {
                CoverView(state: ctx.state, size: 22)
            }
        }
    }
}

struct KindIcon: View {
    let kind: String
    var body: some View { Image(systemName: kind == "listen" ? "music.note" : "book.fill").foregroundColor(ycBlue) }
}

// 进度条:有开始/结束时间→系统计时自己走;否则用静态 progress
struct ProgressBar: View {
    let state: YuyuanActivityAttributes.ContentState
    var body: some View {
        if let s = state.startAt, let e = state.endAt, e > s {
            ProgressView(timerInterval: s...e, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() }).tint(ycBlue)
        } else {
            ProgressView(value: state.progress).tint(ycBlue)
        }
    }
}

// 左侧图:共享容器里的封面/头像;读不到就画首字圆标
struct CoverView: View {
    let state: YuyuanActivityAttributes.ContentState
    let size: CGFloat
    var body: some View {
        if let n = state.imageName, let u = YuyuanShared.imageURL(n), let d = try? Data(contentsOf: u), let img = UIImage(data: d) {
            Image(uiImage: img).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: [ycBlueSoft, ycBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(state.charName.prefix(1))).font(.system(size: size * 0.48, weight: .bold)).foregroundColor(.white)
            }.frame(width: size, height: size)
        }
    }
}
