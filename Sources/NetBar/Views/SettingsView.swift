import SwiftUI

/// 设置窗口 — 通用、代理、VPS 三个 Tab
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

            ProxySettingsTab()
                .tabItem {
                    Label("代理", systemImage: "network")
                }
                .tag(1)

            VPSSettingsTab(coordinator: coordinator)
                .tabItem {
                    Label("VPS 监控", systemImage: "cloud")
                }
                .tag(2)
        }
        .frame(width: 460, height: 340)
    }
}

// MARK: - 通用设置

private struct GeneralSettingsTab: View {
    let coordinator: MonitorCoordinator
    @State private var launchAtLogin = LaunchAgentManager.isEnabled
    @State private var suppressLaunchAtLoginChange = false
    @State private var refreshInterval: Double = AppConfig.shared.refreshInterval

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        guard !suppressLaunchAtLoginChange else { return }
                        guard LaunchAgentManager.setEnabled(newValue) else {
                            Log.config.error("开机自启设置失败: LaunchAgent 写入或 launchctl 更新失败")
                            suppressLaunchAtLoginChange = true
                            launchAtLogin = LaunchAgentManager.isEnabled
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
            launchAtLogin = LaunchAgentManager.isEnabled
            refreshInterval = AppConfig.shared.refreshInterval
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
                Text("Mihomo 代理核心的本地连接信息。如果使用 Clash Verge，Socket 路径通常为 /tmp/verge/verge-mihomo.sock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - VPS 设置

private struct VPSSettingsTab: View {
    let coordinator: MonitorCoordinator
    @State private var configs: [AppConfig.VPSConfig] = AppConfig.shared.vpsConfigs
    @State private var editingConfig: AppConfig.VPSConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if configs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("未配置 VPS 服务器")
                        .foregroundColor(.secondary)
                    Text("添加 VPS 后可在菜单栏查看流量统计")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(configs) { config in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(verbatim: "\(config.host):\(config.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                editingConfig = config
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)

                            Button {
                                configs.removeAll { $0.id == config.id }
                                AppConfig.shared.vpsConfigs = configs
                                coordinator.reloadVPSConfigsAndRefresh()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Button {
                    editingConfig = AppConfig.VPSConfig(
                        id: UUID().uuidString,
                        name: "New VPS",
                        host: "",
                        port: 2053,
                        basePath: "",
                        username: "",
                        useTLS: true
                    )
                } label: {
                    Label("添加 VPS", systemImage: "plus")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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
    }
}

// MARK: - VPS 编辑表单

private struct VPSEditSheet: View {
    @State var config: AppConfig.VPSConfig
    @State private var password: String = ""
    let onSave: (AppConfig.VPSConfig) -> Void
    let onCancel: () -> Void

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名称", text: $config.name)
                TextField("主机", text: $config.host)
                    .font(.system(.body, design: .monospaced))
                TextField("端口", value: $config.port, formatter: Self.portFormatter)
                TextField("Base Path", text: $config.basePath)
                    .font(.system(.body, design: .monospaced))
                TextField("用户名", text: $config.username)
                SecureField("密码", text: $password)
                Toggle("使用 TLS (HTTPS)", isOn: $config.useTLS)
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    config.password = password
                    onSave(config)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.host.isEmpty || config.username.isEmpty)
            }
            .padding()
        }
        .frame(width: 380, height: 360)
        .onAppear {
            password = config.password
        }
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

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
