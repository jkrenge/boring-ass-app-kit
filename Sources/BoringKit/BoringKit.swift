@_exported import Aptabase
import DeviceCheck
import Foundation
import KSCrashMonitors
import KSCrashRecording

/// Crash reporting (KSCrash + MetricKit), analytics and handled errors (Aptabase) and feedback,
/// all sent to the boring-api Worker.
///
/// ```swift
/// BoringKit.start(api: URL(string: "https://boring-api.<you>.workers.dev")!)
/// Aptabase.shared.trackEvent("export_tapped", with: ["format": "pdf"])
/// Aptabase.shared.trackError(error)
/// .sheet(isPresented: $showFeedback) { FeedbackView() }
/// ContentView().updatePrompt()
/// ```
@MainActor
public enum BoringKit {
    private static var api: URL?
    private static var token: String?

    /// Call once, as early as possible in app launch.
    public static func start(api: URL) {
        self.api = api
        installCrashReporter()
        let saved = Keychain.read()
        token = saved
        // start analytics synchronously so events tracked right after start() aren't dropped
        if let saved { startAnalytics(api, token: saved) }
        // Aptabase drops 401s silently, so check the token ourselves; a 401 clears it and we register again.
        // The same ping says whether a newer version is out. No ping on first launch: a fresh install is current.
        let check = Task<AppUpdate?, Never> {
            guard let saved else { return nil }
            return await ping(saved)
        }
        updateCheck = check
        Task {
            _ = await check.value
            // shortcut: on first launch, events tracked before registration finishes are dropped
            guard let current = await deviceToken() else { return }
            if current != saved { startAnalytics(api, token: current) }
            await uploadCrashReports(current)
        }
    }

    private static func startAnalytics(_ api: URL, token: String) {
        var host = api.absoluteString
        if host.hasSuffix("/") { host.removeLast() }
        Aptabase.shared.initialize(appKey: "A-SH-\(token)", with: InitOptions(host: host))
    }

    /// The newer version the Worker offers (its `apps` table), or nil. Waits for the launch ping.
    /// `.updatePrompt()` uses this; call it directly for your own UI.
    public static func availableUpdate() async -> AppUpdate? { await updateCheck?.value }

    private static var updateCheck: Task<AppUpdate?, Never>?

    private static func ping(_ token: String) async -> AppUpdate? {
        struct Pong: Decodable { let update: AppUpdate? }
        guard let api,
              let (data, status) = await send(api.appending(path: "v1/ping"), body: json(["version": shortVersion]), token: token),
              status == 200
        else { return nil }
        let update = (try? JSONDecoder().decode(Pong.self, from: data))?.update
        // only ever send people to the App Store, whatever the Worker says
        return update?.url.scheme == "https" && update?.url.host() == "apps.apple.com" ? update : nil
    }

    /// Sends feedback right away. `FeedbackView` uses this; call it directly for your own UI.
    public static func sendFeedback(_ message: String, email: String? = nil) async -> Bool {
        guard let token = await deviceToken() else { return false }
        var body: [String: Any] = [
            "message": message,
            "appVersion": appVersion,
            "osVersion": osVersion,
            "deviceModel": deviceModel,
            "isDebug": isDebug,
        ]
        if let email, !email.isEmpty { body["email"] = email }
        guard let status = await post("v1/feedback", json: body, token: token) else { return false }
        return (200..<300).contains(status)
    }

    // MARK: - Device registration

    private static func deviceToken() async -> String? {
        if let token = token ?? Keychain.read() {
            self.token = token
            return token
        }
        // share one in-flight registration, e.g. feedback sent while start() is still registering
        let task = registration ?? Task { await register() }
        registration = task
        let token = await task.value
        registration = nil
        return token
    }

    private static var registration: Task<String?, Never>?

