#if !APP_STORE
import AppKit
import CryptoKit
import Darwin
import Foundation
import NetworkExecution
import SystemConfiguration

struct ClashNativeProfileRegistry: Decodable {
    let current: String
    let names: [String: String]

    private enum CodingKeys: String, CodingKey { case current, names }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decode(String.self, forKey: .current)
        // Verge also registers unnamed script/merge/rules entries. They are not
        // selectable profiles; retain strict String identity for named profiles.
        names = try container.decode([String: String?].self, forKey: .names).compactMapValues { $0 }
    }
}

enum ClashDNSPathEvidence {
    static let upstreamIPs: Set<String> = ["1.1.1.1", "1.0.0.1"]
    static let managedGroups: Set<String> = ["🧲 Claude", "🌐 统一出口"]

    static func connections(in payload: [String: Any]) -> [[String: Any]]? {
        // Mihomo serializes the empty tracker slice as null, including immediately
        // after disabling system proxy. Missing/malformed data still fails closed.
        guard let value = payload["connections"] else { return nil }
        return value is NSNull ? [] : value as? [[String: Any]]
    }

    static func ruleConfiguration(_ rules: [[String: Any]]) -> [[String: Any]] {
        rules.map { rule in
            var projection = rule.filter { ["type", "payload", "proxy", "size"].contains($0.key) }
            projection["disabled"] = (rule["extra"] as? [String: Any])?["disabled"] as? Bool ?? false
            return projection
        }
    }

    static func runtimeTunConfiguration(_ tun: [String: Any]) -> [String: Any] {
        // The live device/address are allocated when TUN starts. Intended device
        // and address settings remain covered by the generated YAML digest.
        normalizedTunConfiguration(Dictionary(uniqueKeysWithValues: (ClashTunPolicy.captureKeys + ["stack", "mtu"]).map { ($0, tun[$0] ?? NSNull()) }))
    }

    static func normalizedTunConfiguration(_ tun: [String: Any]) -> [String: Any] {
        var result = tun
        // TUN capture lists are sets. Verge can merge/reorder the deprecated
        // CIDR forms; membership changes must still invalidate the contract.
        for key in ClashTunPolicy.captureKeys {
            if let values = tun[key] as? [String] { result[key] = Array(Set(values)).sorted() }
        }
        return result
    }

    static func isManagedDoH(_ connection: [String: Any]) -> Bool {
        let metadata = connection["metadata"] as? [String: Any] ?? [:]
        let destination = metadata["destinationIP"] as? String ?? ""
        let host = metadata["host"] as? String ?? ""
        let port = metadata["destinationPort"] as? String ?? String(metadata["destinationPort"] as? Int ?? 0)
        return (upstreamIPs.contains(destination) || upstreamIPs.contains(host)) && port == "443" && managedGroups.contains(metadata["specialProxy"] as? String ?? "")
    }

    static func freshUpstreams(logs: String, names: [String]) -> Set<String>? {
        var results: [String: Set<String>] = [:]
        for line in logs.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? String else { continue }
            for name in names where payload.contains("[DNS] " + name + " -->") && payload.contains(" TXT from ") {
                let matching = upstreamIPs.filter { payload.hasSuffix("TXT from https://" + $0 + ":443/dns-query") || payload.hasSuffix("TXT from https://" + $0 + "/dns-query") }
                guard matching.count == 1, let upstream = matching.first else { return nil }
                results[name, default: []].insert(upstream)
            }
        }
        guard names.allSatisfy({ results[$0]?.isEmpty == false }) else { return nil }
        return results.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    static func confirmsChains(_ connections: [[String: Any]], upstreams: Set<String>, group: String, leaf: String) -> Bool {
        let relevant = connections.filter(isManagedDoH)
        return upstreams.allSatisfy { ip in
            let matches = relevant.filter { row in
                let metadata = row["metadata"] as? [String: Any] ?? [:]
                return metadata["destinationIP"] as? String == ip || metadata["host"] as? String == ip
            }
            return !matches.isEmpty && matches.allSatisfy { row in
                let metadata = row["metadata"] as? [String: Any] ?? [:]
                let chains = row["chains"] as? [String] ?? []
                return metadata["specialProxy"] as? String == group && chains.contains(group) && chains.contains(leaf) && !chains.contains("DIRECT")
            }
        }
    }

