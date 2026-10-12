import Foundation

struct AppVersion {
    static var current: AppVersion { AppVersion(info: Bundle.main.infoDictionary ?? [:]) }
    let version: String?
    let build: String?
    init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }
    var sidebar: String {
        version.map { "Version \($0)" } ?? "Development build · version unavailable"
    }
    var details: String {
        "\(sidebar) · \(build.map { "Build \($0)" } ?? "build number unavailable")"
    }
}
