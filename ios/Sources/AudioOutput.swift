import AVFoundation

/// 用 AVAudioEngine 把环形缓冲里的声音放出来。系统会自动送到当前输出（助听器 / 耳机 / 扬声器）。
/// 只在主线程调用。卡住时由 watchdog() 整个重建引擎。
final class AudioOutput {
    let ring: RingBuffer
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var sampleRate: Double = 48000
    /// 用户希望它在跑（被来电打断、换耳机后自动恢复）
    private(set) var shouldRun = false
    private(set) var lastError = ""
    private(set) var rebuilds = 0
    var onLog: ((String) -> Void)?

    private var lastRenderCalls = -1
    private var stalledTicks = 0
    private(set) var interrupted = false

    init(ring: RingBuffer) {
        self.ring = ring
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(onMediaReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        nc.addObserver(self, selector: #selector(onRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        observeEngine()
    }

    var isRunning: Bool { engine.isRunning }

    /// 当前声音实际从哪出
    var routeDescription: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.isEmpty { return T("无输出", "No output") }
        return outs.map { port -> String in
            switch port.portType {
            case .builtInSpeaker: return T("手机扬声器", "iPhone speaker")
            case .builtInReceiver: return T("听筒", "Receiver")
            case .headphones: return T("有线耳机", "Headphones")
            default: return port.portName
            }
        }.joined(separator: T("、", ", "))
    }

    var hardwareRate: Double { AVAudioSession.sharedInstance().sampleRate }

    /// 新连接拿到格式头时调用：按新采样率整个重建播放
    func restart(sampleRate sr: Double) {
        guard shouldRun else { sampleRate = sr; return }
        sampleRate = sr
        interrupted = false
        stalledTicks = 0
        lastRenderCalls = -1
        ring.reset()
        rebuild(reason: nil)
    }

    func start() {
        shouldRun = true
        interrupted = false
        stalledTicks = 0
        lastRenderCalls = -1
        rebuild(reason: nil)
    }

    func stop() {
        shouldRun = false
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 每 0.5 秒由界面定时器调用：引擎没在跑、或者渲染回调不再被调用，就重建
    func watchdog() {
        // 被其他 App / 来电打断时不抢回来，等系统通知打断结束（或用户手动关开一次）
        guard shouldRun, !interrupted else { return }
        let calls = ring.stats.renderCalls
        if !engine.isRunning || calls == lastRenderCalls {
            stalledTicks += 1
        } else {
            stalledTicks = 0
        }
        lastRenderCalls = calls
        if stalledTicks >= 2 { // 约 1 秒没动静
            stalledTicks = 0
            rebuild(reason: engine.isRunning ? T("播放卡住，自动重启", "Audio stalled; restarting") : T("播放停了，自动重启", "Audio stopped; restarting"))
        }
    }

    /// 丢掉旧引擎，新建一个，接上数据源并启动
    private func rebuild(reason: String?) {
        guard shouldRun else { return }
        if let reason = reason {
            rebuilds += 1
            onLog?(reason)
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            fail(T("音频启动失败：", "Audio session failed: ") + error.localizedDescription)
            return
        }

        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.stop()
        if let old = source { engine.detach(old) }
        source = nil
        engine = AVAudioEngine()
        observeEngine()

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 2, interleaved: false) else {
            fail(T("音频格式无效", "Invalid audio format") + " (\(Int(sampleRate)) Hz)")
            return
        }
        let ring = self.ring
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            if bufs.count >= 2,
               let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
               let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) {
                ring.read(left: l, right: r, frames: n)
            } else if bufs.count == 1, let p = bufs[0].mData?.assumingMemoryBound(to: Float.self) {
                // 万一给的是单个交错缓冲：先读到临时区再交错写入
                let tmpL = UnsafeMutablePointer<Float>.allocate(capacity: n)
                let tmpR = UnsafeMutablePointer<Float>.allocate(capacity: n)
                ring.read(left: tmpL, right: tmpR, frames: n)
                let ch = Int(bufs[0].mNumberChannels)
                for i in 0..<n {
                    if ch >= 2 { p[2 * i] = tmpL[i]; p[2 * i + 1] = tmpR[i] } else { p[i] = (tmpL[i] + tmpR[i]) * 0.5 }
                }
                tmpL.deallocate()
                tmpR.deallocate()
            }
            return noErr
        }
        engine.attach(node)
        let mixer = engine.mainMixerNode
        engine.connect(node, to: mixer, format: fmt)
        // 显式把混音器接到输出，用硬件格式
        let outFmt = engine.outputNode.inputFormat(forBus: 0)
        if outFmt.sampleRate > 0 && outFmt.channelCount > 0 {
            engine.connect(mixer, to: engine.outputNode, format: outFmt)
        }
        mixer.outputVolume = 1.0
        source = node

        do {
            engine.prepare()
            try engine.start()
            lastError = ""
        } catch {
            fail(T("播放启动失败：", "Playback failed: ") + error.localizedDescription)
        }
    }

    private func fail(_ msg: String) {
        lastError = msg
        onLog?(msg)
    }

    private func observeEngine() {
        NotificationCenter.default.addObserver(self, selector: #selector(onConfigChange(_:)),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
    }

    @objc private func onInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .ended {
                self.interrupted = false
                self.rebuild(reason: T("打断结束，恢复播放", "Interruption ended; resuming"))
            } else {
                self.interrupted = true
                self.onLog?(T("被来电或其他 App 的声音打断，点一下按钮可恢复", "Interrupted by a call or another app; tap the button to resume"))
            }
        }
    }

    @objc private func onConfigChange(_ n: Notification) {
        DispatchQueue.main.async { self.rebuild(reason: T("输出设备变化，重新接上", "Output changed; restarting audio")) }
    }

    @objc private func onRouteChange(_ n: Notification) {
        DispatchQueue.main.async { self.onLog?(T("输出：", "Output: ") + self.routeDescription) }
    }

    @objc private func onMediaReset(_ n: Notification) {
        DispatchQueue.main.async { self.rebuild(reason: T("系统音频服务重置，重新启动", "Media services reset; restarting")) }
    }
}