    static func tunCaptureSHA256(_ tun: [String: Any]) throws -> String {
        let projection = normalizedTunConfiguration(Dictionary(uniqueKeysWithValues: ClashTunPolicy.captureKeys.map { ($0, tun[$0] ?? NSNull()) }))
        let data = try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isAffectedPublicConnection(_ connection: [String: Any], protectedCIDRs: [String] = []) -> Bool {
        if isManagedDoH(connection) { return true }
        let metadata = connection["metadata"] as? [String: Any] ?? [:]
        let host = (metadata["host"] as? String ?? "").lowercased()
        let destination = metadata["destinationIP"] as? String ?? ""
        let protectedSuffixes = [".local", ".localhost", ".ts.net", ".tailscale.com", ".hq.cmcc", ".js.cmcc", ".rdcloud.indn", ".js.chinamobile.com"]
        if host == "localhost" || protectedSuffixes.contains(where: { host.hasSuffix($0) || host == String($0.dropFirst()) }) { return false }
        func privateAddress(_ value: String) -> Bool {
            let text = value.lowercased()
            if text.contains(":") { return text == "::" || text == "::1" || text.hasPrefix("fc") || text.hasPrefix("fd") || text.hasPrefix("fe80:") || text.hasPrefix("ff") }
            let parts = text.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
            return parts[0] == 0 || parts[0] == 10 || parts[0] == 127 || parts[0] >= 224 ||
                (parts[0] == 169 && parts[1] == 254) || (parts[0] == 172 && (16...31).contains(parts[1])) ||
                (parts[0] == 192 && parts[1] == 168) || (parts[0] == 100 && (64...127).contains(parts[1]))
        }
        if privateAddress(destination) || privateAddress(host) || protectedCIDRs.contains(where: { address(destination, isIn: $0) || address(host, isIn: $0) }) { return false }
        // Unknown destinations are kept rather than treating lack of evidence as public.
        return !destination.isEmpty
    }

    private static func address(_ address: String, isIn cidr: String) -> Bool {
        let fields = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let prefix = Int(fields[1]), !address.isEmpty else { return false }
        let family = address.contains(":") ? AF_INET6 : AF_INET
        let width = family == AF_INET6 ? 16 : 4
        guard (0...(width * 8)).contains(prefix) else { return false }
        var ip = [UInt8](repeating: 0, count: width), network = [UInt8](repeating: 0, count: width)
        guard inet_pton(family, address, &ip) == 1, inet_pton(family, String(fields[0]), &network) == 1 else { return false }
        let whole = prefix / 8, remaining = prefix % 8
        guard ip.prefix(whole) == network.prefix(whole) else { return false }
        return remaining == 0 || (ip[whole] & (0xff << (8 - remaining))) == (network[whole] & (0xff << (8 - remaining)))
    }
}

final class LiveClashNetworkModeBackend: ClashNetworkModeBackend {
    private let access = MihomoControllerAccess()
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func manifest() throws -> ClashModeManifest {
        let url = home.appendingPathComponent("Library/Application Support/NetBar/ClashModes/manifest.json")
        let manifest = try JSONDecoder().decode(ClashModeManifest.self, from: Data(contentsOf: url))
        for mode in [ClashNetworkMode.companyCoexistence, .unifiedEgress] {
            let entry = try manifest.entry(for: mode)
            let file = URL(fileURLWithPath: manifest.configRoot).appendingPathComponent("profiles").appendingPathComponent(entry.profileFile)
            let data = try Data(contentsOf: file)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sourceSHA256 else {
                throw ClashModeFailure("\(entry.displayName) 源文件已变化，请刷新双配置登记后重试")
            }
            guard entry.expectedIPv6 != nil, entry.expectedDNSSHA256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  entry.expectedTunPolicy != nil,
                  Set(entry.expectedTunCaptureKeys ?? []) == Set(ClashTunPolicy.captureKeys),
                  entry.expectedTunCaptureSHA256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  (mode != .unifiedEgress || entry.expectedUnifiedMembersSHA256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil),
                  entry.expectedRulesSHA256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let scriptFile = entry.scriptFile, scriptFile == URL(fileURLWithPath: scriptFile).lastPathComponent,
                  !scriptFile.contains(".."), !scriptFile.contains("/"), scriptFile.hasSuffix(".js"),
                  let scriptDigest = entry.scriptSHA256,
                  let scriptData = try? Data(contentsOf: URL(fileURLWithPath: manifest.configRoot).appendingPathComponent("profiles").appendingPathComponent(scriptFile)),
                  SHA256.hash(data: scriptData).map({ String(format: "%02x", $0) }).joined() == scriptDigest else {
                throw ClashModeFailure("双配置脚本或完整规则摘要缺失/变化，请重新生成登记")
            }
        }
        return manifest
    }

