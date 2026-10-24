import AppKit
import Combine
import Foundation

struct ManagementPanel: Codable, Identifiable, Equatable {
    enum Access: String, Codable, CaseIterable {
        case browser, sub2apiBWG, sub2apiNKG
        var title: String {
            switch self { case .browser: return "浏览器"; case .sub2apiBWG: return "SSH 隧道 · 搬瓦工"; case .sub2apiNKG: return "SSH 隧道 · 南京" }
        }
        var tunnelHost: String? {
            switch self { case .browser: return nil; case .sub2apiBWG: return "bwg"; case .sub2apiNKG: return "tencent-edge-nkg" }
        }
    }
    var id = UUID().uuidString
    var name = ""
    var address = "https://"
    var username = ""
    var password = ""
    var access: Access = .browser
    var tunnelScript = ""
    var hasCredentials: Bool { !username.isEmpty || !password.isEmpty }
    var credentialsSummary: String { password.isEmpty ? (username.isEmpty ? "未保存凭据" : "已保存账号 · 密码未保存") : "凭据已保存" }

    func validatedURL() throws -> URL {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: raw), let host = c.host, !host.isEmpty,
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.user == nil, c.password == nil, c.fragment == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true,
              let url = c.url else { throw PanelError.invalidURL }
        // Management links may contain an object ID, never login tokens or passwords.
        let forbidden = ["password", "passwd", "pwd", "token", "secret", "api_key", "apikey", "auth", "session", "cookie", "key"]
        guard !(c.queryItems ?? []).contains(where: { item in forbidden.contains { item.name.lowercased().contains($0) } }) else { throw PanelError.embeddedCredential }
        if access != .browser {
            let expectedPort = access == .sub2apiBWG ? 8080 : 8082
            guard host == "127.0.0.1", c.scheme == "http", c.port == expectedPort,
                  c.path.isEmpty || c.path == "/", c.query == nil else { throw PanelError.invalidTunnel }
        }
        return url
    }
    func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw PanelError.missingName }
        result.address = try validatedURL().absoluteString
        if access != .browser {
            guard tunnelScript.hasPrefix("/"), URL(fileURLWithPath: tunnelScript).lastPathComponent == "sub2api-tunnel.sh" else { throw PanelError.missingTunnel }
        }
        return result
    }
    static func defaults(configs: [AppConfig.VPSConfig]) -> [Self] {
        [.init(id: "bwg-kiwivm", name: "BWG · KiwiVM", address: "https://kiwivm.64clouds.com/")] + configs.map {
            .init(id: "vps-" + $0.id, name: $0.name + " · 3X-UI", address: $0.panelURL, username: $0.username)
        }
    }
}

enum PanelError: LocalizedError {
    case invalidURL, embeddedCredential, invalidTunnel, missingName, missingTunnel, conflict, corrupt, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP 或 HTTPS 面板地址，不要在地址中填写登录信息。"
        case .embeddedCredential: return "请把密码或令牌放入登录信息，面板地址不能携带认证参数。"
        case .invalidTunnel: return "隧道后台必须使用对应的本机地址：搬瓦工 127.0.0.1:8080，南京 127.0.0.1:8082。"
        case .missingName: return "请填写面板名称。"
        case .missingTunnel: return "请选择已有的 sub2api-tunnel.sh 隧道入口脚本。"
        case .conflict: return "记录已在其他位置更新。请重新载入后编辑；本次草稿仍保留。"
        case .corrupt: return "无法读取已保存的面板记录，未覆盖原数据。"
        case .unavailable: return "记录尚未载入，暂时不能保存。"
        }
    }
}

