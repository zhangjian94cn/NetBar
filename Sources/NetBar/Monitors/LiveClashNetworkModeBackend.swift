#if !APP_STORE
import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import NetworkExecution

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
        Dictionary(uniqueKeysWithValues: (ClashTunPolicy.captureKeys + ["stack", "mtu"]).map { ($0, tun[$0] ?? NSNull()) })
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
        let projection = Dictionary(uniqueKeysWithValues: ClashTunPolicy.captureKeys.map { ($0, tun[$0] ?? NSNull()) })
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

/// Fixed native AX surface for Clash Verge Rev. No generic script execution, file
/// current-UID edits, synthesized shortcuts or configuration mutation via HTTP.
final class ClashNativeProfileAdapter {
    private let supportedVersion = "2.5.8"
    private let bundleID = "io.github.clash-verge-rev.clash-verge-rev"

    func checkAccess() throws {
        guard AXIsProcessTrusted() else { throw ClashModeFailure("需要在系统设置 → 隐私与安全性 → 辅助功能中允许 NetBar；授权后重新选择模式") }
        _ = try application()
    }

    func activate(profileUID: String, displayName: String) throws {
        try checkAccess()
        guard !profileUID.isEmpty, !displayName.isEmpty else { throw ClashModeFailure("配置身份缺失") }
        let app = try application()
        if try pressTrayItem(in: app, identifiers: ["profiles_" + profileUID], titles: [displayName]) { return }
        // Native subscriptions page fallback. Only a unique registered title is allowed.
        bringForward()
        guard let subscription = find(in: app, matching: { normalizedTitle($0) == "订阅" && role($0) == kAXButtonRole as String }) else {
            throw ClashModeFailure("Clash 原生订阅入口不可用，未切换配置")
        }
        try press(subscription)
        guard let heading = waitFind(in: app, matching: { title($0) == displayName && role($0) == "AXHeading" }) else {
            throw ClashModeFailure("Clash 尚未登记目标配置，请先原生导入双配置")
        }
        var candidate: AXUIElement? = heading
        for _ in 0..<4 {
            guard let element = candidate else { break }
            if hasAction(element, kAXPressAction as String) { try press(element); return }
            candidate = axAttribute(element, kAXParentAttribute as String)
        }
        // Tauri v2.5.8 exposes profile cards as headings rather than buttons.
        // The center comes from this verified heading, never a saved coordinate.
        try clickKnownElement(heading)
    }

    func reactivate() throws {
        try checkAccess()
        let app = try application()
        bringForward()
        guard let subscription = find(in: app, matching: { normalizedTitle($0) == "订阅" && role($0) == kAXButtonRole as String }) else { throw ClashModeFailure("原生订阅入口不可用") }
        try press(subscription)
        guard let reload = waitFind(in: app, matching: { ["重新激活订阅", "Reactivate Profiles", "Reactivate Profile"].contains(title($0)) && role($0) == kAXButtonRole as String }) else { throw ClashModeFailure("原生重新激活入口不可用") }
        try press(reload)
    }

