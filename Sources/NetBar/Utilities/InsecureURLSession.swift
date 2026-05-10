import Foundation

/// 忽略自签证书的 URLSession 工厂
/// 用于连接使用自签 TLS 证书的服务（如 3X-UI 面板）
enum InsecureURLSession {

    /// 创建一个不验证服务器证书的临时 URLSession
    static func create(timeout: TimeInterval = 10) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config, delegate: InsecureDelegate(), delegateQueue: nil)
    }
}

// MARK: - URLSession Delegate

private class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
