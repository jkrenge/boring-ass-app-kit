@_exported import Aptabase
import DeviceCheck
import Foundation
import KSCrashMonitors
import KSCrashRecording
import UIKit

/// Crash reporting (KSCrash + MetricKit), analytics and handled errors (Aptabase) and feedback,
/// all sent to the boring-api Worker.
///
/// ```swift
/// BoringKit.start(api: URL(string: "https://boring-api.<you>.workers.dev")!)
/// Aptabase.shared.trackEvent("export_tapped", with: ["format": "pdf"])
/// Aptabase.shared.trackError(error)
/// .sheet(isPresented: $showFeedback) { FeedbackView() }
/// ```
@MainActor
public enum BoringKit {
    private static var api: URL?
    private static var token: String?

    /// Call once, as early as possible in app launch.
    public static func start(api: URL) {
        self.api = api
        installCrashReporter()
        Task {
            // shortcut: on first launch, events tracked before registration finishes are dropped
            guard let token = await deviceToken() else { return }
            var host = api.absoluteString
            if host.hasSuffix("/") { host.removeLast() }
            Aptabase.shared.initialize(appKey: "A-SH-\(token)", with: InitOptions(host: host))
            await uploadCrashReports(token)
        }
    }

    /// Sends feedback right away. `FeedbackView` uses this; call it directly for your own UI.
    public static func sendFeedback(_ message: String, email: String? = nil) async -> Bool {
        guard let token = await deviceToken() else { return false }
        var body: [String: Any] = [
            "message": message,
            "appVersion": appVersion,
            "osVersion": UIDevice.current.systemVersion,
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
        var body: [String: Any] = ["bundleId": Bundle.main.bundleIdentifier ?? "", "development": isDebug]
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
                return  // offline: keep reports on disk for next launch
            }
            // 400/413 will never succeed, so drop them too
            if (200..<300).contains(status) || status == 400 || status == 413 { store.deleteReport(with: id) }
            if status == 401 { return }
        }
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
        if status == 401 {
            // revoked or unknown: forget it so the next launch registers again
            Keychain.save(nil)
            self.token = nil
        }
        return (data, status)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: - Device info

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static var isDebug: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}

private enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "BoringKit",
         kSecAttrAccount as String: "device-token"]
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
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}
