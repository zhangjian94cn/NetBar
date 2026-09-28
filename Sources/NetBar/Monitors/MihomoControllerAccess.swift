import Foundation
import NetworkExecution

/// One owner for controller discovery. A responding, decodable /configs is the
/// evidence; the existence of a socket file alone never selects a controller.
final class MihomoControllerAccess {
    static let legacySocketPath = "/tmp/verge/verge-mihomo.sock"
    static let defaultControllerURL = "http://127.0.0.1:9097/connections"

    struct Settings {
        var socketPath: String
        var controllerURL: String
        var secret: String
    }

    enum Endpoint: Equatable {
        case unixSocket(String)
        case http(String)

        var diagnosticLabel: String {
            switch self {
            case .unixSocket(let path):
                if path == MihomoControllerAccess.legacySocketPath { return "legacy-socket" }
                if path.hasPrefix("/var/run/clash-verge-service/users/") { return "user-service-socket" }
                return "custom-socket"
            case .http: return "http-controller"
            }
        }
    }

    struct Session {
        let endpoint: Endpoint
        let configuration: MihomoClient.RuntimeConfiguration
    }

    enum Failure: Error, Equatable {
        case unreachable, timedOut, cancelled, unauthorized, invalidResponse, readOnly

        var description: String {
            switch self {
            case .unreachable: return "Clash 控制端不可达，请检查 NetBar 的代理设置"
            case .timedOut: return "Clash 控制端检查超时，等待重新检测"
            case .cancelled: return "Clash 控制端检查已取消，等待重新检测"
            case .unauthorized: return "Clash 控制端认证失败，请检查 NetBar 代理设置中的 Secret"
            case .invalidResponse: return "Clash 控制端返回无效配置，请检查 NetBar 的代理设置"
            case .readOnly: return "HTTP 控制端仅供读取；控制操作需要本机 Socket"
            }
        }
    }

    typealias CommandRunner = ([String]) -> (exitCode: Int32, output: String)
    private let settings: () -> Settings
    private let userID: UInt32
    private let run: CommandRunner
    private let cacheID = UUID().uuidString
    private let lock = NSLock()
    private var lastFailure: Failure = .unreachable

    init(settings: @escaping () -> Settings = {
        Settings(socketPath: AppConfig.shared.mihomoSocketPath,
                 controllerURL: AppConfig.shared.mihomoControllerURL,
                 secret: AppConfig.shared.mihomoSecret)
    }, userID: UInt32 = getuid(), run: @escaping CommandRunner = { arguments in
        let result = BoundedCommand.run("/usr/bin/curl", arguments, timeout: 2)
        return (result.exitCode, result.stdout)
    }) {
        self.settings = settings
        self.userID = userID
        self.run = run
    }

    var failureDescription: String {
        lock.lock(); defer { lock.unlock() }
        return lastFailure.description
    }

    private func failed<T>(_ failure: Failure) -> Result<T, Failure> {
        lock.lock(); lastFailure = failure; lock.unlock()
        return .failure(failure)
    }

    func resolve() -> Result<Session, Failure> {
        let settings = settings()
        let parent = ProbeContext.current
        if parent?.isCancelled == true { return failed(.cancelled) }
        if parent?.isStopped == true { return failed(.timedOut) }
        let key = "mihomo-session:\(cacheID):\(settings.socketPath):\(settings.controllerURL)"
        if let parent, let cached: Session = parent.memoized(key, { nil as Session? }) {
            return .success(cached)
        }
        // All candidates share this budget; adding a fallback must not multiply
        // the time spent discovering a controller in a recovery round.
        let context = ProbeContext(timeout: 2, parent: parent)
        return ProbeContext.withValue(context) {
            var failure = Failure.unreachable
            for endpoint in candidates(settings) {
                if context.isCancelled { return failed(.cancelled) }
                if context.isStopped { return failed(.timedOut) }
                switch request(endpoint: endpoint, path: "/configs", secret: settings.secret) {
                case .success(let data):
                    guard let config = MihomoClient.decodeRuntimeConfiguration(data) else {
                        failure = .invalidResponse
                        continue
                    }
                    let session = Session(endpoint: endpoint, configuration: config)
                    parent?.store(key, session)
                    return .success(session)
                case .failure(let error):
                    // Keep an informative response error when later candidates
                    // simply do not exist. No failure is cached across retries.
                    if error != .unreachable || failure == .unreachable { failure = error }
                }
            }
            return failed(failure)
        }
    }

    private func candidates(_ settings: Settings) -> [Endpoint] {
        let socket = settings.socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !socket.isEmpty, socket != Self.legacySocketPath { return [.unixSocket(socket)] }
        let controller = settings.controllerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !controller.isEmpty, controller != Self.defaultControllerURL {
            return [.http(controller)]
        }
        return [
            .unixSocket("/var/run/clash-verge-service/users/\(userID)/verge-mihomo.sock"),
            .unixSocket(Self.legacySocketPath),
            .http(Self.defaultControllerURL)
        ]
    }

    func read(path: String) -> Data? {
        guard case .success(let session) = resolve() else { return nil }
        return try? request(endpoint: session.endpoint, path: path, secret: settings().secret).get()
    }

    func write(method: String, path: String, body: String? = nil) -> Bool {
        #if APP_STORE
        return false
        #else
        guard case .success(let session) = resolve() else { return false }
        guard case .unixSocket = session.endpoint else {
            let _: Result<Data, Failure> = failed(.readOnly)
            return false
        }
        // Exactly one write to the verified target. Never replay a mutation on
        // another controller after an ambiguous transport failure.
        if case .success = request(endpoint: session.endpoint, path: path,
                                   method: method, body: body, secret: settings().secret,
                                   expectedStatus: 204) { return true }
        return false
        #endif
    }

    private func request(endpoint: Endpoint, path: String, method: String = "GET",
                         body: String? = nil, secret: String,
                         expectedStatus: Int? = nil) -> Result<Data, Failure> {
        if ProbeContext.current?.isCancelled == true { return failed(.cancelled) }
        if ProbeContext.current?.isStopped == true { return failed(.timedOut) }
        var arguments = ["-sS", "--noproxy", "*", "--max-time", "2", "-w", "\n%{http_code}"]
        let url: String
        switch endpoint {
        case .unixSocket(let socketPath):
            arguments += ["--unix-socket", socketPath]
            url = "http://unix" + path
        case .http(let value):
            guard var components = URLComponents(string: value),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  components.host != nil else { return failed(.invalidResponse) }
            components.path = path
            components.query = nil
            components.fragment = nil
            guard let resolved = components.url else { return failed(.invalidResponse) }
            url = resolved.absoluteString
        }
        if method != "GET" { arguments += ["-X", method] }
        if !secret.isEmpty { arguments += ["-H", "Authorization: Bearer \(secret)"] }
        if let body { arguments += ["-H", "Content-Type: application/json", "--data-binary", body] }
        arguments.append(url)
        let result = run(arguments)
        if result.exitCode == -2 { return failed(.cancelled) }
        if result.exitCode == -3 || result.exitCode == 28 { return failed(.timedOut) }
        guard result.exitCode == 0 else { return failed(.unreachable) }
        guard let newline = result.output.lastIndex(of: "\n"),
              let status = Int(result.output[result.output.index(after: newline)...]) else {
            return failed(.invalidResponse)
        }
        if status == 401 || status == 403 { return failed(.unauthorized) }
        guard expectedStatus.map({ status == $0 }) ?? (200..<300).contains(status) else {
            return failed(.invalidResponse)
        }
        return .success(Data(result.output[..<newline].utf8))
    }
}
