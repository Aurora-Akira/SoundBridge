import Foundation
import Network
import AVFoundation
import MediaPlayer
import UIKit
import os


struct DiscoveredPC: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    /// 扫描局域网找到的电脑只有 IP，没有 Bonjour 名字
    var ip: String? = nil
    var id: String { name }
    /// 选中它时存的 selection
    var selectionKey: String { ip.map { "ip:" + $0 } ?? "pc:" + name }
}

enum Phase: Equatable {
    case off          // 没开
    case searching    // 在找电脑
    case connecting   // 连接中 / 重连中
    case listening    // 已连上，正在播放
}

enum LatencyPreset: String, CaseIterable, Identifiable {
    case auto, low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return T("自动", "Auto")
        case .low: return T("低", "Low")
        case .medium: return T("中", "Medium")
        case .high: return T("高", "High")
        }
    }
    /// 最低目标延迟（毫秒）
    var baseMs: Double {
        switch self {
        case .auto: return 60
        case .low: return 60
        case .medium: return 150
        case .high: return 300
        }
    }
}

/// 网络线程写、主线程读的时间戳
private final class Stamp {
    private var lock = os_unfair_lock()
    private var value: CFTimeInterval = 0
    func set(_ v: CFTimeInterval) { os_unfair_lock_lock(&lock); value = v; os_unfair_lock_unlock(&lock) }
    func get() -> CFTimeInterval { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return value }
}

/// 发现电脑、连 TCP、收 PCM，喂给环形缓冲。
final class RelayClient: ObservableObject {
    static let port: UInt16 = 47800
    static let serviceType = "_hearrelay._tcp"

    @Published var enabled = false {
        didSet { if enabled != oldValue { enabled ? begin() : end() } }
    }
    @Published private(set) var phase: Phase = .off
    @Published private(set) var status = ""
    @Published private(set) var connected = false
    @Published private(set) var pcs: [DiscoveredPC] = []
    @Published private(set) var bufferMs = 0
    @Published private(set) var underruns = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var routeName = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var events: [String] = []
    @Published private(set) var interrupted = false
    /// App 内选的语言；空 = 跟系统
    @Published var languageOverride: String = Lang.override {
        didSet {
            guard languageOverride != oldValue else { return }
            Lang.set(languageOverride)
            updateNowPlaying()
            refreshStats()
        }
    }