    func setTunPolicy(_ policy: ClashTunPolicy) throws {
        try checkAccess()
        let app = try application()
        bringForward()
        // A single supported settings dialog is the only editable surface.
        if find(in: app, matching: { title($0) == "DNS 劫持" }) == nil {
            try openSettings(in: app)
            // v2.5.8 labels the heading, while the adjacent gear button exposes
            // only its tooltip. Bind by the verified row rather than that tooltip.
            guard let tun = followingControl("虚拟网卡模式", root: app, role: kAXButtonRole as String) else { throw ClashModeFailure("Clash 原生 TUN 高级设置入口不可用") }
            try press(tun)
        }
        guard waitFind(in: app, matching: { title($0) == "DNS 劫持" }) != nil else { throw ClashModeFailure("TUN 设置弹窗未打开") }
        var saved = false
        defer {
            if !saved, let cancel = find(in: app, matching: { title($0) == "取消" && role($0) == kAXButtonRole as String }) { try? press(cancel) }
        }
        try setFollowingLabel("自动设置全局路由", root: app, role: "AXSwitch", value: NSNumber(value: policy.autoRoute))
        try setFollowingLabel("严格路由", root: app, role: "AXSwitch", value: NSNumber(value: policy.strictRoute))
        try setFollowingLabel("自动选择流量出口接口", root: app, role: "AXSwitch", value: NSNumber(value: policy.autoDetectInterface))
        try setFollowingLabel("DNS 劫持", root: app, role: kAXTextFieldRole as String, value: policy.dnsHijack.joined(separator: ",") as NSString)
        if followingControl("排除自定义网段", root: app, role: kAXTextAreaRole as String) == nil {
            guard let toggle = find(in: app, matching: { title($0) == "排除自定义网段" && role($0) == kAXButtonRole as String }) else { throw ClashModeFailure("排除网段编辑入口不可用") }
            try press(toggle)
        }
        try setFollowingLabel("排除自定义网段", root: app, role: kAXTextAreaRole as String, value: policy.routeExcludeAddress.joined(separator: ",") as NSString)
        guard let save = find(in: app, matching: { title($0) == "保存" && role($0) == kAXButtonRole as String }) else { throw ClashModeFailure("原生 TUN 保存按钮不可用") }
        try press(save)
        saved = true
    }

    private func setFollowingLabel(_ label: String, root: AXUIElement, role wantedRole: String, value: CFTypeRef) throws {
        guard let control = followingControl(label, root: root, role: wantedRole) else { throw ClashModeFailure("原生字段不可用：" + label) }
        if let boolean = value as? NSNumber, wantedRole == "AXSwitch" {
            let current = (attribute(control, kAXValueAttribute as String) as? NSNumber)?.boolValue
            if current == boolean.boolValue { return }
            try press(control)
        } else {
            guard AXUIElementSetAttributeValue(control, kAXValueAttribute as CFString, value) == .success else { throw ClashModeFailure("无法填写原生字段：" + label) }
        }
    }

    private func followingControl(_ label: String, root: AXUIElement, role wantedRole: String) -> AXUIElement? {
        let all = flatten(root)
        guard let index = all.firstIndex(where: { title($0) == label && role($0) != kAXButtonRole as String }),
              let control = all.dropFirst(index + 1).prefix(8).first(where: { role($0) == wantedRole }) else { return nil }
        return control
    }

    private func flatten(_ root: AXUIElement) -> [AXUIElement] {
        var pending: [(AXUIElement, Int)] = [(root, 0)], output: [AXUIElement] = []
        while let (element, depth) = pending.popLast(), output.count < 2500 {
            output.append(element)
            if depth < 20 {
                let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
                pending += children.reversed().map { ($0, depth + 1) }
            }
        }
        return output
    }

    func setTun(_ enabled: Bool) throws {
        try checkAccess()
        let app = try application()
        if try pressTrayItem(in: app, identifiers: ["tray_tun_mode"], titles: ["虚拟网卡模式", "TUN 模式", "Tun Mode", "TUN Mode"]) { return }
        bringForward()
        try openSettings(in: app)
        try setFollowingLabel("虚拟网卡模式", root: app, role: "AXSwitch", value: NSNumber(value: enabled))
    }

    func toggleSystemProxy() throws {
        try checkAccess()
        let app = try application()
        if try pressTrayItem(in: app, identifiers: ["tray_system_proxy"], titles: ["系统代理", "System Proxy"]) { return }
        bringForward()
        try openSettings(in: app)
        guard let control = followingControl("系统代理", root: app, role: "AXSwitch") else { throw ClashModeFailure("Clash 原生系统代理开关不可用") }
        try press(control)
    }

