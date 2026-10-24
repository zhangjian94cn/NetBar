import Foundation
import Combine

struct ConnectionSettingsValues: Equatable {
    var socket: String
    var url: String
    var secret: String
    var ipEnabled: Bool
    var ipVersion: IPVersion
    var ipMinutes: Double
    var hideSSID: Bool
    var apiKey: String
    static func current() -> Self {
        let c = AppConfig.shared
        return .init(socket: c.mihomoSocketPath, url: c.mihomoControllerURL, secret: c.mihomoSecret,
                     ipEnabled: c.ipCheckEnabled, ipVersion: c.ipCheckVersion,
                     ipMinutes: c.ipCheckRefreshMinutes, hideSSID: c.hideWiFiName, apiKey: c.ping0APIKey)
    }
    var validationError: String? {
        if !socket.isEmpty && !socket.hasPrefix("/") { return "Socket 路径需要是绝对路径，或留空自动发现。" }
        if !url.isEmpty {
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? ""),
                  parsed.host != nil, parsed.user == nil, parsed.password == nil else { return "请输入有效的 HTTP(S) 控制端地址；凭据请放入 Secret。" }
        }
        return nil
    }
}

final class SettingsDraft: ObservableObject {
    @Published var values: ConnectionSettingsValues
    @Published private(set) var message: String?
    @Published private(set) var isTesting = false
    private var baseline: ConnectionSettingsValues
    private let read: () -> ConnectionSettingsValues
    private let write: (ConnectionSettingsValues) -> Void
    init(read: @escaping () -> ConnectionSettingsValues = { .current() },
         write: @escaping (ConnectionSettingsValues) -> Void = { v in
             let c = AppConfig.shared
             c.mihomoSocketPath = v.socket; c.mihomoControllerURL = v.url; c.mihomoSecret = v.secret
             c.ipCheckEnabled = v.ipEnabled; c.ipCheckVersion = v.ipVersion
             c.ipCheckRefreshMinutes = v.ipMinutes; c.hideWiFiName = v.hideSSID; c.ping0APIKey = v.apiKey
         }) {
        self.read = read; self.write = write; let initial = read(); values = initial; baseline = initial
    }
    private var testedValues: ConnectionSettingsValues?
    private var testResult: String?
    var hasChanges: Bool { values != baseline }
    var visibleTestResult: String? { testedValues == values ? testResult : nil }
    func loadIfClean() { if !hasChanges { baseline = read(); values = baseline } }
    func discard() { baseline = read(); values = baseline; message = nil; testedValues = nil }
    /// Read back even credential writes, which may fail independently of preferences.
    @discardableResult func persist() -> Bool {
        guard baseline == read() else { message = "设置已在其他位置改变，请取消草稿后重新编辑。"; return false }
        if let error = values.validationError { message = error; return false }
        values.apiKey = values.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let intended = values
        write(intended)
        baseline = read()
        guard baseline == intended else {
            message = "部分设置未能保存，草稿已保留。请检查凭据存储后重试。"
            return false
        }
        message = "已保存"; return true
    }
    @discardableResult func save(coordinator: MonitorCoordinator) -> Bool {
        let old = read()
        let saved = persist(), current = read()
        if old.socket != current.socket || old.url != current.url || old.secret != current.secret {
            coordinator.clashNetworkModeController.invalidateProbe()
            coordinator.clashNetworkModeController.refresh()
        }
        if old.ipEnabled != current.ipEnabled || old.ipVersion != current.ipVersion || old.ipMinutes != current.ipMinutes || old.apiKey != current.apiKey {
            coordinator.reloadIPCheckSettingsAndRefresh()
        }
        return saved
    }
    func testProxy() {
        guard !isTesting else { return }
        if let error = values.validationError { message = error; return }
        let candidate = values
        isTesting = true
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                MihomoControllerAccess(settings: {
                    .init(socketPath: candidate.socket, controllerURL: candidate.url, secret: candidate.secret)
                }).resolve()
            }.value
            switch result {
            case .success: self.testResult = "连接可读取 · 仅测试草稿，尚未保存"
            case .failure(let error): self.testResult = error.description + " · 草稿未保存"
            }
            self.testedValues = candidate; self.isTesting = false
        }
    }
    func testIP() {
        guard !isTesting else { return }
        let candidate = values
        isTesting = true
        Task { @MainActor in
            do {
                let key = candidate.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await EgressIPClientRouter().lookupCurrentIP(version: candidate.ipVersion, apiKey: key.isEmpty ? nil : key)
                self.testResult = "IP 检测完成 · 仅测试草稿，尚未保存"
            } catch { self.testResult = "IP 检测未完成 · 草稿未保存，请检查连接与凭据。" }
            self.testedValues = candidate; self.isTesting = false
        }
    }
}
