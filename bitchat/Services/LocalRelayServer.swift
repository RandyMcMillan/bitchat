import Foundation
import Network

public final class RelayServer {
    private final class ClientSession {
        let connection: NWConnection
        var subscriptions: [String: [RelayFilter]] = [:]

        init(connection: NWConnection) {
            self.connection = connection
        }

        func send(_ text: String) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        func close() {
            connection.cancel()
        }
    }

    private let queue = DispatchQueue(label: "chat.bitchat.relay")
    private let store: PersistentEventStore
    private let port: UInt16
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientSession] = [:]

    public init(port: UInt16, dataDirectory: URL) throws {
        self.port = port
        self.store = try PersistentEventStore(directoryURL: dataDirectory)
    }

    public func start() throws {
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true

        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)

        let endpoint = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: endpoint)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .setup:
                print("[relay] setup")
            case .waiting(let error):
                print("[relay] waiting: \(error)")
            case .ready:
                print("[relay] listening on port \(self.port) with \(self.store.count) stored events")
            case .failed(let error):
                print("[relay] failed: \(error)")
            case .cancelled:
                print("[relay] cancelled")
            @unknown default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let client = ClientSession(connection: connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self = self, let client = client else { return }
            switch state {
            case .ready:
                self.receiveNextMessage(from: client)
            case .failed(let error):
                self.disconnect(client: client, reason: error.localizedDescription)
            case .cancelled:
                self.disconnect(client: client, reason: "cancelled")
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveNextMessage(from client: ClientSession) {
        client.connection.receiveMessage { [weak self, weak client] data, _, _, error in
            guard let self = self, let client = client else { return }

            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                self.handle(text: text, from: client)
            }

            if let error {
                self.disconnect(client: client, reason: error.localizedDescription)
                return
            }

            self.receiveNextMessage(from: client)
        }
    }

    private func handle(text: String, from client: ClientSession) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [Any],
              let command = array.first as? String else {
            client.send(notice("invalid message"))
            return
        }

        switch command {
        case "EVENT":
            handlePublish(array: array, from: client)
        case "REQ":
            handleSubscribe(array: array, from: client)
        case "CLOSE":
            handleClose(array: array, from: client)
        default:
            client.send(notice("unsupported command"))
        }
    }

    private func handlePublish(array: [Any], from client: ClientSession) {
        guard array.count >= 2,
              let eventDict = array[1] as? [String: Any] else {
            client.send(ok(eventID: "", accepted: false, message: "invalid event payload"))
            return
        }

        do {
            let event = try RelayEvent(from: eventDict)
            guard event.isValid() else {
                client.send(ok(eventID: event.id, accepted: false, message: "invalid event id"))
                return
            }

            let inserted = try store.appendIfNew(event)
            if inserted {
                broadcast(event)
            }
            client.send(ok(eventID: event.id, accepted: true, message: inserted ? "stored" : "duplicate"))
        } catch {
            client.send(ok(eventID: eventDict["id"] as? String ?? "", accepted: false, message: error.localizedDescription))
        }
    }

    private func handleSubscribe(array: [Any], from client: ClientSession) {
        guard array.count >= 3,
              let subID = array[1] as? String else {
            client.send(notice("invalid subscription"))
            return
        }

        let filters = array.dropFirst(2).compactMap { item -> RelayFilter? in
            guard let dict = item as? [String: Any] else { return nil }
            return RelayFilter(json: dict)
        }

        guard !filters.isEmpty else {
            client.send(notice("empty subscription filters"))
            return
        }

        client.subscriptions[subID] = filters
        for event in store.matchingEvents(for: filters) {
            client.send(eventResponse(subscriptionID: subID, event: event))
        }
        client.send(eose(subscriptionID: subID))
    }

    private func handleClose(array: [Any], from client: ClientSession) {
        guard array.count >= 2,
              let subID = array[1] as? String else { return }
        client.subscriptions.removeValue(forKey: subID)
    }

    private func broadcast(_ event: RelayEvent) {
        for client in clients.values {
            let matchingSubscriptionIDs = client.subscriptions.compactMap { subID, filters -> String? in
                filters.contains(where: { $0.matches(event) }) ? subID : nil
            }
            for subID in matchingSubscriptionIDs {
                client.send(eventResponse(subscriptionID: subID, event: event))
            }
        }
    }

    private func disconnect(client: ClientSession, reason: String) {
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
        client.close()
        print("[relay] disconnected: \(reason)")
    }

    private func ok(eventID: String, accepted: Bool, message: String) -> String {
        jsonString(["OK", eventID, accepted, message])
    }

    private func eventResponse(subscriptionID: String, event: RelayEvent) -> String {
        guard let data = try? JSONEncoder().encode(event),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return notice("serialization failure")
        }
        return jsonString(["EVENT", subscriptionID, object])
    }

    private func eose(subscriptionID: String) -> String {
        jsonString(["EOSE", subscriptionID])
    }

    private func notice(_ message: String) -> String {
        jsonString(["NOTICE", message])
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return #"["NOTICE","serialization failure"]"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
