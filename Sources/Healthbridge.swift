import Foundation
import HealthKit

// 健康数据(HealthKit):今天步数 + 昨晚睡眠时长。读出来塞进 /status,芋圆机再喂给 char。
// 需要签名时带 com.apple.developer.healthkit 权限(Entitlements.plist);全能签若剥掉该权限,授权框弹不出、这里会一直是空。
final class HealthBridge {
    static let shared = HealthBridge()
    private let store = HKHealthStore()
    private(set) var steps: Int = -1          // -1 = 未知
    private(set) var sleepMin: Int = -1       // 昨晚睡眠分钟数,-1 = 未知
    private(set) var fetchedAt: Date? = nil
    private var busy = false

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuth(_ done: @escaping (Bool, String) -> Void) {
        guard available else { done(false, "此设备不支持健康数据"); return }
        guard let st = HKObjectType.quantityType(forIdentifier: .stepCount), let sl = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { done(false, "健康类型不可用"); return }
        store.requestAuthorization(toShare: [], read: [st, sl]) { ok, err in
            DispatchQueue.main.async {
                if ok { done(true, "健康权限:已请求(读步数/睡眠)"); self.refresh(force: true) }
                else { done(false, "健康权限失败:\(err?.localizedDescription ?? "被拒绝或签名没带 HealthKit 权限")") }
            }
        }
    }

    // 最多 5 分钟刷一次;/status 被读时顺手触发
    func refresh(force: Bool = false) {
        guard available, !busy else { return }
        if !force, let t = fetchedAt, Date().timeIntervalSince(t) < 300 { return }
        busy = true
        let group = DispatchGroup()
        // 今天步数
        if let st = HKObjectType.quantityType(forIdentifier: .stepCount) {
            group.enter()
            let start = Calendar.current.startOfDay(for: Date())
            let pred = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            let q = HKStatisticsQuery(quantityType: st, quantitySamplePredicate: pred, options: .cumulativeSum) { _, res, _ in
                if let sum = res?.sumQuantity() { self.steps = Int(sum.doubleValue(for: .count())) }
                group.leave()
            }
            store.execute(q)
        }
        // 昨晚睡眠:昨天 18:00 → 今天 12:00 之间的"睡着"样本累加(去重叠)
        if let sl = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            group.enter()
            let cal = Calendar.current
            let todayNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
            let yest18 = cal.date(byAdding: .hour, value: -18, to: todayNoon) ?? Date().addingTimeInterval(-18 * 3600)
            let pred = HKQuery.predicateForSamples(withStart: yest18, end: min(todayNoon, Date()), options: [])
            let q = HKSampleQuery(sampleType: sl, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                var intervals: [(Date, Date)] = []
                for s in (samples as? [HKCategorySample]) ?? [] {
                    var asleep = false
                    if #available(iOS 16.0, *) {
                        asleep = HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: s.value) ?? .inBed)
                    } else { asleep = (s.value == HKCategoryValueSleepAnalysis.asleep.rawValue) }
                    if asleep { intervals.append((s.startDate, s.endDate)) }
                }
                // 合并重叠区间(多来源:手表+手机)
                var total: TimeInterval = 0; var curS: Date? = nil; var curE: Date? = nil
                for (s0, e0) in intervals.sorted(by: { $0.0 < $1.0 }) {
                    if let e = curE, s0 <= e { if e0 > e { curE = e0 } }
                    else { if let s1 = curS, let e1 = curE { total += e1.timeIntervalSince(s1) }; curS = s0; curE = e0 }
                }
                if let s1 = curS, let e1 = curE { total += e1.timeIntervalSince(s1) }
                self.sleepMin = intervals.isEmpty ? -1 : Int(total / 60)
                group.leave()
            }
            store.execute(q)
        }
        group.notify(queue: .main) { self.fetchedAt = Date(); self.busy = false }
    }

    // 拼进 /status 的片段
    func statusFragment() -> String {
        refresh()
        return ",\"steps\":\(steps),\"sleepMin\":\(sleepMin),\"healthAt\":\(Int((fetchedAt ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970))"
    }
}