    func runtime() throws -> ClashModeRuntime {
        let root = readOnlyConfigRoot()
        let profile = try readProfileRegistry(root: root)
        guard let config = json(access.read(path: "/configs")), let tun = config["tun"] as? [String: Any],
              let tunEnabled = tun["enable"] as? Bool, let ipv6 = config["ipv6"] as? Bool,
              let ruleObject = json(access.read(path: "/rules")), let rules = ruleObject["rules"] as? [[String: Any]],
              let proxyObject = json(access.read(path: "/proxies")), let proxies = proxyObject["proxies"] as? [String: [String: Any]] else {
            throw ClashModeFailure(access.failureDescription)
        }
        var selectors: [String: String] = [:], members: [String: [String]] = [:], types: [String: String] = [:]
        for (name, value) in proxies {
            types[name] = value["type"] as? String
            if let current = value["now"] as? String { selectors[name] = current }
            if let all = value["all"] as? [String] { members[name] = all }
        }
        let markers = Set(rules.compactMap { rule -> String? in
            guard (rule["type"] as? String)?.lowercased() == "domain", let payload = rule["payload"] as? String,
                  payload.hasPrefix("netbar-mode-"), let proxy = rule["proxy"] as? String else { return nil }
            return "DOMAIN,\(payload),\(proxy)"
        })
        let hijacks = tun["dns-hijack"] as? [String] ?? []
        let udp = hijacks.contains("any:53") || hijacks.contains("udp://any:53")
        let tcp = hijacks.contains("tcp://any:53")
        let port = config["mixed-port"] as? Int ?? 7897
        let ruleKeys = rules.map { rule -> [String] in
            let type = (rule["type"] as? String ?? "").replacingOccurrences(of: "-", with: "").uppercased().replacingOccurrences(of: "IPCIDR6", with: "IPCIDR")
            var payload = rule["payload"] as? String ?? ""
            if type.hasPrefix("DOMAIN") || type == "GEOIP" { payload = payload.lowercased() }
            return [type, payload, rule["proxy"] as? String ?? ""]
        }
        let ruleData = try JSONSerialization.data(withJSONObject: ruleKeys, options: [.withoutEscapingSlashes])
        let rulesSHA256 = SHA256.hash(data: ruleData).map { String(format: "%02x", $0) }.joined()
        let policy = ClashTunPolicy(autoRoute: tun["auto-route"] as? Bool ?? false, autoDetectInterface: tun["auto-detect-interface"] as? Bool ?? false,
                                    strictRoute: tun["strict-route"] as? Bool ?? false, dnsHijack: hijacks, routeExcludeAddress: tun["route-exclude-address"] as? [String] ?? [])
        let generated = try runtimeGeneratedPolicy(root: root)
        let dnsHash = generated.dnsSHA256
        let tunCaptureSHA256 = try ClashDNSPathEvidence.tunCaptureSHA256(generated.tun)
        // hit/miss counters and timestamps change with ordinary traffic. They
        // must never look like an external configuration write during CAS.
        let routingData = try JSONSerialization.data(withJSONObject: ["rules": ClashDNSPathEvidence.ruleConfiguration(rules), "ipv6": ipv6, "tun": ClashDNSPathEvidence.runtimeTunConfiguration(tun), "generatedTun": ClashDNSPathEvidence.normalizedTunConfiguration(generated.tun.filter { $0.key != "enable" }), "dnsHash": dnsHash], options: [.sortedKeys])
        let routingDigest = SHA256.hash(data: routingData).map { String(format: "%02x", $0) }.joined()
        return .init(profileUID: profile.current, tunEnabled: tunEnabled,
                     systemProxyEnabled: try systemProxyEnabled(port: port),
                     runtimeRuleMode: config["mode"] as? String == "rule", markers: markers,
                     selectors: selectors, members: members, proxyTypes: types,
                     hijacksUDPAndTCP: udp && tcp, ipv6Enabled: ipv6, routingDigest: routingDigest, rulesSHA256: rulesSHA256, dnsSHA256: dnsHash, tunPolicy: policy, tunCaptureSHA256: tunCaptureSHA256,
                     disabledRuleCount: rules.filter { ($0["extra"] as? [String: Any])?["disabled"] as? Bool == true }.count)
    }

