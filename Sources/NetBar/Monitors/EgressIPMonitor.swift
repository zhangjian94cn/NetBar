import Foundation

final class EgressIPMonitor: ObservableObject, MonitorProtocol {
    @Published private(set) var info: EgressIPInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let config: AppConfig
    private let client: IPIntelligenceClient
    private let minimumCacheTTL: TimeInterval
    private var timer: Timer?

    init(
        config: AppConfig = .shared,
        client: IPIntelligenceClient = Ping0IPClient(),
        minimumCacheTTL: TimeInterval = 300
    ) {
        self.config = config
        self.client = client
        self.minimumCacheTTL = minimumCacheTTL
    }

    func start() {
        stop()

        guard config.ipCheckEnabled else {
            clearDisabledState()
            return
        }

        refresh(force: true)
        let interval = max(minimumCacheTTL, config.ipCheckRefreshMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reloadSettingsAndRefresh() {
        start()
    }

    func refresh(force: Bool = false) {
        Task {
            await refreshNow(force: force)
        }
    }

    @discardableResult
    func refreshNow(force: Bool = false) async -> EgressIPInfo? {
        guard config.ipCheckEnabled else {
            await MainActor.run {
                self.clearDisabledState()
            }
            return nil
        }

        if !force {
            let cachedInfo = await MainActor.run { self.info }
            if let cachedInfo, Date().timeIntervalSince(cachedInfo.fetchedAt) < minimumCacheTTL {
                return cachedInfo
            }
        }

        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }

        do {
            let apiKey = config.ping0APIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.lookupCurrentIP(
                version: config.ipCheckVersion,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            await MainActor.run {
                self.info = result
                self.errorMessage = nil
                self.isLoading = false
            }
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                self.errorMessage = message
                self.isLoading = false
            }
            return nil
        }
    }

    private func clearDisabledState() {
        info = nil
        errorMessage = nil
        isLoading = false
    }
}