    /// 被来电 / 其他 App 打断后，用户点按钮恢复
    func resumeAfterInterruption() {
        guard enabled else { enabled = true; return }
        output.start()
        interrupted = false
        log(T("手动恢复播放", "Resumed"))
    }
    /// "pc:电脑名" 或 "ip:192.168.x.x"
    @Published var selection: String {
        didSet {
            UserDefaults.standard.set(selection, forKey: "selection")
            if selection != oldValue && enabled { reconnectNow(reason: nil); updateNowPlaying() }
        }
    }
    @Published var manualHost: String {
        didSet { UserDefaults.standard.set(manualHost, forKey: "manualHost") }
    }
    @Published var preset: LatencyPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "latencyPreset")
            autoTargetMs = preset.baseMs
            applyLatency()
        }
    }
    /// 自动模式下当前的目标延迟
    @Published private(set) var autoTargetMs: Double = 60

    private var lastUnderruns = 0
    private var calmTicks = 0
    private var rateMismatchTicks = 0
    private var requestedRate: Double = 0
    private var connectedAt: Date?
    private var headerReceived = false
    private let lastData = Stamp()

    private let ring: RingBuffer
    private let output: AudioOutput
    private let netQueue = DispatchQueue(label: "relay.net")
    private var conn: NWConnection?
    private var browser: NWBrowser?
    private var retry: DispatchWorkItem?
    private var statsTimer: Timer?
    private var meterTimer: Timer?
    // 仅在 netQueue 上访问
    private var header = Data()
    private var gotHeader = false
    private var carry = Data()
    private var activeConn: ObjectIdentifier?

    init() {
        let d = UserDefaults.standard
        selection = d.string(forKey: "selection") ?? ""
        manualHost = d.string(forKey: "manualHost") ?? ""
        let p = LatencyPreset(rawValue: d.string(forKey: "latencyPreset") ?? "") ?? .auto
        preset = p
        autoTargetMs = p.baseMs
        ring = RingBuffer(capacityFrames: 192_000, targetFrames: 4_000)
        output = AudioOutput(ring: ring)
        output.onLog = { [weak self] msg in self?.log(msg) }
        applyLatency()
        setupRemoteCommands()
        startBrowsing()
        routeName = output.routeDescription
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.routeName = self.output.routeDescription
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onForeground()
        }
    }

    // MARK: - 开关

    private func begin() {
        output.start()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStats() }
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.refreshMeter() }
        log(T("开始收听", "Started"))
        phase = .searching
        connect()
        updateNowPlaying()
    }

    private func end() {
        retry?.cancel()
        retry = nil
        let c = conn
        conn = nil
        netQueue.async { c?.cancel() }
        output.stop()
        ring.reset()
        statsTimer?.invalidate()
        statsTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        connected = false
        headerReceived = false
        bufferMs = 0
        level = 0
        phase = .off
        status = ""
        log(T("已停止", "Stopped"))
        updateNowPlaying()
    }

    func useManualHost() {
        let h = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        manualHost = h
        selection = "ip:" + h
        if !enabled { enabled = true }
    }

    func choose(_ pc: DiscoveredPC) {
        selection = pc.selectionKey
        if !enabled { enabled = true }
    }

    /// 回到前台：如果开着但数据早就断了，立刻重连，不等看门狗
    private func onForeground() {
        guard enabled else { return }
        routeName = output.routeDescription
        if output.interrupted { output.start() }
        if connected, headerReceived, CACurrentMediaTime() - lastData.get() > 1.0 {
            reconnectNow(reason: T("回到前台时发现数据已断，重新连接", "Stream was stale on return; reconnecting"))
        }
        if pcs.isEmpty { scanSubnet() }
    }

    // MARK: - 发现

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [DiscoveredPC] = []
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint {
                    list.append(DiscoveredPC(name: name, endpoint: r.endpoint))
                }
            }
            list.sort { $0.name < $1.name }
            DispatchQueue.main.async { self?.onDiscovered(list) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case let .failed(err) = state {
                DispatchQueue.main.async { self?.log(T("自动发现失败：\(err)", "Discovery failed: \(err)")) }
            }
        }
        b.start(queue: netQueue)
        browser = b
        // 有些路由器 / 随身 Wi-Fi 不转发组播，自动发现会找不到：3 秒后还没结果就扫一遍局域网
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.pcs.isEmpty else { return }
            self.scanSubnet()
        }
    }

    private func onDiscovered(_ list: [DiscoveredPC]) {
        bonjourPCs = list
        mergePCs()
    }

    private var bonjourPCs: [DiscoveredPC] = []
    private var scannedPCs: [DiscoveredPC] = []
    @Published private(set) var scanning = false

    /// Bonjour 找到的 + 扫描找到的合并（同一台电脑只保留 Bonjour 那条）
    private func mergePCs() {
        var list = bonjourPCs
        for s in scannedPCs where !list.contains(where: { $0.name == s.name }) { list.append(s) }
        pcs = list
        if selection.isEmpty, list.count == 1 {
            selection = list[0].selectionKey
        }
        if enabled, conn == nil, list.contains(where: { $0.selectionKey == selection }) {
            connect()
        }
    }

    /// 扫描手机所在的 /24 网段，找开着 47800 端口的电脑（不依赖组播）
    func scanSubnet() {
        guard !scanning, let myIP = Self.wifiIPv4() else { return }
        let parts = myIP.split(separator: ".")
        guard parts.count == 4 else { return }
        let prefix = parts[0...2].joined(separator: ".") + "."
        scanning = true
        log(T("正在扫描局域网找电脑……", "Scanning the local network for your PC…"))
        let hosts = (1...254).map { prefix + String($0) }.filter { $0 != myIP }
        let lock = NSLock()
        var found: [String] = []
        let group = DispatchGroup()
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { scanning = false; return }
        for h in hosts {
            group.enter()
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 2
            let c = NWConnection(host: NWEndpoint.Host(h), port: port, using: NWParameters(tls: nil, tcp: tcp))
            var done = false
            let finish: (Bool) -> Void = { ok in
                lock.lock()
                if done { lock.unlock(); return }
                done = true
                if ok { found.append(h) }
                lock.unlock()
                c.cancel()
                group.leave()
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            c.start(queue: netQueue)
            netQueue.asyncAfter(deadline: .now() + 2.5) { finish(false) }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.scanning = false
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            self.scannedPCs = found.sorted().map {
                DiscoveredPC(name: $0, endpoint: .hostPort(host: NWEndpoint.Host($0), port: port), ip: $0)
            }
            self.log(found.isEmpty ? T("局域网里没扫到电脑", "No PC found on the local network")
                                   : T("扫到电脑：", "Found: ") + found.joined(separator: ", "))
            self.mergePCs()
            if self.enabled, self.conn == nil { self.connect() }
        }
    }

    /// 手机 Wi-Fi（en0）的 IPv4 地址，只认局域网私有地址
    static func wifiIPv4() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.hasPrefix("172.") { result = s }
            }
        }
        return result
    }

    // MARK: - 连接

    private func targetEndpoint() -> NWEndpoint? {
        if selection.hasPrefix("ip:") {
            let host = String(selection.dropFirst(3))
            guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: Self.port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        if selection.hasPrefix("pc:") {
            let name = String(selection.dropFirst(3))
            return pcs.first(where: { $0.name == name })?.endpoint
        }
        return nil
    }

    private func reconnectNow(reason: String?) {
        if let reason = reason { log(reason) }
        retry?.cancel()
        let c = conn
        conn = nil
        netQueue.async { c?.cancel() }
        connected = false
        headerReceived = false
        connect()
    }

    private func connect() {
        guard enabled, conn == nil else { return }
        guard let ep = targetEndpoint() else {
            phase = .searching
            if selection.hasPrefix("pc:") {
                status = T("正在找「{0}」……", "Looking for {0}…", String(selection.dropFirst(3)))
            } else if pcs.isEmpty {
                status = T("正在找电脑……", "Looking for your PC…")
            } else {
                status = T("请在下面选一台电脑", "Pick a PC below")
            }
            return
        }
        phase = .connecting
        status = T("正在连接……", "Connecting…")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        let c = NWConnection(to: ep, using: params)
        conn = c
        let cid = ObjectIdentifier(c)
        netQueue.async {
            self.activeConn = cid
            self.header = Data()
            self.gotHeader = false
            self.carry = Data()
        }
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self = self, let c = c else { return }
            switch state {
            case .ready:
                // 告诉电脑：想要的采样率（= 当前输出设备的硬件采样率）+ 本机名字
                let want = Self.wantedRate()
                var hello = Data("HRQ1".utf8)
                withUnsafeBytes(of: UInt32(want).littleEndian) { hello.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt16(2).littleEndian) { hello.append(contentsOf: $0) }
                let name = Data(self.deviceLabel.utf8.prefix(200))
                hello.append(contentsOf: Array("HRN1".utf8))
                hello.append(UInt8(name.count))
                hello.append(name)
                c.send(content: hello, completion: .contentProcessed { _ in })
                self.lastData.set(CACurrentMediaTime())
                DispatchQueue.main.async {
                    guard self.conn === c else { return }
                    self.requestedRate = Double(want)
                    self.connectedAt = Date()
                    self.connected = true
                    self.status = T("已连接，等电脑出声", "Connected")
                    self.log(T("已连接电脑", "Connected to PC"))
                }
                self.receive(on: c)
            case .waiting(let err):
                DispatchQueue.main.async {
                    guard self.conn === c else { return }
                    self.status = Self.describe(err)
                    self.log(T("连不上：", "Can't connect: ") + Self.describe(err))
                    self.dropAndRetry(c)
                }
            case .failed(let err):
                DispatchQueue.main.async {
                    guard self.conn === c else { return }
                    self.status = Self.describe(err)
                    self.log(T("连接断开：", "Disconnected: ") + Self.describe(err))
                    self.dropAndRetry(c)
                }
            default:
                break
            }
        }
        c.start(queue: netQueue)
    }

    private func dropAndRetry(_ c: NWConnection) {
        guard conn === c else { return }
        conn = nil
        connected = false
        headerReceived = false
        phase = .connecting
        netQueue.async { c.cancel() }
        ring.reset()
        guard enabled else { return }
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.connect() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak c] data, _, isComplete, error in
            guard let self = self, let c = c else { return }
            // 旧连接残留的数据直接丢掉，免得和新连接的数据混在一起
            if let data = data, !data.isEmpty, self.activeConn == ObjectIdentifier(c) {
                self.lastData.set(CACurrentMediaTime())
                self.handle(data)
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard self.conn === c else { return }
                    self.status = T("电脑那边断开了，重连中……", "PC disconnected, reconnecting…")
                    self.log(T("电脑断开了连接", "PC closed the connection"))
                    self.dropAndRetry(c)
                }
                return
            }
            self.receive(on: c)
        }
    }

    /// netQueue 上调用
    private func handle(_ data: Data) {
        var payload = data
        if !gotHeader {
            header.append(data)
            guard header.count >= 12 else { return }
            let magic = String(decoding: header.prefix(4), as: UTF8.self)
            let sr = header.withUnsafeBytes { raw -> UInt32 in raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let ch = header.withUnsafeBytes { raw -> UInt16 in raw.loadUnaligned(fromByteOffset: 8, as: UInt16.self) }
            let bits = header.withUnsafeBytes { raw -> UInt16 in raw.loadUnaligned(fromByteOffset: 10, as: UInt16.self) }
            guard magic == "HRLY", ch == 2, bits == 16, (8000...192_000).contains(sr) else {
                header = Data()
                DispatchQueue.main.async {
                    if let c = self.conn { self.dropAndRetry(c) }
                    self.status = T("对方不是「声桥」，或版本不对", "Not a SoundBridge server")
                }
                return
            }
            gotHeader = true
            payload = header.subdata(in: 12..<header.count)
            header = Data()
            let rate = Double(UInt32(littleEndian: sr))
            DispatchQueue.main.async {
                // 每次（重新）连上都把播放整个重建一遍，和手动关开一次效果一样
                self.output.restart(sampleRate: rate)
                self.applyLatency()
                self.headerReceived = true
                self.phase = .listening
                self.status = T("正在收听", "Listening")
            }
        }
        if !carry.isEmpty {
            carry.append(payload)
            payload = carry
            carry = Data()
        }
        let frames = payload.count / 4
        if frames > 0 {
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                // Data 可能不是 2 字节对齐，复制到对齐的缓冲里再读
                let samples = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
                defer { samples.deallocate() }
                memcpy(samples, base, frames * 4)
                ring.write(interleaved: samples, frames: frames)
            }
        }
        let rest = payload.count - frames * 4
        if rest > 0 { carry = payload.suffix(rest) }
    }

    // MARK: - 延迟

    static func wantedRate() -> Int {
        let hw = AVAudioSession.sharedInstance().sampleRate
        if hw < 8000 { return 48000 }
        return Int(min(hw, 48000).rounded())
    }

    /// 在主线程取好，网络线程直接用
    private let deviceLabel: String = UIDevice.current.name

    /// 实际生效的目标延迟
    var effectiveLatencyMs: Double { preset == .auto ? max(autoTargetMs, preset.baseMs) : preset.baseMs }

    private func applyLatency() {
        let sr = output.sampleRate
        let target = effectiveLatencyMs
        // 目标之上再留 max(目标, 300ms) 的余量，网络突发时少丢数据
        ring.setTarget(frames: Int(target / 1000.0 * sr), headroom: Int(max(target, 300) / 1000.0 * sr))
    }

    /// 自动模式：有断续就把延迟加大一点；连续 20 秒稳定就慢慢降回去
    private func adaptLatency(underrunsNow: Int) {
        let delta = underrunsNow - lastUnderruns
        lastUnderruns = underrunsNow
        guard preset == .auto, phase == .listening, let t = connectedAt, Date().timeIntervalSince(t) > 2 else {
            calmTicks = 0
            return
        }
        if delta > 0 {
            autoTargetMs = min(600, max(autoTargetMs, preset.baseMs) + 30 * Double(min(delta, 3)))
            calmTicks = 0
            applyLatency()
        } else {
            calmTicks += 1
            if calmTicks >= 40 && autoTargetMs > preset.baseMs {
                autoTargetMs = max(preset.baseMs, autoTargetMs - 10)
                calmTicks = 30 // 之后每 5 秒降 10ms
                applyLatency()
            }
        }
    }

    /// 输出设备换了（比如助听器 ↔ 扬声器），采样率跟着变，就重连让电脑按新采样率发
    private func checkRouteRate() {
        let hw = output.hardwareRate
        guard connected, headerReceived, requestedRate > 0, output.sampleRate == requestedRate, hw >= 8000,
              abs(min(hw, 48000) - output.sampleRate) > 1 else {
            rateMismatchTicks = 0
            return
        }
        rateMismatchTicks += 1
        if rateMismatchTicks >= 4 {
            rateMismatchTicks = 0
            reconnectNow(reason: T("输出设备变了（\(Int(hw)) Hz），重新连接", "Output changed (\(Int(hw)) Hz); reconnecting"))
        }
    }

    /// 电脑端（1.2+）静音时也会持续发数据，所以 2.5 秒收不到任何数据 = 连接假死，直接重连
    private func checkStall() {
        guard connected, headerReceived else { return }
        let silent = CACurrentMediaTime() - lastData.get()
        if silent > 2.5 {
            reconnectNow(reason: T("\(Int(silent)) 秒没收到电脑的数据，自动重连", "No data for \(Int(silent)) s; reconnecting"))
        }
    }

    // MARK: - 状态

    private func refreshStats() {
        output.watchdog()
        let s = ring.stats
        adaptLatency(underrunsNow: s.underruns)
        checkRouteRate()
        checkStall()
        bufferMs = Int(Double(s.frames) / output.sampleRate * 1000)
        underruns = s.underruns
        routeName = output.routeDescription
        if interrupted != output.interrupted { interrupted = output.interrupted }
        let state: String
        if output.interrupted { state = T("被其他声音打断", "interrupted") }
        else if output.isRunning { state = T("播放中", "running") }
        else { state = T("未运行", "stopped") }
        var d = T("播放：\(state) · 自动重启 \(output.rebuilds) 次\n", "Audio: \(state) · restarts \(output.rebuilds)\n")
        d += T("缓冲：\(bufferMs) ms（目标 \(Int(effectiveLatencyMs)) ms）· 卡顿 \(s.underruns) 次 · 丢弃 \(s.drops) 次\n",
               "Buffer: \(bufferMs) ms (target \(Int(effectiveLatencyMs)) ms) · underruns \(s.underruns) · drops \(s.drops)\n")
        d += T("输出：\(output.routeDescription)（\(Int(output.hardwareRate)) Hz）· 电脑发送 \(Int(output.sampleRate)) Hz",
               "Output: \(output.routeDescription) (\(Int(output.hardwareRate)) Hz) · stream \(Int(output.sampleRate)) Hz")
        if !status.isEmpty { d += "\n" + T("状态：", "Status: ") + status }
        if !output.lastError.isEmpty { d += "\n" + T("错误：", "Error: ") + output.lastError }
        diagnostics = d
    }

    private func refreshMeter() {
        let p = ring.takePeak()
        let target: Float = p <= 0.0001 ? 0 : min(1, max(0, (20 * log10(p) + 50) / 50))
        let v = max(target, level * 0.85)
        if abs(v - level) > 0.01 || (v == 0 && level != 0) { level = v < 0.01 ? 0 : v }
    }

    private func log(_ msg: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        events.insert("\(f.string(from: Date()))  \(msg)", at: 0)
        if events.count > 30 { events.removeLast(events.count - 30) }
    }

    // MARK: - 锁屏控制

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.enabled = true; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.enabled = false; return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.enabled.toggle()
            return .success
        }
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
    }

    /// 灵动岛 / 锁屏的封面：App 图标同款（iOS 不让直接读 AppIcon，所以单独放了一张）
    private static let artwork: UIImage? = UIImage(named: "NowPlaying")

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        // 标题 = 电脑名（连上后）或「电脑的声音」，副标题 = App 名 / 已暂停
        let pcName: String = {
            if selection.hasPrefix("pc:") { return String(selection.dropFirst(3)) }
            if selection.hasPrefix("ip:") { return T("电脑的声音", "PC Audio") }
            return T("电脑的声音", "PC Audio")
        }()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: pcName,
            MPMediaItemPropertyArtist: enabled ? T("声桥", "SoundBridge") : T("声桥 · 已暂停", "SoundBridge · Paused"),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: enabled ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let img = Self.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
        if #available(iOS 13.0, *) { center.playbackState = enabled ? .playing : .paused }
    }

    private static func describe(_ err: NWError) -> String {
        switch err {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return T("电脑上的「声桥」没打开", "SoundBridge isn't running on the PC")
            case .ETIMEDOUT: return T("连接超时：手机和电脑在同一个网络吗？", "Timed out — are the phone and PC on the same network?")
            case .EHOSTUNREACH, .ENETUNREACH:
                return T("找不到电脑：检查 Wi-Fi，或在「设置」里给本 App 打开「本地网络」权限",
                         "Can't reach the PC — check Wi-Fi, or allow Local Network for this app in Settings")
            default: return "\(code)"
            }
        default:
            return "\(err)"
        }
    }
}