    func assertCompanyVPNDisconnected() throws {
        let dns = BoundedCommand.run("/usr/sbin/scutil", ["--dns"], timeout: 2)
        let route = BoundedCommand.run("/sbin/route", ["-n", "get", "172.21.180.176"], timeout: 2)
        let nc = BoundedCommand.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 2)
        guard dns.exitCode == 0, route.exitCode == 0, nc.exitCode == 0 else { throw ClashModeFailure("公司隧道状态未知，统一保障条件未满足；请手动断开公司 VPN 后重试") }
        let protectedSuffixes = ["hq.cmcc", "js.cmcc", "rdcloud.indn", "js.chinamobile.com"]
        guard !protectedSuffixes.contains(where: { dns.stdout.lowercased().contains($0) }),
              !nc.stdout.split(separator: "\n").contains(where: { $0.contains("(Connected)") && !$0.localizedCaseInsensitiveContains("tailscale") }) else {
            throw ClashModeFailure("检测到公司或其他 VPN 隧道/专用解析，请先手动断开公司 VPN；NetBar 不会代为操作")
        }
        guard let line = route.stdout.split(separator: "\n").first(where: { $0.contains("interface:") }),
              let interface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              interface.hasPrefix("en") || interface.hasPrefix("bridge") else {
            throw ClashModeFailure("公司保护网段仍经隧道或状态未知，统一保障条件未满足")
        }
    }

    func verifyDNSPath(mode: ClashNetworkMode, entry: ClashModeManifest.Entry, leaf: String) throws {
        guard try manifest().entry(for: mode) == entry else { throw ClashModeFailure("双配置登记在切换期间变化") }
        let current = try runtime()
        guard current.tunEnabled, current.hijacksUDPAndTCP, current.rulesSHA256 == entry.expectedRulesSHA256, current.leaf(for: entry.targetGroup) == leaf else { throw ClashModeFailure("DNS 劫持配置未核验") }
        let route = BoundedCommand.run("/sbin/route", ["-n", "get", "114.114.114.114"], timeout: 2)
        guard route.exitCode == 0, route.stdout.split(separator: "\n").contains(where: { $0.contains("interface: utun") }) else { throw ClashModeFailure("DNS 目标路由未进入 TUN，DNS 路径未核验") }
        let suffix = mode == .companyCoexistence ? ".claude.ai" : ".cloudflare.com"
        // Observe existing connections; a read-only probe never closes them.
        let names = (0..<2).map { _ in "netbar-" + UUID().uuidString.lowercased() + suffix }
        let logs = try access.captureDebugLogs {
            for (index, transport) in ["+notcp", "+tcp"].enumerated() {
                let result = BoundedCommand.run("/usr/bin/dig", ["@114.114.114.114", names[index], "TXT", transport, "+time=2", "+tries=1", "+comments", "+noquestion", "+noanswer", "+noauthority", "+noadditional"], timeout: 3)
                guard result.exitCode == 0, result.stdout.contains("status: NOERROR") || result.stdout.contains("status: NXDOMAIN") else { throw ClashModeFailure("\(transport == "+tcp" ? "TCP" : "UDP") DNS 劫持查询未通过") }
            }
        }
        guard let upstreams = ClashDNSPathEvidence.freshUpstreams(logs: logs, names: names),
              let payload = json(access.read(path: "/connections")), let connections = ClashDNSPathEvidence.connections(in: payload),
              ClashDNSPathEvidence.confirmsChains(connections, upstreams: upstreams, group: entry.targetGroup, leaf: leaf) else {
            throw ClashModeFailure("未取得本轮随机 DNS 查询经 Cloudflare DoH 与选定节点的关联证据，DNS 保障未核验")
        }
    }