/// One Keychain item owns both the links and credentials: no plaintext preferences or split writes.
final class ManagementPanelsStore: ObservableObject {
    static let storageKey = "management_panels_v1"
    @Published private(set) var panels: [ManagementPanel] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var openingID: String?
    private var baseline: Data?
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let defaults: () -> [ManagementPanel]
    init(read: @escaping () throws -> Data? = { try KeychainHelper.readChecked(key: storageKey) },
         write: @escaping (Data) throws -> Void = { try KeychainHelper.writeChecked(key: storageKey, data: $0) },
         defaults: @escaping () -> [ManagementPanel] = { ManagementPanel.defaults(configs: AppConfig.shared.vpsConfigs) }) {
        self.read = read; self.write = write; self.defaults = defaults
    }
    @MainActor func load() async {
        guard !busy, !loaded else { return }
        busy = true; defer { busy = false }
        do {
            let reader = read
            let data = try await Task.detached { try reader() }.value
            let items: [ManagementPanel]
            if let data {
                guard let decoded = try? JSONDecoder().decode([ManagementPanel].self, from: data), Set(decoded.map(\.id)).count == decoded.count else { throw PanelError.corrupt }
                items = decoded
            } else { items = defaults() }
            baseline = data; panels = items; loaded = true; message = nil
        } catch { message = error.localizedDescription }
    }
    @MainActor @discardableResult func save(_ candidate: [ManagementPanel]) async -> Bool {
        guard loaded, !busy else { message = PanelError.unavailable.localizedDescription; return false }
        busy = true; defer { busy = false }
        do {
            let normalized = try candidate.map { try $0.validated() }
            guard Set(normalized.map(\.id)).count == normalized.count else { throw PanelError.corrupt }
            let data = try JSONEncoder().encode(normalized)
            let reader = read, writer = write, expected = baseline
            try await Task.detached {
                guard try reader() == expected else { throw PanelError.conflict }
                try writer(data)
                guard try reader() == data else { throw PanelError.conflict }
            }.value
            baseline = data; panels = normalized; message = nil; return true
        } catch { message = error.localizedDescription; return false }
    }
    @MainActor @discardableResult func importRecord(_ data: Data) async -> Bool {
        guard data.count <= 1_048_576,
              let imported = try? JSONDecoder().decode([ManagementPanel].self, from: data),
              !imported.isEmpty, Set(imported.map(\.id)).count == imported.count else {
            message = "导入文件格式不正确或超过 1 MB，原记录保持不变。"; return false
        }
        let candidate: [ManagementPanel]
        if baseline == nil {
            let incoming = Set(imported.map(\.id))
            candidate = imported + panels.filter { !incoming.contains($0.id) }
        } else {
            let existing = Set(panels.map(\.id))
            candidate = panels + imported.filter { !existing.contains($0.id) }
        }
        let added = candidate.count - panels.count
        guard await save(candidate) else { return false }
        message = "导入完成，现有 \(panels.count) 个面板（新增 \(max(0, added)) 个）。已保存的同 ID 记录保持原样。"
        return true
    }
    @MainActor func open(_ panel: ManagementPanel) {
        guard openingID == nil else { return }
        do {
            let url = try panel.validatedURL()
            if panel.access == .browser || DistributionFlavor.current != .directFull {
                message = NSWorkspace.shared.open(url) ? (panel.access == .browser ? nil : "已打开本机后台地址；Lite 需要先手动建立 SSH 隧道。") : "浏览器未能打开面板，请检查默认浏览器。"
                return
            }
            _ = try panel.validated()
            guard FileManager.default.fileExists(atPath: panel.tunnelScript) else { throw PanelError.missingTunnel }
            openingID = panel.id; message = "正在连接管理隧道…"
            Task { @MainActor in
                let succeeded = await ManagementTunnelLauncher.run(script: panel.tunnelScript, host: panel.access.tunnelHost!)
                openingID = nil
                if succeeded {
                    message = NSWorkspace.shared.open(url) ? nil : "隧道已就绪，但浏览器未打开。"
                } else {
                    message = "SSH 隧道未就绪，未打开后台。请检查现有隧道入口、SSH 认证及端口占用后重试。"
                }
            }
        } catch { message = error.localizedDescription }
    }
}

/// The service owner intentionally retains its SSH/watchdog children. The general
/// probe runner kills a process group on exit and must not be used for this action.
enum ManagementTunnelLauncher {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        var pending: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
        func finish(_ success: Bool) {
            lock.lock(); let current = continuation; continuation = nil; lock.unlock()
            current?.resume(returning: success)
        }
    }
    static func run(script: String, host: String, timeout: TimeInterval = 120) async -> Bool {
        guard ["bwg", "tencent-edge-nkg"].contains(host),
              script.hasPrefix("/"), URL(fileURLWithPath: script).lastPathComponent == "sub2api-tunnel.sh" else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            let completion = Completion(continuation)
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script, "--host", host, "up", "--no-open"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { completion.finish($0.terminationStatus == 0) }
            do { try process.run() } catch { completion.finish(false); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if completion.pending { if process.isRunning { process.terminate() }; completion.finish(false) }
            }
        }
    }
}

enum CredentialClipboard {
    static func copy(_ value: String, pasteboard: NSPasteboard = .general, lifetime: TimeInterval = 30) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        let generation = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            if pasteboard.changeCount == generation { pasteboard.clearContents() }
        }
    }
}
