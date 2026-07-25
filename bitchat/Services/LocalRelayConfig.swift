import Foundation

public enum LocalRelayConfig {
    public static let port: UInt16 = 7447

    public static var urlString: String {
        "ws://127.0.0.1:\(port)"
    }

    public static var url: URL {
        URL(string: urlString)!
    }

    public static var dataDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        return base.appendingPathComponent("bitchat-relay", isDirectory: true)
    }
}
