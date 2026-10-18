import Foundation
import CryptoKit
import IOKit

/// 授权配置。服务端地址可在 Info.plist 里用 `LicenseServerURL` 覆盖。
enum LicenseConfig {
    static let defaultServerURL = "https://licensevate-api-xiaazgezpn.cn-hangzhou.fcapp.run"
    /// 服务端签名私钥对应的 Ed25519 公钥（base64，32 字节）。
    static let publicKeyBase64 = "QSrOx0sDlQw/AQvyqSnf0lPAbBdi9iI0oqjHbNfcxSM="
    /// 产品标识（小写）。多款软件共用同一服务端与密钥，用它区分授权。
    static let product = "supperrightclick"
    static let trialDuration: TimeInterval = 24 * 3600
    static let machineSalt = "SuperRightClick|v1|"

    static var serverURL: URL? {
        let s = (Bundle.main.object(forInfoDictionaryKey: "LicenseServerURL") as? String) ?? defaultServerURL
        return URL(string: s)
    }
}

enum LicenseStatus: Equatable {
    case licensed(expires: Date?)      // expires == nil：永久
    case licenseExpired
    case trialAvailable                // 还没开始试用
    case trial(remaining: TimeInterval)
    case trialExpired

    var isUsable: Bool {
        switch self {
        case .licensed, .trial: return true
        default: return false
        }
    }
}

enum ActivationResult {
    case success
    case rejected(String)   // 服务端明确拒绝
    case network(String)    // 网络/服务异常
}

/// 服务端签发的授权凭证：payload 为 "v2|product|code|machine|expiresAt|issuedAt"，sig 为其 Ed25519 签名。
private struct StoredLicense: Codable {
    var code: String
    var payload: String
    var sig: String
}

private struct LocalState: Codable {
    var trialStart: TimeInterval?
    var lastSeen: TimeInterval
}

final class LicenseManager {
    static let shared = LicenseManager()

    private let queue = DispatchQueue(label: "license.state")
    private var license: StoredLicense?
    private var expiresAt: TimeInterval = 0      // 0：永久
    private var state = LocalState(trialStart: nil, lastSeen: 0)
    private var lastPersisted: TimeInterval = 0

    private let defaultsKey = "com.superrightclick.state"
    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SuperRightClick", isDirectory: true)
    }()
    private var licenseFile: URL { dir.appendingPathComponent("license.json") }
    private var stateFile: URL { dir.appendingPathComponent(".state") }

    private init() { load() }

    // MARK: - 机器 ID

    /// 本机 ID：IOPlatformUUID 加盐后的 SHA256，不上传原始硬件 UUID。
    lazy var machineID: String = {
        var raw = "unknown"
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            if let v = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                raw = v
            }
            IOObjectRelease(service)
        }
        let digest = SHA256.hash(data: Data((LicenseConfig.machineSalt + raw).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    var licenseCode: String? { queue.sync { license?.code } }

    // MARK: - 状态

    /// 「当前时间」取系统时间与历史最晚时间的较大值，防止回拨时钟延长试用/授权。
    private func trustedNow() -> TimeInterval {
        max(Date().timeIntervalSince1970, state.lastSeen)
    }

    func status() -> LicenseStatus {
        queue.sync {
            let now = trustedNow()
            if license != nil {
                if expiresAt == 0 { return .licensed(expires: nil) }
                if now < expiresAt { return .licensed(expires: Date(timeIntervalSince1970: expiresAt)) }
                return .licenseExpired
            }
            guard let start = state.trialStart else { return .trialAvailable }
            let remaining = start + LicenseConfig.trialDuration - now
            return remaining > 0 ? .trial(remaining: remaining) : .trialExpired
        }
    }

    /// 每秒调用：推进 lastSeen（至多每分钟落盘一次）。
    func touch() {
        queue.sync {
            let now = max(Date().timeIntervalSince1970, state.lastSeen)
            state.lastSeen = now
            if now - lastPersisted >= 60 { persistState() }
        }
    }

    func startTrialIfNeeded() {
        queue.sync {
            if state.trialStart == nil {
                state.trialStart = trustedNow()
                persistState()
            }
        }
    }

    // MARK: - 在线激活 / 续期

    /// 上传授权码 + 本机 ID 到服务端校验。成功后凭证落盘，之后不再联网。
    func activate(code: String, completion: @escaping (ActivationResult) -> Void) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return completion(.rejected("请输入授权码")) }
        guard let url = LicenseConfig.serverURL else { return completion(.network("授权服务器地址无效")) }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "action": "activate",
            "product": LicenseConfig.product,
            "code": normalized,
            "machine": machineID,
            "name": Host.current().localizedName ?? "",
            "app": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            let result: ActivationResult
            if let error {
                result = .network("无法连接授权服务器：\(error.localizedDescription)")
            } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = self.handle(json: json, code: normalized)
            } else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                result = .network("授权服务器响应异常（HTTP \(status)）")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func handle(json: [String: Any], code: String) -> ActivationResult {
        let ok = json["ok"] as? Bool ?? false
        guard ok else { return .rejected(json["msg"] as? String ?? "授权码无效") }
        guard let payload = json["payload"] as? String, let sig = json["sig"] as? String,
              let exp = Self.verify(payload: payload, sig: sig, code: code, machine: machineID) else {
            return .network("授权凭证校验失败")
        }
        queue.sync {
            license = StoredLicense(code: code, payload: payload, sig: sig)
            expiresAt = exp
            persistLicense()
        }
        return .success
    }

    /// 清除本地授权（服务端明确拒绝续期时）。
    func clearLicense() {
        queue.sync {
            license = nil
            expiresAt = 0
            try? FileManager.default.removeItem(at: licenseFile)
        }
    }

    // MARK: - 验签

    /// 验证签名并校验授权码/机器 ID，返回到期时间戳（0 = 永久）。
    private static func verify(payload: String, sig: String, code: String, machine: String) -> TimeInterval? {
        guard let keyData = Data(base64Encoded: LicenseConfig.publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sigData = Data(base64Encoded: sig),
              key.isValidSignature(sigData, for: Data(payload.utf8)) else { return nil }
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "v2", parts[1] == LicenseConfig.product,
              parts[2] == code, parts[3] == machine,
              let exp = TimeInterval(parts[4]) else { return nil }
        return exp
    }

    // MARK: - 持久化

    private func load() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: licenseFile),
           let stored = try? JSONDecoder().decode(StoredLicense.self, from: data),
           let exp = Self.verify(payload: stored.payload, sig: stored.sig, code: stored.code, machine: machineID) {
            license = stored
            expiresAt = exp
        }

        // 试用起点/最晚时间双份存储（文件 + UserDefaults），取更早的起点、更晚的时间。
        var states: [LocalState] = []
        if let data = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(LocalState.self, from: data) {
            states.append(s)
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let s = try? JSONDecoder().decode(LocalState.self, from: data) {
            states.append(s)
        }
        state.trialStart = states.compactMap { $0.trialStart }.min()
        state.lastSeen = states.map { $0.lastSeen }.max() ?? 0
        persistState()
    }

    private func persistLicense() {
        if let license, let data = try? JSONEncoder().encode(license) {
            try? data.write(to: licenseFile, options: .atomic)
        }
    }

    private func persistState() {
        lastPersisted = state.lastSeen
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFile, options: .atomic)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