    private func openSettings(in app: AXUIElement) throws {
        guard let settings = find(in: app, matching: { normalizedTitle($0) == "设置" && role($0) == kAXButtonRole as String }) else { throw ClashModeFailure("Clash 原生设置入口不可用") }
        try press(settings)
        guard waitFind(in: app, matching: { title($0) == "虚拟网卡模式" && role($0) == "AXHeading" }) != nil else { throw ClashModeFailure("Clash 原生设置页面未就绪") }
    }

    private func application() throws -> AXUIElement {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let bundleURL = process.bundleURL, let bundle = Bundle(url: bundleURL),
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == supportedVersion else {
            throw ClashModeFailure("原生配置适配器当前仅验证 Clash Verge Rev 2.5.8，应用未运行或版本不匹配")
        }
        let element = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.7)
        return element
    }

    private func bringForward() {
        let work = { NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID).first?.activate(options: [.activateIgnoringOtherApps]) }
        if Thread.isMainThread { _ = work() } else { DispatchQueue.main.sync { _ = work() } }
    }

    private func pressTrayItem(in app: AXUIElement, identifiers: Set<String>, titles: Set<String>) throws -> Bool {
        let match: (AXUIElement) -> Bool = { element in
            guard self.role(element) == kAXMenuItemRole as String else { return false }
            let identifier = self.attribute(element, kAXIdentifierAttribute as String) as? String ?? ""
            return identifiers.contains(identifier) || titles.contains(self.title(element))
        }
        if let found = find(in: app, matching: match) { try press(found); return true }
        guard let extras = axAttribute(app, "AXExtrasMenuBar") else { return false }
        let children = attribute(extras, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
        guard children.count == 1, let statusItem = children.first else { return false }
        let opened = AXUIElementPerformAction(statusItem, kAXShowMenuAction as CFString)
        if opened != .success { try clickKnownElement(statusItem, rightButton: true) }
        defer { _ = AXUIElementPerformAction(statusItem, kAXCancelAction as CFString) }
        if let item = waitFind(in: extras, matching: match) ?? waitFind(in: app, matching: match) { try press(item); return true }
        // Open only the profiles submenu; never traverse unrelated commands.
        if let submenu = find(in: extras, matching: { ["配置文件", "配置", "Profiles"].contains(self.title($0)) && self.role($0) == kAXMenuItemRole as String }) {
            _ = AXUIElementPerformAction(submenu, kAXPressAction as CFString)
            if let item = waitFind(in: submenu, matching: match) { try press(item); return true }
        }
        return false
    }

    private func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute as String) as? String ?? attribute(element, kAXDescriptionAttribute as String) as? String ?? ""
    }
    private func normalizedTitle(_ element: AXUIElement) -> String { title(element).filter { !$0.isWhitespace } }
    private func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute as String) as? String ?? "" }
    private func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private func axAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let result = attribute(element, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private func hasAction(_ element: AXUIElement, _ action: String) -> Bool {
        var values: CFArray?
        guard AXUIElementCopyActionNames(element, &values) == .success else { return false }
        return (values as? [String] ?? []).contains(action)
    }
    private func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw ClashModeFailure("原生辅助功能动作未完成，未确认配置生效") }
    }
    private func clickKnownElement(_ element: AXUIElement, rightButton: Bool = false) throws {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID,
              let position = attribute(element, kAXPositionAttribute as String),
              let size = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw ClashModeFailure("无法确定已核验原生控件的位置，未执行点击")
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { throw ClashModeFailure("原生控件不可见") }
        let center = CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
        let button: CGMouseButton = rightButton ? .right : .left
        guard let down = CGEvent(mouseEventSource: nil, mouseType: rightButton ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: center, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: rightButton ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: center, mouseButton: button) else {
            throw ClashModeFailure("原生点击无法创建")
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func waitFind(in root: AXUIElement, matching: (AXUIElement) -> Bool) -> AXUIElement? {
        for attempt in 0..<5 {
            if let result = find(in: root, matching: matching) { return result }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.15) }
        }
        return nil
    }
    private func find(in root: AXUIElement, matching: (AXUIElement) -> Bool) -> AXUIElement? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var found: AXUIElement?
        while let (element, depth) = pending.popLast(), visited < 2500 {
            visited += 1
            if matching(element) {
                // Ambiguous names never choose an arbitrary command.
                if found != nil { return nil }
                found = element
            }
            guard depth < 20 else { continue }
            let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
            pending += children.reversed().map { ($0, depth + 1) }
        }
        return found
    }
}

