import Foundation
import WebKit

/// 免 Key 数据链路：离屏 WKWebView 加载 ping0.cc，等待 Cloudflare Turnstile 自动通过
/// （真 WebKit 引擎下为 managed 模式，无需人工交互），再单次 evaluateJavaScript 抽取字段，
/// 交给 `Ping0PageParser` 解析。
///
/// 页面结构与解析锚点契约（站点改版时按此修补）：
/// skills/my/infra/local-dev-config/netbar-app-management/specs/001-ping0-ip-purity/contracts/ping0-dom-anchors.md
final class Ping0WebClient: IPIntelligenceClient {
    private let pageReadyTimeout: TimeInterval
    private let aiDetectionTimeout: TimeInterval
    private let pollInterval: TimeInterval

    /// - Parameters:
    ///   - pageReadyTimeout: 页面就绪（挑战自动通过 + 数据渲染）的总预算，含 Turnstile 3-8s。
    ///   - aiDetectionTimeout: 「大模型检测」点击触发后的结论等待上限，超时该字段降级。
    init(
        pageReadyTimeout: TimeInterval = 12,
        aiDetectionTimeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.5
    ) {
        self.pageReadyTimeout = pageReadyTimeout
        self.aiDetectionTimeout = aiDetectionTimeout
        self.pollInterval = pollInterval
    }

    /// 网页链路查询的是浏览器实际出口（auto 语义），`version` 无法强制 IPv4/IPv6，忽略。
    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo {
        try await lookupViaPage(urlString: "https://ping0.cc/")
    }

    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo {
        try await lookupViaPage(urlString: "https://ping0.cc/ip/\(ip)")
    }

    @MainActor
    private func lookupViaPage(urlString: String) async throws -> EgressIPInfo {
        try Task.checkCancellation()
        guard let url = URL(string: urlString) else { throw EgressIPError.invalidEndpoint }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        // Query ownership ends here, on success, error, or cancellation. Keeping a
        // loaded challenge page alive also keeps its timers and WebKit work alive.
        defer { Self.releasePage(webView) }
        return try await withTaskCancellationHandler {
            webView.load(URLRequest(url: url))
            guard try await waitUntilReady(webView) else { throw EgressIPError.webpageNotReady }
            let script = Self.extractionScript(aiTimeoutMs: Int(aiDetectionTimeout * 1000))
            var lastError: Error = EgressIPError.invalidJSONResponse
            for _ in 0..<3 {
                try Task.checkCancellation()
                do {
                    guard let raw = try await evaluate(script, on: webView) as? String else {
                        throw EgressIPError.invalidJSONResponse
                    }
                    try Task.checkCancellation()
                    return try Ping0PageParser.parse(extractionJSON: raw)
                } catch let error as EgressIPError {
                    throw error
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            throw lastError
        } onCancel: {
            Task { @MainActor in Self.releasePage(webView) }
        }
    }

    @MainActor
    private static func releasePage(_ webView: WKWebView) {
        webView.stopLoading()
        // stopLoading alone does not stop JavaScript in an already loaded page.
        webView.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    private func evaluate(_ script: String, on webView: WKWebView) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    private func waitUntilReady(_ webView: WKWebView) async throws -> Bool {
        let deadline = Date().addingTimeInterval(pageReadyTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let ready = (try? await evaluate(Self.readinessScript, on: webView) as? Bool) ?? false
            if ready { return true }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    // MARK: - 注入脚本

    /// 数据页就绪特征：任一核心锚点出现（挑战页两者皆无，等待其自动通过并 reload）。
    static let readinessScript = "!!document.querySelector('.line.ip') || !!document.querySelector('.riskitem.riskcurrent')"

    /// 单次往返抽取全部字段；大模型检测为「点击检测」态时自动触发并限时等待结论，
    /// 超时返回空串（该字段降级，不阻塞整体）。键名契约见 Ping0PageParser 文档。
    static func extractionScript(aiTimeoutMs: Int) -> String {
        """
        (async () => {
          const q = (s) => document.querySelector(s);
          const txt = (s) => { const el = q(s); return el ? el.textContent.trim() : ''; };
          // 行主文本：剔除徽章与说明链接后取剩余文本
          const mainText = (s) => {
            const el = q(s); if (!el) return '';
            const clone = el.cloneNode(true);
            clone.querySelectorAll('.label, .fielddesc, a').forEach((n) => n.remove());
            return clone.textContent.trim();
          };
          const riskItem = q('.riskitem.riskcurrent');
          const riskPercent = riskItem
            ? ((riskItem.querySelector('.value') || {}).textContent || '').trim()
            : '';
          let aiText = txt('.line-aicheck .content span.label');
          if (!aiText) {
            const trigger = q('.line-aicheck .content a');
            if (trigger) trigger.click();
            const deadline = Date.now() + \(aiTimeoutMs);
            while (!aiText && Date.now() < deadline) {
              await new Promise((r) => setTimeout(r, 400));
              aiText = txt('.line-aicheck .content span.label');
            }
          }
          return JSON.stringify({
            ip: txt('.line.ip .content .ip span'),
            location: mainText('.line.loc .content'),
            asn: txt('a[href*="/as/AS"]'),
            asnName: mainText('.line.asnname .content'),
            org: mainText('.line.orgname .content'),
            ipType: txt('.line-iptype .content span.label'),
            riskPercent: riskPercent,
            nativeText: txt('.line-nativeip .content span.label'),
            aiText: aiText,
            sharedUsers: txt('.line-usecount .content .usecountbar'),
          });
        })()
        """
    }
}

/// 数据源装配与降级链的唯一决策点：
/// 配置了 ping0 API Key → 付费接口（`Ping0IPClient`，行为不变）；
/// 未配置 → 免 Key 网页链路（`Ping0WebClient`），网页失败时降级基础归属地（/geo），
/// 再失败才向上抛错（此时错误来自 geo，语义可读）。
final class EgressIPClientRouter: IPIntelligenceClient {
    private let apiClient: IPIntelligenceClient
    private let webClient: IPIntelligenceClient

    init(
        apiClient: IPIntelligenceClient = Ping0IPClient(),
        webClient: IPIntelligenceClient = Ping0WebClient()
    ) {
        self.apiClient = apiClient
        self.webClient = webClient
    }

    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
            return try await apiClient.lookupCurrentIP(version: version, apiKey: trimmedKey)
        }
        do {
            return try await webClient.lookupCurrentIP(version: version, apiKey: nil)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            Log.network.error("ping0 网页链路失败，降级基础归属地: \(error.localizedDescription)")
            return try await apiClient.lookupCurrentIP(version: version, apiKey: nil)
        }
    }

    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo {
        try await apiClient.lookup(ip: ip, apiKey: apiKey)
    }
}
