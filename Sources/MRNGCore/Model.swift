// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// A node in the connection tree: either a Container (folder) or a Connection.
public final class MRNGNode: Identifiable, Hashable {
    public static func == (lhs: MRNGNode, rhs: MRNGNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    public let id: String
    public let isContainer: Bool
    /// All raw XML attributes (kept for fidelity and round-trip on save).
    public var attributes: [String: String]
    public weak var parent: MRNGNode?
    public var children: [MRNGNode] = []

    /// Name is always read from attributes (stays in sync with edits).
    public var name: String { attributes["Name"] ?? "(no name)" }

    public init(id: String, name: String, isContainer: Bool, attributes: [String: String]) {
        self.id = id
        self.isContainer = isContainer
        self.attributes = attributes
        self.attributes["Name"] = name
    }

    // MARK: - Tree mutations (editing)

    public func addChild(_ node: MRNGNode, at index: Int? = nil) {
        node.parent?.children.removeAll { $0 === node }
        node.parent = self
        if let index, index >= 0, index <= children.count { children.insert(node, at: index) }
        else { children.append(node) }
    }

    public func removeFromParent() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    /// True if `ancestor` is a (strict) ancestor of this node — used to forbid
    /// moving a folder into itself.
    public func isDescendant(of ancestor: MRNGNode) -> Bool {
        var p = parent
        while let cur = p { if cur === ancestor { return true }; p = cur.parent }
        return false
    }

    public func setAttribute(_ key: String, _ value: String) {
        attributes[key] = value
    }

    public func deepCopy(name: String? = nil) -> MRNGNode {
        var copiedAttributes = attributes
        let copiedName = name ?? self.name
        copiedAttributes["Name"] = copiedName
        let copied = MRNGNode(
            id: UUID().uuidString.lowercased(),
            name: copiedName,
            isContainer: isContainer,
            attributes: copiedAttributes
        )
        for child in children {
            copied.addChild(child.deepCopy())
        }
        return copied
    }

    // MARK: - Factories for new nodes (with mRemoteNG default attributes)

    public static func makeConnection(name: String, protocolType: String = "RDP",
                                      hostname: String = "") -> MRNGNode {
        var a = defaultAttributes(container: false)
        a["Name"] = name
        a["Protocol"] = protocolType
        a["Hostname"] = hostname
        a["Port"] = defaultPortString(for: protocolType)
        return MRNGNode(id: UUID().uuidString.lowercased(), name: name, isContainer: false, attributes: a)
    }

    public static func makeContainer(name: String) -> MRNGNode {
        var a = defaultAttributes(container: true)
        a["Name"] = name
        return MRNGNode(id: UUID().uuidString.lowercased(), name: name, isContainer: true, attributes: a)
    }

    private static func defaultPortString(for proto: String) -> String {
        switch proto {
        case "SSH1", "SSH2": return "22"
        case "Telnet": return "23"
        case "VNC": return "5900"
        case "HTTP": return "80"
        case "HTTPS": return "443"
        default: return "3389"
        }
    }

    private static func defaultAttributes(container: Bool) -> [String: String] {
        var a: [String: String] = [
            "Type": container ? "Container" : "Connection",
            "Expanded": container ? "true" : "false",
            "Descr": "", "Icon": "mRemoteNG", "Panel": "General",
            "Username": "", "Domain": "", "Password": "", "Hostname": "",
            "Protocol": "RDP", "PuttySession": "Default Settings", "Port": "3389",
            "ConnectToConsole": "false", "UseCredSsp": "true", "RenderingEngine": "IE",
            "ICAEncryptionStrength": "EncrBasic", "RDPAuthenticationLevel": "NoAuth",
            "RDPMinutesToIdleTimeout": "0", "RDPAlertIdleTimeout": "false", "LoadBalanceInfo": "",
            "Colors": "Colors16Bit", "Resolution": "FitToWindow", "AutomaticResize": "true",
            "DisplayWallpaper": "false", "DisplayThemes": "false", "EnableFontSmoothing": "false",
            "EnableDesktopComposition": "false", "CacheBitmaps": "false", "RedirectDiskDrives": "false",
            "RedirectPorts": "false", "RedirectPrinters": "false", "RedirectSmartCards": "false",
            "RedirectSound": "DoNotPlay", "SoundQuality": "Dynamic", "RedirectKeys": "false",
            "Connected": "false", "PreExtApp": "", "PostExtApp": "", "MacAddress": "",
            "UserField": "", "ExtApp": "", "VNCCompression": "CompNone", "VNCEncoding": "EncHextile",
            "VNCAuthMode": "AuthVNC", "VNCProxyType": "ProxyNone", "VNCProxyIP": "",
            "VNCProxyPort": "0", "VNCProxyUsername": "", "VNCProxyPassword": "", "VNCColors": "ColNormal",
            "VNCSmartSizeMode": "SmartSAspect", "VNCViewOnly": "false", "RDGatewayUsageMethod": "Never",
            "RDGatewayHostname": "", "RDGatewayUseConnectionCredentials": "Yes", "RDGatewayUsername": "",
            "RDGatewayPassword": "", "RDGatewayDomain": "",
            "ProxyJump": "", "ProxyJumpPassword": "",
        ]
        let inheritFalse = [
            "InheritCacheBitmaps", "InheritColors", "InheritDescription", "InheritDisplayThemes",
            "InheritDisplayWallpaper", "InheritEnableFontSmoothing", "InheritEnableDesktopComposition",
            "InheritDomain", "InheritIcon", "InheritPanel", "InheritPassword", "InheritPort",
            "InheritProtocol", "InheritPuttySession", "InheritRedirectDiskDrives", "InheritRedirectKeys",
            "InheritRedirectPorts", "InheritRedirectPrinters", "InheritRedirectSmartCards",
            "InheritRedirectSound", "InheritSoundQuality", "InheritResolution", "InheritAutomaticResize",
            "InheritUseConsoleSession", "InheritUseCredSsp", "InheritRenderingEngine", "InheritUsername",
            "InheritICAEncryptionStrength", "InheritRDPAuthenticationLevel",
            "InheritRDPMinutesToIdleTimeout", "InheritRDPAlertIdleTimeout", "InheritLoadBalanceInfo",
            "InheritPreExtApp", "InheritPostExtApp", "InheritMacAddress", "InheritUserField",
            "InheritExtApp", "InheritVNCCompression", "InheritVNCEncoding", "InheritVNCAuthMode",
            "InheritVNCProxyType", "InheritVNCProxyIP", "InheritVNCProxyPort", "InheritVNCProxyUsername",
            "InheritVNCProxyPassword", "InheritVNCColors", "InheritVNCSmartSizeMode", "InheritVNCViewOnly",
            "InheritRDGatewayUsageMethod", "InheritRDGatewayHostname",
            "InheritRDGatewayUseConnectionCredentials", "InheritRDGatewayUsername",
            "InheritRDGatewayPassword", "InheritRDGatewayDomain", "InheritProxyJump",
        ]
        for k in inheritFalse { a[k] = "false" }
        return a
    }

    /// Resolve an attribute taking inheritance from the parent into account
    /// (Inherit<flag>="true").
    public func resolved(_ key: String, inheritKey: String) -> String? {
        if attributes[inheritKey] == "true", let parent = parent {
            return parent.resolved(key, inheritKey: inheritKey)
        }
        return attributes[key]
    }

    // Accessors with inheritance for the fields relevant at connect/display time.
    public var protocolType: String { resolved("Protocol", inheritKey: "InheritProtocol") ?? "RDP" }
    public var hostname: String { attributes["Hostname"] ?? "" } // mRemoteNG has no InheritHostname
    public var port: Int { Int(resolved("Port", inheritKey: "InheritPort") ?? "") ?? defaultPort }
    public var username: String { resolved("Username", inheritKey: "InheritUsername") ?? "" }
    public var domain: String { resolved("Domain", inheritKey: "InheritDomain") ?? "" }
    public var encryptedPassword: String { resolved("Password", inheritKey: "InheritPassword") ?? "" }
    public var puttySession: String { resolved("PuttySession", inheritKey: "InheritPuttySession") ?? "" }
    public var descr: String { resolved("Descr", inheritKey: "InheritDescription") ?? "" }
    public var icon: String { resolved("Icon", inheritKey: "InheritIcon") ?? "mRemoteNG" }
    public var panel: String { resolved("Panel", inheritKey: "InheritPanel") ?? "" }
    public var expanded: Bool { attributes["Expanded"] == "true" }
    public var externalApp: String { resolved("ExtApp", inheritKey: "InheritExtApp") ?? "" }
    /// Encrypted TOTP (2FA) secret, mRemoteNXT-extension attribute — no
    /// inheritance, same as a per-connection Password.
    public var encryptedTOTPSecret: String { attributes["TOTPSecret"] ?? "" }

    /// SSH local port forwards (`ssh -L`), one per line as
    /// "localPort:remoteHost:remotePort" — Almac Remote extension attribute,
    /// applied when this connection is used as an SSH jump host.
    public var sshLocalForwardsRaw: String { attributes["SSHLocalForwards"] ?? "" }
    public var sshLocalForwards: [String] {
        sshLocalForwardsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// SSH jump host this connection should tunnel through before connecting
    /// (any protocol — RDP, SSH, Telnet, HTTP), as "user@host[:port]".
    /// Almac Remote extension attribute; inheritable from a parent folder so
    /// it can be set once for a whole group of connections.
    public var proxyJump: String { resolved("ProxyJump", inheritKey: "InheritProxyJump") ?? "" }
    /// Encrypted password for the jump host, same scheme as the connection Password.
    public var encryptedProxyJumpPassword: String { resolved("ProxyJumpPassword", inheritKey: "InheritProxyJump") ?? "" }

    /// Default port per protocol when none is specified.
    private var defaultPort: Int {
        switch protocolType {
        case "SSH1", "SSH2": return 22
        case "Telnet": return 23
        case "RDP": return 3389
        case "VNC": return 5900
        case "HTTP": return 80
        case "HTTPS": return 443
        case "Rlogin": return 513
        default: return 0
        }
    }
}

/// Parses a `ProxyJump` value ("user@host[:port]") into its parts.
public struct ProxyJumpTarget {
    public let user: String
    public let host: String
    public let port: Int

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let userSplit = trimmed.split(separator: "@", maxSplits: 1)
        let userPart = userSplit.count == 2 ? String(userSplit[0]) : ""
        let hostPort = String(userSplit.count == 2 ? userSplit[1] : userSplit[0])
        guard !hostPort.isEmpty else { return nil }
        let hostSplit = hostPort.split(separator: ":", maxSplits: 1)
        guard let hostOnly = hostSplit.first, !hostOnly.isEmpty else { return nil }
        let port = hostSplit.count == 2 ? Int(hostSplit[1]) ?? 22 : 22
        user = userPart
        host = String(hostOnly)
        self.port = port
    }
}

/// The confCons.xml document: encryption parameters + the array of root nodes.
public struct ConfCons {
    public var encryptionEngine: String
    public var blockCipherMode: String
    public var kdfIterations: Int
    public var fullFileEncryption: Bool
    public var protected: String
    public var confVersion: String
    public var roots: [MRNGNode]

    public init(encryptionEngine: String, blockCipherMode: String, kdfIterations: Int,
                fullFileEncryption: Bool, protected: String, confVersion: String,
                roots: [MRNGNode]) {
        self.encryptionEngine = encryptionEngine
        self.blockCipherMode = blockCipherMode
        self.kdfIterations = kdfIterations
        self.fullFileEncryption = fullFileEncryption
        self.protected = protected
        self.confVersion = confVersion
        self.roots = roots
    }

    /// All nodes (DFS), containers included.
    public func allNodes() -> [MRNGNode] {
        var out: [MRNGNode] = []
        func walk(_ n: MRNGNode) { out.append(n); n.children.forEach(walk) }
        roots.forEach(walk)
        return out
    }
}
