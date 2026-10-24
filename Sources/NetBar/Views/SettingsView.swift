import AppKit
import ServiceManagement
import SwiftUI

/// Independent settings window; connection forms remain drafts until saved.
struct SettingsView: View {
    let coordinator: MonitorCoordinator
    @ObservedObject private var draft: SettingsDraft
    @State private var tab = 0
    init(coordinator: MonitorCoordinator) { self.coordinator = coordinator; draft = coordinator.settingsDraft }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("设置分类", selection: $tab) {
                Text("通用").tag(0)
                if DistributionFlavor.current == .directFull { Text("Clash 连接").tag(1) }
                Text("IP 检测").tag(2)
                Text("服务器").tag(3)
            }.pickerStyle(.segmented).labelsHidden()
            if tab == 0 { GeneralSettingsTab(coordinator: coordinator) }
            else if tab == 3 { VPSSettingsTab(coordinator: coordinator) }
            else {
                Form {
                    if tab == 1 {
                        Section {
                            TextField("Socket 路径（留空自动发现）", text: $draft.values.socket)
                            TextField("Controller URL", text: $draft.values.url)
                            SecureField("Secret", text: $draft.values.secret)
                        } header: { Text("Mihomo / Clash Verge") } footer: {
                            Text("留空自动发现。自定义 Socket 优先，自定义 HTTP 只读。测试当前草稿，不改变已保存连接。").font(.system(size: 11))
                        }
                    } else {
                        Section {
                            Toggle("启用出口 IP 检测", isOn: $draft.values.ipEnabled)
                            Picker("检测版本", selection: $draft.values.ipVersion) { ForEach(IPVersion.allCases) { Text($0.displayName).tag($0) } }
                            Picker("自动刷新", selection: $draft.values.ipMinutes) { ForEach([5.0,15,30,60], id: \.self) { Text("\(Int($0)) 分钟").tag($0) } }
                            Toggle("隐藏 Wi-Fi 名称", isOn: $draft.values.hideSSID)
                            SecureField("ping0 API Key", text: $draft.values.apiKey)
                        } footer: {
                            Text("检测会把当前公网出口 IP 发送给 ping0.cc；Key 留空使用免费链路。字段修改仅保留为草稿。").font(.system(size: 11))
                        }
                    }
                    if let result = draft.visibleTestResult { Text(result).font(.system(size: 12)).textSelection(.enabled) }
                    if let message = draft.message { Text(message).font(.system(size: 12)).foregroundColor(.secondary) }
                }.formStyle(.grouped)
                HStack {
                    Text(draft.hasChanges ? "有未保存的修改" : "与已保存设置一致").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button("取消修改") { draft.discard() }.disabled(!draft.hasChanges)
                    Button(draft.isTesting ? "正在测试…" : "测试连接") { if tab == 1 { draft.testProxy() } else { draft.testIP() } }.disabled(draft.isTesting)
                    Button("保存") { draft.save(coordinator: coordinator) }.buttonStyle(.borderedProminent).disabled(!draft.hasChanges || draft.isTesting)
                }
            }
        }.padding(16).tint(PopoverVisualStyle.accent)
        .onAppear { draft.loadIfClean() }
    }
}

// MARK: - 通用设置

private struct GeneralSettingsTab: View {
    let coordinator: MonitorCoordinator
    @State private var launchAtLogin = StartupSetting.isEnabled
    @State private var suppressLaunchAtLoginChange = false
    @State private var startupError: String?
    @State private var refreshInterval: Double = AppConfig.shared.refreshInterval

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .disabled(MonitorCoordinator.isVisualCaptureRun)
                    .onChange(of: launchAtLogin) { newValue in
                        guard !suppressLaunchAtLoginChange else { return }
                        guard StartupSetting.setEnabled(newValue) else {
                            Log.config.error("开机自启设置失败")
                            startupError = "开机启动设置未生效，请检查系统的登录项设置。"
                            suppressLaunchAtLoginChange = true
                            launchAtLogin = StartupSetting.isEnabled
                            DispatchQueue.main.async {
                                suppressLaunchAtLoginChange = false
                            }
                            return
                        }
                    }

                if let startupError { Text(startupError).foregroundColor(.orange) }
                HStack {
                    Text("网速刷新间隔")
                    Spacer()
                    Picker("", selection: $refreshInterval) {
                        Text("1 秒").tag(1.0)
                        Text("2 秒").tag(2.0)
                        Text("3 秒").tag(3.0)
                        Text("5 秒").tag(5.0)
                    }
                    .frame(width: 100)
                    .onChange(of: refreshInterval) { newValue in
                        AppConfig.shared.refreshInterval = newValue
                        coordinator.applyRefreshInterval(newValue)
                    }
                }
            } header: {
                Text("基本")
            }

            Section {
                HStack {
                    Text("版本类型")
                    Spacer()
                    Text(DistributionFlavor.current.displayName)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("构建")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            launchAtLogin = StartupSetting.isEnabled
            refreshInterval = AppConfig.shared.refreshInterval
        }
    }
}

