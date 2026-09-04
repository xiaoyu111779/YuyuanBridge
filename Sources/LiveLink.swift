import Foundation
import AVFoundation
import Network
import UIKit

// 实时联动:让 App 在后台活着(静音音频保活),并在本机 127.0.0.1:27182 开一个极小的 HTTP 服务,
// 芋圆机网页(同一台 iPhone 的 Safari/PWA)直接 fetch 拿到 {电量,是否充电,时间}。
// 不经过任何服务器、不上网。用户从多任务划掉 App 就停,重新打开自动恢复。
final class LiveLink: ObservableObject {
    static let shared = LiveLink()
    static let port: UInt16 = 27182

    @Published var running = false
    @Published var lastServed: String = ""

    private var player: AVAudioPlayer?
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private var storedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "livelink.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "livelink.enabled") }
    }

    var isEnabledPref: Bool { storedEnabled }

    // MARK: 启停
    func start() {
        storedEnabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        startKeepAlive()
        startServer()
        DispatchQueue.main.async { self.running = true }
        AppStore.shared.append("实时联动:已开启(本机 127.0.0.1:\(Self.port))")
    }
    func stop() {
        storedEnabled = false
        player?.stop(); player = nil
        listener?.cancel(); listener = nil
        conns.forEach { $0.cancel() }; conns.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.running = false }
        AppStore.shared.append("实时联动:已关闭")
    }
    func restoreIfNeeded() { if storedEnabled && !running { start() } }

    // MARK: 保活——播放一段合成的静音 wav 循环(混音模式,不打断用户在听的音乐)
    private func startKeepAlive() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            if player == nil {
                let data = Self.silentWav(seconds: 2)
                player = try AVAudioPlayer(data: data)
                player?.numberOfLoops = -1
                player?.volume = 0.0
                player?.prepareToPlay()
            }
            player?.play()
        } catch {
            AppStore.shared.append("保活音频启动失败:\(error.localizedDescription)")
        }
    }
    // 生成 16-bit 单声道 8kHz 全零 PCM 的 wav 数据(无需打包音频文件)
    private static func silentWav(seconds: Int) -> Data {
        let sampleRate = 8000, channels = 1, bits = 16
        let dataLen = sampleRate * channels * bits / 8 * seconds
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataLen)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bits / 8)); u16(UInt16(channels * bits / 8)); u16(UInt16(bits))
        d.append("data".data(using: .ascii)!); u32(UInt32(dataLen)); d.append(Data(count: dataLen))
        return d
    }

    // MARK: 本机 HTTP 服务(只监听回环 127.0.0.1,外部访问不到)
    private func startServer() {
        if listener != nil { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { st in
                if case .failed(let e) = st { AppStore.shared.append("本机服务失败:\(e)") }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            AppStore.shared.append("本机服务启动失败:\(error.localizedDescription)")
        }
    }
    private func accept(_ c: NWConnection) {
        conns.append(c)
        c.stateUpdateHandler = { [weak self] st in if case .failed = st { self?.drop(c) } ; if case .cancelled = st { self?.drop(c) } }
        c.start(queue: .global(qos: .utility))
        var buf = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, _ in
                guard let self = self else { return }
                if let d = data { buf.append(d) }
                // 找到 header 结束;按 Content-Length 等 body 收完再处理(POST /sync 快照可能几十 KB)
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let headStr = String(data: buf[buf.startIndex..<r.lowerBound], encoding: .utf8) ?? ""
                    let cl = headStr.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    let bodyStart = r.upperBound
                    if buf.count - bodyStart >= cl || isDone {
                        let body = buf[bodyStart..<min(buf.endIndex, bodyStart + cl)]
                        self.respond(c, head: headStr, body: Data(body))
                        return
                    }
                }
                if isDone { self.respond(c, head: String(data: buf, encoding: .utf8) ?? "", body: Data()); return }
                readMore()
            }
        }
        readMore()
    }
    private func respond(_ c: NWConnection, head: String, body: Data) {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let q: [String: String] = {
            guard let comps = URLComponents(string: "http://x" + path) else { return [:] }
            var m: [String: String] = [:]; comps.queryItems?.forEach { if let v = $0.value { m[$0.name] = v } }; return m
        }()
        var status = "200 OK"; var out = ""
        if method == "OPTIONS" { status = "204 No Content" }
        else if path.hasPrefix("/status") || path.hasPrefix("/ping") { out = self.statusJSON() }
        else if path.hasPrefix("/action") {
            // 静默执行动作:GET /action?b64=<和 yuyuanji://action?b64= 完全同格式>
            if let b64 = q["b64"], let u = URL(string: "yuyuanji://action?b64=" + b64) {
                DispatchQueue.main.async { ActionHandler.shared.handle(url: u) }
                out = "{\"ok\":true}"
            } else { out = "{\"ok\":false,\"error\":\"bad action\"}" }
        }
        else if path.hasPrefix("/sync") {
            // 芋圆机同步"离线小脑"快照:POST body = base64url(JSON)
            let b64 = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (q["b64"] ?? "")
            let ok = Brain.shared.saveSnapshot(b64: b64)
            out = ok ? "{\"ok\":true}" : "{\"ok\":false,\"error\":\"bad snapshot\"}"
        }
        else if path.hasPrefix("/outbox/ack") {
            let ids = (q["ids"] ?? "").split(separator: ",").map(String.init)
            Brain.shared.ack(ids: ids)
            out = "{\"ok\":true}"
        }
        else if path.hasPrefix("/outbox") {
            out = Brain.shared.outboxJSON()
        }
        else { status = "404 Not Found"; out = "{\"ok\":false,\"error\":\"not found\"}" }
        let bodyData = out.data(using: .utf8) ?? Data()
        let headOut = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: *\r\n"
            + "Access-Control-Allow-Private-Network: true\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "Content-Length: \(bodyData.count)\r\n\r\n"
        var resp = headOut.data(using: .utf8)!; resp.append(bodyData)
        c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
        DispatchQueue.main.async { self.lastServed = Self.fmt.string(from: Date()) }
    }
    private func drop(_ c: NWConnection) { conns.removeAll { $0 === c } }

    // MARK: 状态 JSON
    func statusJSON() -> String {
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let lvl = dev.batteryLevel  // -1 = 未知(模拟器)
        let pct = lvl < 0 ? -1 : Int((lvl * 100).rounded())
        let charging: Bool
        switch dev.batteryState { case .charging, .full: charging = true; default: charging = false }
        let full = dev.batteryState == .full
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let ts = Int(Date().timeIntervalSince1970)
        return "{\"ok\":true,\"battery\":\(pct),\"approx\":true,\"charging\":\(charging),\"full\":\(full),\"lowPower\":\(lowPower),\"ts\":\(ts),\"app\":\"YuyuanBridge\"}"
    }
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}
