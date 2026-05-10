import AppKit
import ServiceManagement
import SwiftUI

/// 设置窗口 — 通用、代理、服务器管理
struct SettingsView: View {
    @ObservedObject var config = AppConfig.shared
    let coordinator: MonitorCoordinator
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(coordinator: coordinator)
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
                .tag(0)

            if DistributionFlavor.current.supportsAdvancedProxyDetection {
                ProxySettingsTab()
                    .tabItem {
                        Label("代理", systemImage: "network")
                    }
                    .tag(1)
            }

            IPDetectionSettingsTab(coordinator: coordinator)
                .tabItem {
                    Label("IP 检测", systemImage: "globe")
                }
                .tag(2)

            VPSSettingsTab(coordinator: coordinator)
                .tabItem {
                    Label("服务器管理", systemImage: "cloud")
                }
                .tag(3)
        }
        .frame(width: 560, height: 430)
    }
}

// MARK: - 通用设置

private struct GeneralSettingsTab: View {
    let coordinator: MonitorCoordinator
    @State private var launchAtLogin = StartupSetting.isEnabled
    @State private var suppressLaunchAtLoginChange = false
    @State private var refreshInterval: Double = AppConfig.shared.refreshInterval

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        guard !suppressLaunchAtLoginChange else { return }
                        guard StartupSetting.setEnabled(newValue) else {
                            Log.config.error("开机自启设置失败")
                            suppressLaunchAtLoginChange = true
                            launchAtLogin = StartupSetting.isEnabled
                            DispatchQueue.main.async {
                                suppressLaunchAtLoginChange = false
                            }
                            return
                        }
                    }

                HStack {
                    Text("刷新间隔")
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

// MARK: - 代理设置

private struct ProxySettingsTab: View {
    @State private var socketPath = AppConfig.shared.mihomoSocketPath
    @State private var controllerURL = AppConfig.shared.mihomoControllerURL
    @State private var secret = AppConfig.shared.mihomoSecret

    var body: some View {
        Form {
            Section {
                TextField("Socket 路径", text: $socketPath)
                    .onChange(of: socketPath) { AppConfig.shared.mihomoSocketPath = $0 }

                TextField("Controller URL", text: $controllerURL)
                    .onChange(of: controllerURL) { AppConfig.shared.mihomoControllerURL = $0 }

                SecureField("Secret", text: $secret)
                    .onChange(of: secret) { AppConfig.shared.mihomoSecret = $0 }
            } header: {
                Text("Mihomo / Clash Verge")
            } footer: {
                Text("Direct Full 用于读取本机代理核心连接信息，App Store Lite 不包含该能力。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - IP 检测设置

private struct IPDetectionSettingsTab: View {
    let coordinator: MonitorCoordinator
    @ObservedObject private var egressIPMonitor: EgressIPMonitor
    @State private var enabled = AppConfig.shared.ipCheckEnabled
    @State private var version = AppConfig.shared.ipCheckVersion
    @State private var refreshMinutes = AppConfig.shared.ipCheckRefreshMinutes
    @State private var hideWiFiName = AppConfig.shared.hideWiFiName
    @State private var apiKey = AppConfig.shared.ping0APIKey
    @State private var isTesting = false

    init(coordinator: MonitorCoordinator) {
        self.coordinator = coordinator
        _egressIPMonitor = ObservedObject(initialValue: coordinator.egressIPMonitor)
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用出口 IP 检测", isOn: $enabled)
                    .onChange(of: enabled) { newValue in
                        AppConfig.shared.ipCheckEnabled = newValue
                        coordinator.reloadIPCheckSettingsAndRefresh()
                    }

                Picker("检测版本", selection: $version) {
                    ForEach(IPVersion.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .onChange(of: version) { newValue in
                    AppConfig.shared.ipCheckVersion = newValue
                    coordinator.reloadIPCheckSettingsAndRefresh()
                }

                Picker("自动刷新", selection: $refreshMinutes) {
                    Text("5 分钟").tag(5.0)
                    Text("15 分钟").tag(15.0)
                    Text("30 分钟").tag(30.0)
                    Text("60 分钟").tag(60.0)
                }
                .onChange(of: refreshMinutes) { newValue in
                    AppConfig.shared.ipCheckRefreshMinutes = newValue
                    coordinator.reloadIPCheckSettingsAndRefresh()
                }

                Toggle("隐藏 Wi-Fi 名称", isOn: $hideWiFiName)
                    .onChange(of: hideWiFiName) { newValue in
                        AppConfig.shared.hideWiFiName = newValue
                    }
            } header: {
                Text("出口 IP")
            } footer: {
                Text("开启后顶部网络信息会显示“Wi-Fi: 已隐藏”。这是隐私显示设置，不影响公网出口 IP 或代理状态判断。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                SecureField("ping0 API Key", text: $apiKey)
                    .onChange(of: apiKey) { newValue in
                        AppConfig.shared.ping0APIKey = newValue
                    }

                HStack {
                    Button {
                        apiKey = ""
                        AppConfig.shared.ping0APIKey = ""
                        coordinator.reloadIPCheckSettingsAndRefresh()
                    } label: {
                        Label("清空 Key", systemImage: "xmark.circle")
                    }

                    Spacer()

                    Button {
                        runTest()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 64)
                        } else {
                            Label("测试检测", systemImage: "checkmark.circle")
                        }
                    }
                    .disabled(!enabled || isTesting)
                }
            } header: {
                Text("纯净度")
            } footer: {
                Text("未填写 API Key 时只显示免费基础信息；填写后会请求 ping0 指定 IP API 显示风险值、IDC、原生 IP 等字段。检测会把当前公网出口 IP 发送给 ping0.cc。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                if let info = egressIPMonitor.info {
                    HStack {
                        Text("当前出口")
                        Spacer()
                        Text(info.ip)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(info.riskLabel)
                            .foregroundColor(riskColor(info))
                    }
                } else if let error = egressIPMonitor.errorMessage {
                    Text(error)
                        .foregroundColor(.orange)
                } else {
                    Text(enabled ? "尚未检测" : "已关闭")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("结果")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            enabled = AppConfig.shared.ipCheckEnabled
            version = AppConfig.shared.ipCheckVersion
            refreshMinutes = AppConfig.shared.ipCheckRefreshMinutes
            hideWiFiName = AppConfig.shared.hideWiFiName
            apiKey = AppConfig.shared.ping0APIKey
        }
    }

    private func runTest() {
        AppConfig.shared.ipCheckEnabled = enabled
        AppConfig.shared.ipCheckVersion = version
        AppConfig.shared.ipCheckRefreshMinutes = refreshMinutes
        AppConfig.shared.ping0APIKey = apiKey

        isTesting = true
        Task {
            _ = await coordinator.egressIPMonitor.refreshNow(force: true)
            isTesting = false
        }
    }

    private func riskColor(_ info: EgressIPInfo) -> Color {
        guard let risk = info.ipRisk else {
            return .secondary
        }
        if risk <= 25 { return .green }
        if risk <= 50 { return .orange }
        return .red
    }
}

// MARK: - VPS 设置

private struct VPSSettingsTab: View {
    let coordinator: MonitorCoordinator
    @State private var configs: [AppConfig.VPSConfig] = AppConfig.shared.vpsConfigs
    @State private var editingConfig: AppConfig.VPSConfig?
    @State private var testingIDs: Set<String> = []
    @State private var testMessages: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if configs.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(configs) { config in
                        serverRow(config)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            bottomBar
        }
        .sheet(item: $editingConfig) { config in
            VPSEditSheet(config: config) { updated in
                if let idx = configs.firstIndex(where: { $0.id == updated.id }) {
                    configs[idx] = updated
                } else {
                    configs.append(updated)
                }
                AppConfig.shared.vpsConfigs = configs
                coordinator.reloadVPSConfigsAndRefresh()
                editingConfig = nil
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
                Text("添加 3X-UI 面板后，NetBar 会在菜单栏显示 VPS 流量。")
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

            Button {
                editingConfig = config
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")

            Button {
                configs.removeAll { $0.id == config.id }
                AppConfig.shared.vpsConfigs = configs
                coordinator.reloadVPSConfigsAndRefresh()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
        .padding(.vertical, 6)
    }

    private func testServer(_ config: AppConfig.VPSConfig) {
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
    let onSave: (AppConfig.VPSConfig) -> Void
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
        onSave: @escaping (AppConfig.VPSConfig) -> Void,
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
                        onSave(updated)
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
                let result = await ThreeXUIClient().testConnection(config: candidate, password: password)
                testResult = result
                hasSuccessfulTest = result.success
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

/// 管理设置窗口的生命周期（确保只有一个实例）
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(coordinator: MonitorCoordinator) {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(coordinator: coordinator)
        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "NetBar 设置"
        newWindow.styleMask = [.titled, .closable]
        newWindow.center()
        newWindow.setFrameAutosaveName("SettingsWindow")
        newWindow.isReleasedWhenClosed = false

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