    func verifySystemHTTPS() throws {
        let dns = BoundedCommand.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "cp.cloudflare.com"], timeout: 4)
        guard dns.exitCode == 0, dns.stdout.contains("ip_address:") || dns.stdout.contains("ipv6_address:") else { throw ClashModeFailure("系统解析未通过") }
        let https = BoundedCommand.run("/usr/bin/curl", ["--noproxy", "*", "-sS", "--connect-timeout", "3", "--max-time", "6", "-o", "/dev/null", "-w", "%{http_code}", "https://cp.cloudflare.com/generate_204"], timeout: 7)
        guard https.exitCode == 0, https.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "204" else { throw ClashModeFailure("不带显式代理的系统 HTTPS 未通过") }
    }
    private func systemProxyEnabled(port: Int) throws -> Bool {
        guard let proxy = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { throw ClashModeFailure("系统代理状态未知") }
        return ["HTTP", "HTTPS", "SOCKS"].contains { scheme in
            let host = proxy[scheme + "Proxy"] as? String ?? ""
            return (proxy[scheme + "Enable"] as? NSNumber)?.boolValue == true &&
                ["127.0.0.1", "localhost", "::1"].contains(host) && (proxy[scheme + "Port"] as? NSNumber)?.intValue == port
        }
    }
    func networkFingerprint() throws -> String {
        let commands = [("/usr/sbin/scutil", ["--nwi"]), ("/usr/sbin/scutil", ["--dns"]), ("/sbin/route", ["-n", "get", "default"])]
        var parts: [String] = []
        for (command, args) in commands {
            let result = BoundedCommand.run(command, args, timeout: 2)
            guard result.exitCode == 0, !result.outputTruncated else { throw ClashModeFailure("网络身份未知，旧检测已失效") }
            parts.append(result.stdout)
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func json(_ data: Data?) -> [String: Any]? { guard let data else { return nil }; return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private func runtimeGeneratedPolicy(root: String) throws -> (dnsSHA256: String, tun: [String: Any]) {
        let script = "require 'yaml';require 'json';x=YAML.safe_load(File.read(ARGV[0]),aliases:true)||{};def canon(x);case x;when Hash;x.keys.sort.to_h{|k|[k,canon(x[k])]};when Array;x.map{|v|canon(v)};else;x;end;end;puts JSON.generate({dns:JSON.generate(canon(x['dns']||{})),tun:x['tun']||{}})"
        let result = BoundedCommand.run("/usr/bin/ruby", ["-e", script, URL(fileURLWithPath: root).appendingPathComponent("clash-verge.yaml").path], timeout: 2, outputLimit: 2_000_000)
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8), let generated = json(data), let dns = generated["dns"] as? String,
              let tun = generated["tun"] as? [String: Any] else { throw ClashModeFailure("无法核对已生成运行配置的 DNS/TUN 策略") }
        return (SHA256.hash(data: Data(dns.utf8)).map { String(format: "%02x", $0) }.joined(), tun)
    }
    private func readOnlyConfigRoot() -> String {
        let url = home.appendingPathComponent("Library/Application Support/NetBar/ClashModes/manifest.json")
        if let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(ClashModeManifest.self, from: data),
           [1, 2].contains(manifest.schemaVersion), manifest.configRoot.hasPrefix("/") { return manifest.configRoot }
        return home.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev").path
    }
    private func readProfileRegistry(root: String) throws -> ClashNativeProfileRegistry {
        let script = "require 'yaml';require 'json';x=YAML.safe_load(File.read(ARGV[0]),aliases:true)||{};puts JSON.dump({current:x['current'],names:(x['items']||[]).map{|i|[i['uid'],i['name']]}.to_h})"
        let result = BoundedCommand.run("/usr/bin/ruby", ["-e", script, URL(fileURLWithPath: root).appendingPathComponent("profiles.yaml").path], timeout: 2)
        guard result.exitCode == 0, !result.outputTruncated else {
            throw ClashModeFailure("无法读取 Clash 原生配置身份（\(result.outcome.rawValue)，exit \(result.exitCode)，truncated \(result.outputTruncated)）")
        }
        guard let data = result.stdout.data(using: .utf8), let value = try? JSONDecoder().decode(ClashNativeProfileRegistry.self, from: data) else { throw ClashModeFailure("Clash 原生配置身份格式无效，未执行切换") }
        return value
    }
}
#endif
