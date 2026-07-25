import Foundation
import Bitchat

struct RelayCLIConfiguration {
    var port: UInt16 = LocalRelayConfig.port
    var dataDirectory: URL = LocalRelayConfig.dataDirectory
}

func parseConfiguration() -> RelayCLIConfiguration {
    var config = RelayCLIConfiguration()
    var args = Array(CommandLine.arguments.dropFirst())

    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: BitchatRelay [--port <port>] [--data-dir <path>]

            Options:
              --port <port>       TCP port to listen on (default: \(LocalRelayConfig.port))
              --data-dir <path>   Directory used for persistent relay storage
              --help, -h          Show this help text
            """)
            exit(0)
        case "--port":
            guard let value = args.first, let parsed = UInt16(value) else {
                fputs("error: --port expects a numeric value\n", stderr)
                exit(1)
            }
            config.port = parsed
            args.removeFirst()
        case "--data-dir":
            guard let value = args.first else {
                fputs("error: --data-dir expects a path value\n", stderr)
                exit(1)
            }
            config.dataDirectory = URL(fileURLWithPath: value, isDirectory: true)
            args.removeFirst()
        default:
            fputs("error: unknown argument \(arg)\n", stderr)
            exit(1)
        }
    }

    return config
}

do {
    let config = parseConfiguration()
    let server = try RelayServer(port: config.port, dataDirectory: config.dataDirectory)
    print("[relay] starting on port \(config.port)")
    print("[relay] persistence: \(config.dataDirectory.path)")
    try server.start()
    dispatchMain()
} catch {
    fputs("relay failed: \(error)\n", stderr)
    exit(1)
}
