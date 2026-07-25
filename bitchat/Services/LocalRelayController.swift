import Foundation

@MainActor
final class LocalRelayController {
    static let shared = LocalRelayController()

    private var server: RelayServer?
    private var didAttemptStart = false

    func startIfNeeded() {
        guard !didAttemptStart else { return }
        didAttemptStart = true

        do {
            let server = try RelayServer(port: LocalRelayConfig.port, dataDirectory: LocalRelayConfig.dataDirectory)
            try server.start()
            self.server = server
            SecureLogger.log("Local relay started on \(LocalRelayConfig.urlString)",
                            category: SecureLogger.session, level: .info)
        } catch {
            SecureLogger.log("Local relay unavailable: \(error)",
                            category: SecureLogger.session, level: .warning)
        }
    }
}