final class LiveClashNetworkModeBackend: ClashNetworkModeBackend {
    private let access = MihomoControllerAccess()
    private let native = ClashNativeProfileAdapter()
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let helper = "/Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper"

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
        let routingData = try JSONSerialization.data(withJSONObject: ["rules": ClashDNSPathEvidence.ruleConfiguration(rules), "ipv6": ipv6, "tun": ClashDNSPathEvidence.runtimeTunConfiguration(tun), "generatedTun": generated.tun.filter { $0.key != "enable" }, "dnsHash": dnsHash], options: [.sortedKeys])
        let routingDigest = SHA256.hash(data: routingData).map { String(format: "%02x", $0) }.joined()
        return .init(profileUID: profile.current, tunEnabled: tunEnabled,
                     systemProxyEnabled: LiveSystemProxyInspector().isEnabled(expectedPort: port),
                     runtimeRuleMode: config["mode"] as? String == "rule", markers: markers,
                     selectors: selectors, members: members, proxyTypes: types,
                     hijacksUDPAndTCP: udp && tcp, ipv6Enabled: ipv6, routingDigest: routingDigest, rulesSHA256: rulesSHA256, dnsSHA256: dnsHash, tunPolicy: policy, tunCaptureSHA256: tunCaptureSHA256,
                     disabledRuleCount: rules.filter { ($0["extra"] as? [String: Any])?["disabled"] as? Bool == true }.count)
    }

    func dnsStatus() throws -> ClashDNSLeaseStatus { try dnsAction("dns-status") }
    func acquireDNS() throws { let value = try dnsAction("dns-acquire"); guard value.ownedByThisProcess else { throw ClashModeFailure(value.reason ?? "DNS 未由本进程持有") } }
    func releaseDNS() throws {
        let value = try dnsAction("dns-release")
        guard value.dnsLeaseState == "inactive" else { throw ClashModeFailure(value.reason ?? "DNS 恢复存在冲突") }
    }

    private func dnsAction(_ action: String) throws -> ClashDNSLeaseStatus {
        let result = BoundedCommand.run("/usr/bin/sudo", ["-n", helper, action], timeout: action == "dns-acquire" ? 22 : 8)
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8),
              let value = try? JSONDecoder().decode(ClashDNSLeaseStatus.self, from: data), value.protocolVersion >= 6 else {
            throw ClashModeFailure("DNS 恢复组件未安装、需更新或无授权；请先安装/更新 Route Safety Helper")
        }
        return value
    }

    func assertCompanyVPNDisconnected() throws {
        let dns = BoundedCommand.run("/usr/sbin/scutil", ["--dns"], timeout: 2)
        let route = BoundedCommand.run("/sbin/route", ["-n", "get", "172.21.180.176"], timeout: 2)
        let nc = BoundedCommand.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 2)
        guard dns.exitCode == 0, route.exitCode == 0, nc.exitCode == 0 else { throw ClashModeFailure("公司隧道状态未知，统一模式未执行；请手动断开公司 VPN 后重试") }
        let protectedSuffixes = ["hq.cmcc", "js.cmcc", "rdcloud.indn", "js.chinamobile.com"]
        guard !protectedSuffixes.contains(where: { dns.stdout.lowercased().contains($0) }),
              !nc.stdout.split(separator: "\n").contains(where: { $0.contains("(Connected)") && !$0.localizedCaseInsensitiveContains("tailscale") }) else {
            throw ClashModeFailure("检测到公司或其他 VPN 隧道/专用解析，请先手动断开公司 VPN；NetBar 不会代为操作")
        }
        guard let line = route.stdout.split(separator: "\n").first(where: { $0.contains("interface:") }),
              let interface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              interface.hasPrefix("en") || interface.hasPrefix("bridge") else {
            throw ClashModeFailure("公司保护网段仍经隧道或状态未知，统一模式未执行")
        }
    }

    func activate(_ entry: ClashModeManifest.Entry) throws {
        let manifest = try manifest()
        guard manifest.modes.contains(entry) else { throw ClashModeFailure("目标配置登记已变化") }
        let registry = try readProfileRegistry(root: manifest.configRoot)
        guard registry.names[entry.profileUID] == entry.displayName,
              registry.names.values.filter({ $0 == entry.displayName }).count == 1 else { throw ClashModeFailure("原生配置 UID/名称登记不一致") }
        if registry.current == entry.profileUID { try native.reactivate() }
        else { try native.activate(profileUID: entry.profileUID, displayName: entry.displayName) }
        try waitUntil {
            let current = try self.runtime()
            return current.profileUID == entry.profileUID && current.rulesSHA256 == entry.expectedRulesSHA256
        }
    }

    func restoreProfile(_ uid: String) throws {
        let registry = try readProfileRegistry(root: readOnlyConfigRoot())
        guard let name = registry.names[uid], registry.names.values.filter({ $0 == name }).count == 1 else { throw ClashModeFailure("原配置身份无法核实") }
        try native.activate(profileUID: uid, displayName: name)
        try waitUntil { try self.runtime().profileUID == uid }
    }

    func setNativeTunPolicy(_ policy: ClashTunPolicy) throws {
        try native.setTunPolicy(policy)
        try waitUntil { try self.runtime().tunPolicy?.matches(policy) == true }
    }

    func setNativeSwitch(tun: Bool, proxy: Bool) throws {
        var current = try runtime()
        if current.tunEnabled != tun {
            try native.setTun(tun)
            try waitUntil { try self.runtime().tunEnabled == tun }
        }
        current = try runtime()
        if current.systemProxyEnabled != proxy {
            try native.toggleSystemProxy()
            try waitUntil { try self.runtime().systemProxyEnabled == proxy }
        }
    }

    func select(group: String, node: String) throws {
        let current = try runtime()
        guard current.members[group]?.contains(node) == true else { throw ClashModeFailure("节点已不在目标组中") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = group.addingPercentEncoding(withAllowedCharacters: allowed),
              let data = try? JSONSerialization.data(withJSONObject: ["name": node]), let body = String(data: data, encoding: .utf8),
              access.write(method: "PUT", path: "/proxies/" + encoded, body: body) else { throw ClashModeFailure("Clash 拒绝节点选择") }
        try waitUntil { try self.runtime().selectors[group] == node }
    }

    func verifyDNSPath(mode: ClashNetworkMode, entry: ClashModeManifest.Entry, leaf: String) throws {
        guard try manifest().entry(for: mode) == entry else { throw ClashModeFailure("双配置登记在切换期间变化") }
        let current = try runtime()
        guard current.tunEnabled, current.hijacksUDPAndTCP, current.rulesSHA256 == entry.expectedRulesSHA256, current.leaf(for: entry.targetGroup) == leaf else { throw ClashModeFailure("DNS 劫持配置未核验") }
        let route = BoundedCommand.run("/sbin/route", ["-n", "get", "223.5.5.5"], timeout: 2)
        guard route.exitCode == 0, route.stdout.split(separator: "\n").contains(where: { $0.contains("interface: utun") }) else { throw ClashModeFailure("DNS 目标路由未进入 TUN，未接管系统 DNS") }
        let suffix = mode == .companyCoexistence ? ".claude.ai" : ".cloudflare.com"
        // A reused DoH connection can retain the previous node after a selector change.
        // Close only fixed Cloudflare DNS connections belonging to our two groups.
        guard let before = json(access.read(path: "/connections")), let oldConnections = before["connections"] as? [[String: Any]] else { throw ClashModeFailure("无法读取 DNS 上游连接") }
        for connection in oldConnections where ClashDNSPathEvidence.isManagedDoH(connection) {
            guard let id = connection["id"] as? String, id.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil,
                  access.write(method: "DELETE", path: "/connections/" + id) else { throw ClashModeFailure("旧 DNS 上游连接未安全释放") }
        }
        let names = (0..<2).map { _ in "netbar-" + UUID().uuidString.lowercased() + suffix }
        let logs = try access.captureDebugLogs {
            for (index, transport) in ["+notcp", "+tcp"].enumerated() {
                let result = BoundedCommand.run("/usr/bin/dig", ["@223.5.5.5", names[index], "TXT", transport, "+time=2", "+tries=1", "+comments", "+noquestion", "+noanswer", "+noauthority", "+noadditional"], timeout: 3)
                guard result.exitCode == 0, result.stdout.contains("status: NOERROR") || result.stdout.contains("status: NXDOMAIN") else { throw ClashModeFailure("\(transport == "+tcp" ? "TCP" : "UDP") DNS 劫持查询未通过") }
            }
        }
        guard let upstreams = ClashDNSPathEvidence.freshUpstreams(logs: logs, names: names),
              let payload = json(access.read(path: "/connections")), let connections = payload["connections"] as? [[String: Any]],
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
    func closeConnections() throws {
        guard let payload = json(access.read(path: "/connections")), let connections = payload["connections"] as? [[String: Any]] else { throw ClashModeFailure("旧公网连接清理状态未知") }
        let context = ProbeContext(timeout: 6)
        let generated = try runtimeGeneratedPolicy(root: readOnlyConfigRoot())
        let protectedCIDRs = ["route-exclude-address", "inet4-route-exclude-address", "inet6-route-exclude-address"].flatMap { generated.tun[$0] as? [String] ?? [] }
        try ProbeContext.withValue(context) {
            for connection in connections where ClashDNSPathEvidence.isAffectedPublicConnection(connection, protectedCIDRs: protectedCIDRs) {
                guard let id = connection["id"] as? String, id.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil,
                      access.write(method: "DELETE", path: "/connections/" + id) else { throw ClashModeFailure("受影响的旧公网连接未全部释放") }
            }
        }
    }

    private func json(_ data: Data?) -> [String: Any]? { guard let data else { return nil }; return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private func waitUntil(_ condition: () throws -> Bool) throws {
        for attempt in 0..<12 {
            if try condition() { return }
            if attempt < 11 { Thread.sleep(forTimeInterval: 0.2) }
        }
        throw ClashModeFailure("原生激活超时，实际状态尚未核验")
    }
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
           manifest.schemaVersion == 1, manifest.configRoot.hasPrefix("/") { return manifest.configRoot }
        return home.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev").path
    }
    private func readProfileRegistry(root: String) throws -> ClashNativeProfileRegistry {
        let script = "require 'yaml';require 'json';x=YAML.safe_load(File.read(ARGV[0]),aliases:true)||{};puts JSON.dump({current:x['current'],names:(x['items']||[]).map{|i|[i['uid'],i['name']]}.to_h})"
        let result = BoundedCommand.run("/usr/bin/ruby", ["-e", script, URL(fileURLWithPath: root).appendingPathComponent("profiles.yaml").path], timeout: 2)
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8), let value = try? JSONDecoder().decode(ClashNativeProfileRegistry.self, from: data) else { throw ClashModeFailure("无法读取 Clash 原生配置身份") }
        return value
    }
}
#endif