private enum StartupSetting {
    static var isEnabled: Bool {
        if DistributionFlavor.current.usesLaunchAgentStartup {
            return LaunchAgentManager.isEnabled
        }
        return SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if DistributionFlavor.current.usesLaunchAgentStartup {
            return LaunchAgentManager.setEnabled(enabled)
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.config.error("SMAppService 开机自启设置失败: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - VPS 设置

struct VPSSettingsTab: View {
    let coordinator: MonitorCoordinator
    @State private var configs: [AppConfig.VPSConfig] = AppConfig.shared.vpsConfigs
    @State private var editingConfig: AppConfig.VPSConfig?
    @State private var testingIDs: Set<String> = []
    @State private var testMessages: [String: String] = [:]
    @State private var deletingConfig: AppConfig.VPSConfig?
    @State private var saveError: String?
    @ObservedObject private var monitor: VPSTrafficMonitor
    init(coordinator: MonitorCoordinator) { self.coordinator = coordinator; monitor = coordinator.vpsTrafficMonitor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let saveError { Text(saveError).foregroundColor(.orange).padding(.horizontal, 18) }

            if configs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                    ForEach(configs) { config in
                        VStack(alignment: .leading, spacing: 8) {
                            serverRow(config)
                            if let traffic = monitor.vpsList.first(where: { $0.id == config.id }) { VPSTrafficCard(vps: traffic) }
                            else { Text("尚未取得数据").font(.system(size: 12)).foregroundColor(.secondary) }
                        }.padding(12).popoverSurface()
                    }
                    }.padding(.horizontal, 18).padding(.bottom, 12)
                }
            }

            Divider()
            bottomBar
        }
        .alert("删除服务器配置？", isPresented: Binding(get: { deletingConfig != nil }, set: { if !$0 { deletingConfig = nil } })) {
            Button("取消", role: .cancel) { deletingConfig = nil }
            Button("删除", role: .destructive) {
                if let target = deletingConfig {
                    let candidate = configs.filter { $0.id != target.id }
                    _ = persist(candidate)
                }
                deletingConfig = nil
            }
        } message: { Text("将删除“\(deletingConfig?.name ?? "")”的连接配置。其他服务器保持原样。") }
        .sheet(item: $editingConfig) { config in
            VPSEditSheet(config: config) { updated in
                var candidate = configs
                if let idx = candidate.firstIndex(where: { $0.id == updated.id }) { candidate[idx] = updated }
                else { candidate.append(updated) }
                if persist(candidate) { editingConfig = nil; return true }
                return false
            } onCancel: {
                editingConfig = nil
            }
        }
        .onAppear {
            configs = AppConfig.shared.vpsConfigs
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("服务器管理")
                    .font(.system(size: 15, weight: .semibold))
                Text("连接 3X-UI 面板，查看流量、额度与客户端。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                coordinator.reloadVPSConfigsAndRefresh()
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
        }
        .padding([.top, .horizontal], 18)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.badge.plus")
                .font(.system(size: 38, weight: .regular))
                .foregroundColor(.secondary.opacity(0.55))
            Text("还没有服务器")
                .font(.system(size: 15, weight: .semibold))
            Text("点击添加服务器，粘贴 3X-UI 面板地址并测试连接。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button {
                editingConfig = newConfig()
            } label: {
                Label("添加服务器", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                editingConfig = newConfig()
            } label: {
                Label("添加服务器", systemImage: "plus")
            }
            Spacer()
            Text("\(configs.count) 台服务器")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func serverRow(_ config: AppConfig.VPSConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(config.panelURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let message = testMessages[config.id] {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(message == ConnectionTestResult.success.message ? .green : .orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button {
                testServer(config)
            } label: {
                if testingIDs.contains(config.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "checkmark.circle")
                }
            }
            .buttonStyle(.borderless)
            .help("测试连接")
            .accessibilityLabel("测试服务器 " + config.name)

            Button {
                editingConfig = config
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")
            .accessibilityLabel("编辑服务器 " + config.name)

            Button {
                deletingConfig = config
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("删除")
            .accessibilityLabel("删除服务器 " + config.name)
        }
        .padding(.vertical, 6)
    }

    private func persist(_ candidate: [AppConfig.VPSConfig]) -> Bool {
        guard AppConfig.shared.vpsConfigs == configs else {
            saveError = "服务器配置已在其他位置改变，请重新打开此页面后再试。"; return false
        }
        AppConfig.shared.vpsConfigs = candidate
        guard AppConfig.shared.vpsConfigs == candidate else {
            saveError = "配置未能保存，原记录与输入已保留。"; return false
        }
        configs = candidate; saveError = nil; coordinator.reloadVPSConfigsAndRefresh(); return true
    }
    private func testServer(_ config: AppConfig.VPSConfig) {
        guard !testingIDs.contains(config.id) else { return }
        guard !config.password.isEmpty else {
            testMessages[config.id] = VPSConnectionError.passwordRequired.localizedDescription
            return
        }

        testingIDs.insert(config.id)
        Task {
            let result = await ThreeXUIClient().testConnection(config: config, password: config.password)
            testingIDs.remove(config.id)
            testMessages[config.id] = result.message
            if result.success {
                coordinator.reloadVPSConfigsAndRefresh()
            }
        }
    }

    private func newConfig() -> AppConfig.VPSConfig {
        AppConfig.VPSConfig(
            id: UUID().uuidString,
            name: "",
            provider: .threeXUI,
            host: "",
            port: 443,
            basePath: "",
            username: "",
            useTLS: true,
            allowSelfSignedCertificate: false
        )
    }
}

// MARK: - VPS 编辑表单

private struct VPSEditSheet: View {
    let onSave: (AppConfig.VPSConfig) -> Bool
    let onCancel: () -> Void

    @State private var config: AppConfig.VPSConfig
    @State private var displayName: String
    @State private var panelURL: String
    @State private var username: String
    @State private var password: String
    @State private var allowSelfSignedCertificate: Bool
    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult?
    @State private var hasSuccessfulTest = false

    init(
        config: AppConfig.VPSConfig,
        onSave: @escaping (AppConfig.VPSConfig) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _config = State(initialValue: config)
        _displayName = State(initialValue: config.name)
        _panelURL = State(initialValue: config.host.isEmpty ? "" : config.panelURL)
        _username = State(initialValue: config.username)
        _password = State(initialValue: config.password)
        _allowSelfSignedCertificate = State(initialValue: config.allowSelfSignedCertificate)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("显示名称", text: $displayName)
                        .onChange(of: displayName) { _ in resetTestState() }
                    TextField("面板地址", text: $panelURL)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: panelURL) { _ in resetTestState() }
                    TextField("用户名", text: $username)
                        .onChange(of: username) { _ in resetTestState() }
                    SecureField("密码", text: $password)
                        .onChange(of: password) { _ in resetTestState() }
                    Toggle("允许自签证书", isOn: $allowSelfSignedCertificate)
                        .onChange(of: allowSelfSignedCertificate) { _ in resetTestState() }
                } footer: {
                    Text("面板地址可直接粘贴完整 3X-UI URL，例如 https://example.com:2053/panel-path。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let testResult {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: testResult.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(testResult.success ? .green : .orange)
                            Text(testResult.message)
                                .foregroundColor(testResult.success ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    runConnectionTest()
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 58)
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(isTesting || !hasRequiredFields)

                Button("保存") {
                    do {
                        let updated = try buildConfig()
                        updated.password = password
                        guard updated.password == password else {
                            testResult = .failure(VPSConnectionError.invalidCredentials("凭据未能保存，输入已保留。")); return
                        }
                        if !onSave(updated) { testResult = .failure(VPSConnectionError.invalidCredentials("服务器配置未能保存，输入已保留。")) }
                    } catch {
                        testResult = .failure(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460, height: 420)
    }

    private var hasRequiredFields: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private var canSave: Bool {
        hasRequiredFields && hasSuccessfulTest && !isTesting
    }

    private func runConnectionTest() {
        isTesting = true
        testResult = nil

        Task {
            do {
                let candidate = try buildConfig()
                let testedPassword = password
                let result = await ThreeXUIClient().testConnection(config: candidate, password: testedPassword)
                if (try? buildConfig()) == candidate && password == testedPassword {
                    testResult = result; hasSuccessfulTest = result.success
                }
            } catch {
                testResult = .failure(error)
                hasSuccessfulTest = false
            }
            isTesting = false
        }
    }

    private func buildConfig() throws -> AppConfig.VPSConfig {
        let parsed = try VPSPanelURLParser.parse(panelURL)
        return AppConfig.VPSConfig(
            id: config.id,
            name: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .threeXUI,
            host: parsed.host,
            port: parsed.port,
            basePath: parsed.basePath,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            useTLS: parsed.useTLS,
            allowSelfSignedCertificate: allowSelfSignedCertificate
        )
    }

    private func resetTestState() {
        hasSuccessfulTest = false
        testResult = nil
    }
}

// MARK: - Settings Window Controller

/// One settings window, shared by the menu and keyboard shortcut.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private weak var coordinator: MonitorCoordinator?
    func show(coordinator: MonitorCoordinator) {
        self.coordinator = coordinator
        coordinator.settingsDraft.loadIfClean()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(coordinator: coordinator)))
            w.title = "NetBar 设置"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 560, height: 500))
            w.center(); w.setFrameAutosaveName("NetBarSettingsWindow")
            w.isReleasedWhenClosed = false; w.delegate = self
            window = w
        }
        window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func allowLeavingSettings() -> Bool {
        guard let coordinator, coordinator.settingsDraft.hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "保存连接设置的修改？"
        alert.informativeText = "测试连接不会保存草稿。你可以保存、放弃修改或继续编辑。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "放弃修改"); alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return coordinator.settingsDraft.save(coordinator: coordinator)
        case .alertSecondButtonReturn: coordinator.settingsDraft.discard(); return true
        default: return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowLeavingSettings() }
}