    private static func register() async -> String? {
        var body: [String: Any] = [
            "bundleId": Bundle.main.bundleIdentifier ?? "", "platform": platform, "development": isDebug,
        ]
        // DeviceCheck is unsupported on the Simulator; the Worker only accepts that with ALLOW_UNATTESTED
        if DCDevice.current.isSupported, let dcToken = try? await DCDevice.current.generateToken() {
            body["deviceCheckToken"] = dcToken.base64EncodedString()
        }
        guard let api,
              let (data, status) = await send(api.appending(path: "v1/register"), body: json(body)),
              status == 200,
              let token = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String
        else { return nil }  // offline or rejected: try again on next launch
        Keychain.save(token)
        self.token = token
        return token
    }

    // MARK: - Crashes

    private static func installCrashReporter() {
        let config = KSCrashConfiguration()
        config.plugins = [Monitors.metricKit]
        do {
            try KSCrash.shared.install(with: config)
        } catch {
            print("BoringKit: crash reporter not installed: \(error)")
        }
    }

    // shortcut: runs once per launch, so MetricKit diagnostics delivered during this launch upload on the next one
    private static func uploadCrashReports(_ token: String) async {
        guard let store = KSCrash.shared.reportStore, let api else { return }
        for id in store.reportIDs.map(\.int64Value) {
            guard let report = store.reportData(for: id)?.value else { continue }
            guard let (_, status) = await send(api.appending(path: "v1/crashes"), body: report, token: token) else {
                break  // offline: keep reports on disk for next launch
            }
            // 400/413 will never succeed, so drop them too
            if (200..<300).contains(status) || status == 400 || status == 413 { store.deleteReport(with: id) }
            if status == 401 || status == 429 { break }
        }
        // KSCrash's own sendAllReports deletes leftover per-launch folders; uploading by hand skips that
        Task.detached(priority: .background) { KSCrash.shared.reportStore?.cleanupOrphanedRunSidecars() }
    }

    // MARK: - HTTP

    private static func post(_ path: String, json body: [String: Any], token: String) async -> Int? {
        guard let api else { return nil }
        return await send(api.appending(path: path), body: json(body), token: token)?.1
    }

    private static func send(_ url: URL, body: Data, token: String? = nil) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // revoked or unknown: forget it so we register again. Only if it's still current: a late 401
        // for an old token must not wipe one we registered since.
        if status == 401, let token, token == self.token {
            Keychain.save(nil)
            self.token = nil
        }
        return (data, status)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: - Device info

    private static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    private static var appVersion: String {
        "\(shortVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
    }

    // a Mac app can share its iPhone app's bundle ID, so the Worker keeps devices and versions per platform
    private static var platform: String {
        #if os(macOS)
            "macOS"
        #else
            "iOS"
        #endif
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    private static var deviceModel: String {
        #if os(macOS)
            // uname says only "arm64" on a Mac; hw.model is the model, such as Mac14,2
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [UInt8](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
        #else
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }

    private static var isDebug: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}

/// A newer version of this app on the App Store.
public struct AppUpdate: Decodable, Sendable {
    public let version: String
    public let url: URL
}

private enum Keychain {
    private static var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "BoringKit",
            kSecAttrAccount as String: "device-token",
        ]
        #if os(macOS)
            // the iOS-style keychain, which never asks the user for access
            query[kSecUseDataProtectionKeychain as String] = true
            // It needs an app-identifier entitlement, which a build signed without a provisioning profile (many
            // Debug builds, ad-hoc) lacks. Those would register as a new device on every launch, so they use the
            // login keychain instead. Every app shares that one, hence the bundle ID in the name.
            if let task = SecTaskCreateFromSelf(nil),
               SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) == nil {
                query[kSecUseDataProtectionKeychain as String] = nil
                query[kSecAttrService as String] = "BoringKit \(Bundle.main.bundleIdentifier ?? "")"
            }
        #endif
        return query
    }

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var query = query
        query[kSecValueData as String] = Data(token.utf8)
        // ThisDeviceOnly: don't carry the token to a new phone via backups, which would merge two devices
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}
