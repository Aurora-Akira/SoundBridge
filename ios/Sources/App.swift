import SwiftUI
import AVFoundation

@main
struct SoundBridgeApp: App {
    @StateObject private var client = RelayClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var client: RelayClient
    @AppStorage("onboarded") private var onboarded = false
    @State private var showManual = false
    @State private var showDetails = false

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                PowerButton(phase: client.phase, interrupted: client.interrupted, level: client.level) {
                    if client.interrupted && client.enabled {
                        client.resumeAfterInterruption()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { client.enabled.toggle() }
                    }
                }
                .padding(.top, 6)
                statusBlock
                pcCard
                latencyCard
                languageCard
                detailsCard
                Text(T("版本 {0}", "Version {0}", appVersion))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .id(client.languageOverride) // 换语言时整页重画
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showManual) { ManualIPSheet().environmentObject(client) }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView { onboarded = true }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(T("声桥", "SoundBridge"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(T("把电脑的声音，送进你的助听器或耳机", "Hear your PC through your hearing aids or headphones"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 28)
    }

    // 按钮下面的大字状态 + 输出设备
    private var statusBlock: some View {
        VStack(spacing: 10) {
            Text(headline)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let sub = subline {
                Text(sub)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                Image(systemName: routeIcon)
                Text(T("声音从：", "Playing on: ") + client.routeName)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    private var headline: String {
        if client.interrupted && client.enabled { return T("被其他声音打断了", "Interrupted") }
        switch client.phase {
        case .off: return T("点一下，开始收听", "Tap to start listening")
        case .searching: return T("正在找电脑……", "Looking for your PC…")
        case .connecting: return T("正在连接电脑……", "Connecting…")
        case .listening: return T("正在收听电脑的声音", "Listening to your PC")
        }
    }

    private var subline: String? {
        if client.interrupted && client.enabled { return T("来电或其他 App 在放声音。点按钮恢复。", "A call or another app took over audio. Tap the button to resume.") }
        switch client.phase {
        case .off: return T("可以锁屏，会在后台一直听。", "Works with the screen locked.")
        case .searching:
            return client.pcs.isEmpty
                ? T("请确认电脑上开着「声桥」，并且手机和电脑连的是同一个网络。", "Make sure SoundBridge is open on your PC and both are on the same network.")
                : T("在下面选一台电脑。", "Pick a PC below.")
        case .connecting: return client.status.isEmpty ? nil : client.status
        case .listening: return nil
        }
    }

    private var routeIcon: String {
        _ = client.routeName // 输出变化时刷新
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "speaker.slash" }
        if port.portType == .builtInSpeaker { return "speaker.wave.2.fill" }
        if port.portType == .builtInReceiver { return "iphone" }
        let r = port.portName.lowercased()
        if r.contains("airpods") { return "airpods" }
        if r.contains("hearing") || r.contains("助听") || r.contains("助聽") || r.contains("hör") || r.contains("補聴") || r.contains("보청") || r.contains("audífono") || r.contains("auditiv") {
            return "ear"
        }
        return "headphones"
    }

    // 语言
    private var languageCard: some View {
        Card(title: T("语言", "Language"), icon: "globe") {
            Picker(T("语言", "Language"), selection: $client.languageOverride) {
                Text(T("跟随系统", "System default")).tag("")
                ForEach(Lang.languages) { l in Text(l.name).tag(l.code) }
            }
            .pickerStyle(.menu)
        }
    }

    // 电脑列表
    private var pcCard: some View {
        Card(title: T("电脑", "PC"), icon: "desktopcomputer") {
            if client.scanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(T("正在扫描局域网找电脑……", "Scanning the local network for your PC…"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if client.pcs.isEmpty {
                Text(T("还没发现电脑。请在电脑上打开「声桥」。", "No PC found yet. Open SoundBridge on your computer."))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(client.pcs) { pc in
                Button { client.choose(pc) } label: {
                    HStack {
                        Text(pc.name).foregroundColor(.primary)
                        Spacer()
                        if client.selection == pc.selectionKey {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
            // 手动填的 IP（不在列表里时单独显示）
            if client.selection.hasPrefix("ip:"), !client.pcs.contains(where: { $0.selectionKey == client.selection }) {
                HStack {
                    Text(String(client.selection.dropFirst(3))).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                }
                .padding(.vertical, 6)
            }
            HStack {
                Button { client.scanSubnet() } label: {
                    Label(T("重新搜索", "Search again"), systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .disabled(client.scanning)
                Spacer()
                Button { showManual = true } label: {
                    Label(T("手动输入地址", "Enter address"), systemImage: "keyboard")
                        .font(.footnote)
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
    }

    // 延迟档位
    private var latencyCard: some View {
        Card(title: T("延迟", "Delay"), icon: "timer") {
            Picker("", selection: $client.preset) {
                ForEach(LatencyPreset.allCases) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.segmented)
            Text(latencyHint)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var latencyHint: String {
        switch client.preset {
        case .auto: return T("推荐。网络不好时自动多缓冲一点，声音不断。当前约 {0} 毫秒。",
                             "Recommended. Buffers more when Wi-Fi is shaky. Now about {0} ms.", Int(client.effectiveLatencyMs))
        case .low: return T("声音最跟手，但网络不好时容易断断续续。", "Most responsive, but may stutter on weak Wi-Fi.")
        case .medium: return T("比较稳，看视频基本跟得上。", "Steady; fine for most videos.")
        case .high: return T("最稳，适合网络差的时候听歌、听课。", "Most stable; good for music or lectures on weak Wi-Fi.")
        }
    }

    // 详细信息（排查问题用）
    private var detailsCard: some View {
        Card(title: nil, icon: nil) {
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    if !client.diagnostics.isEmpty {
                        Text(client.diagnostics)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if !client.events.isEmpty {
                        Text(T("最近发生的事", "Recent events"))
                            .font(.caption.weight(.semibold))
                        ForEach(Array(client.events.prefix(12).enumerated()), id: \.offset) { _, e in
                            Text(e).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                Label(T("详细信息", "Details"), systemImage: "info.circle")
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - 大按钮

struct PowerButton: View {
    let phase: Phase
    let interrupted: Bool
    let level: Float
    let action: () -> Void
    @State private var spin = false

    private var colors: [Color] {
        if interrupted && phase != .off { return [Color.orange, Color.orange.opacity(0.75)] }
        switch phase {
        case .off: return [Color(.systemGray3), Color(.systemGray2)]
        case .searching, .connecting: return [Color.orange, Color(red: 1, green: 0.62, blue: 0.2)]
        case .listening: return [Color(red: 0.15, green: 0.75, blue: 0.45), Color(red: 0.1, green: 0.6, blue: 0.4)]
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // 声音波纹：跟着音量变大
                if phase == .listening {
                    Circle()
                        .fill(colors[0].opacity(0.18))
                        .frame(width: 200, height: 200)
                        .scaleEffect(1.0 + CGFloat(level) * 0.28)
                        .animation(.easeOut(duration: 0.12), value: level)
                    Circle()
                        .fill(colors[0].opacity(0.12))
                        .frame(width: 200, height: 200)
                        .scaleEffect(1.0 + CGFloat(level) * 0.5)
                        .animation(.easeOut(duration: 0.2), value: level)
                }
                // 连接中：转圈
                if phase == .searching || phase == .connecting {
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 208, height: 208)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                        .onDisappear { spin = false }
                }
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 180, height: 180)
                    .shadow(color: colors[0].opacity(0.45), radius: 18, y: 8)
                VStack(spacing: 6) {
                    Image(systemName: phase == .off ? "power" : (phase == .listening ? "waveform" : "antenna.radiowaves.left.and.right"))
                        .font(.system(size: 50, weight: .semibold))
                    Text(phase == .off ? T("开始", "Start") : T("停止", "Stop"))
                        .font(.headline)
                }
                .foregroundColor(.white)
            }
            .frame(width: 270, height: 270)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phase == .off ? T("开始收听", "Start listening") : T("停止收听", "Stop listening"))
    }
}

// MARK: - 卡片

struct Card<Content: View>: View {
    let title: String?
    let icon: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = title {
                Label(title, systemImage: icon ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: - 手动填 IP

struct ManualIPSheet: View {
    @EnvironmentObject var client: RelayClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text(T("电脑上的「声桥」窗口里写着这个地址，例如 192.168.1.23。",
                                       "The address is shown in the SoundBridge window on your computer, e.g. 192.168.1.23."))) {
                    TextField(T("电脑地址", "PC address"), text: $client.manualHost)
                        .keyboardType(.decimalPad)
                        .disableAutocorrection(true)
                        .font(.title3.monospacedDigit())
                }
            }
            .navigationTitle(T("手动输入地址", "Enter address"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("连接", "Connect")) {
                        client.useManualHost()
                        dismiss()
                    }
                    .disabled(client.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 首次引导

struct OnboardingView: View {
    let done: () -> Void
    @State private var page = 0

    private struct Step { let icon: String; let title: String; let text: String }
    private let steps: [Step] = [
        Step(icon: "desktopcomputer",
             title: T("1. 电脑上装「声桥」", "1. Install it on your PC"),
             text: T("在 Windows 电脑上打开「声桥」程序，它会把电脑的声音发出来。",
                     "Run SoundBridge on your Windows PC. It sends out your PC's sound.")),
        Step(icon: "wifi",
             title: T("2. 连同一个网络", "2. Same network"),
             text: T("手机连 Wi-Fi，电脑连同一个路由器（插网线也行）。第一次打开时，请允许访问「本地网络」。",
                     "Put your iPhone and PC on the same router (Wi-Fi or cable). Allow Local Network access when asked.")),
        Step(icon: "ear",
             title: T("3. 点大按钮", "3. Tap the big button"),
             text: T("电脑上的声音就会从你的助听器或耳机里出来。锁屏也能一直听。",
                     "Your PC's sound now plays through your hearing aids or headphones — even with the screen locked.")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(steps.indices, id: \.self) { i in
                    VStack(spacing: 24) {
                        Spacer()
                        Image(systemName: steps[i].icon)
                            .font(.system(size: 76, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 150, height: 150)
                            .background(Circle().fill(Color.accentColor.opacity(0.12)))
                        Text(steps[i].title)
                            .font(.title2.bold())
                        Text(steps[i].text)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < steps.count - 1 { withAnimation { page += 1 } } else { done() }
            } label: {
                Text(page < steps.count - 1 ? T("下一步", "Next") : T("开始使用", "Get started"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
