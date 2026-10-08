import Foundation

final class EgressIPMonitor: ObservableObject, MonitorProtocol {
    @Published private(set) var info: EgressIPInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let config: AppConfig
    private let client: IPIntelligenceClient
    private let minimumCacheTTL: TimeInterval
    private var timer: Timer?
    private var refreshTask: Task<EgressIPInfo?, Never>?
    private var generation: UInt64 = 0

    init(
        config: AppConfig = .shared,
        client: IPIntelligenceClient = EgressIPClientRouter(),
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
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }

    func reloadSettingsAndRefresh() {
        start()
    }

    func refresh(force: Bool = false) {
        let requestedGeneration = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == requestedGeneration else { return }
            _ = await self.refreshNow(force: force)
        }
    }

    @MainActor
    @discardableResult
    func refreshNow(force: Bool = false) async -> EgressIPInfo? {
        guard config.ipCheckEnabled else {
            stop()
            clearDisabledState()
            return nil
        }
        // Manual refreshes and network-change notifications share the current lookup.
        if let refreshTask { return await refreshTask.value }
        if !force, let info, Date().timeIntervalSince(info.fetchedAt) < minimumCacheTTL {
            return info
        }

        isLoading = true
        errorMessage = nil
        let requestedGeneration = generation
        let apiKey = config.ping0APIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = config.ipCheckVersion
        let task = Task { @MainActor [self] () -> EgressIPInfo? in
            do {
                try Task.checkCancellation()
                let result = try await client.lookupCurrentIP(
                    version: version, apiKey: apiKey.isEmpty ? nil : apiKey
                )
                try Task.checkCancellation()
                guard generation == requestedGeneration, config.ipCheckEnabled else { return nil }
                info = result
                errorMessage = nil
                return result
            } catch {
                guard !Task.isCancelled, generation == requestedGeneration else { return nil }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return nil
            }
        }
        refreshTask = task
        let result = await task.value
        if generation == requestedGeneration {
            refreshTask = nil
            isLoading = false
        }
        return result
    }

    private func clearDisabledState() {
        info = nil
        errorMessage = nil
        isLoading = false
    }
}
