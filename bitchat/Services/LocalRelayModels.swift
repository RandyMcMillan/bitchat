import Foundation
import CryptoKit

struct RelayEvent: Codable, Hashable {
    var id: String
    let pubkey: String
    let created_at: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    var sig: String?

    func computedID() throws -> String {
        let serialized: [Any] = [0, pubkey, created_at, kind, tags, content]
        let data = try JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isValid() -> Bool {
        (try? computedID()) == id
    }
}

extension RelayEvent {
    init(from json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        self = try JSONDecoder().decode(RelayEvent.self, from: data)
    }
}

struct RelayFilter {
    let ids: [String]?
    let authors: [String]?
    let kinds: [Int]?
    let since: Int?
    let until: Int?
    let limit: Int?
    let tagFilters: [String: [String]]

    init?(json: [String: Any]) {
        ids = json["ids"] as? [String]
        authors = json["authors"] as? [String]
        kinds = json["kinds"] as? [Int]
        since = json["since"] as? Int
        until = json["until"] as? Int
        limit = json["limit"] as? Int

        var tags: [String: [String]] = [:]
        for (key, value) in json where key.hasPrefix("#") {
            if let values = value as? [String] {
                tags[String(key.dropFirst())] = values
            }
        }
        tagFilters = tags
    }

    func matches(_ event: RelayEvent) -> Bool {
        if let ids, !ids.isEmpty, !ids.contains(where: { event.id.hasPrefix($0) }) { return false }
        if let authors, !authors.isEmpty, !authors.contains(where: { event.pubkey.hasPrefix($0) }) { return false }
        if let kinds, !kinds.isEmpty, !kinds.contains(event.kind) { return false }
        if let since, event.created_at < since { return false }
        if let until, event.created_at > until { return false }

        for (tagName, expectedValues) in tagFilters {
            let hasMatch = event.tags.contains { tag in
                guard tag.first == tagName else { return false }
                return tag.dropFirst().contains { expectedValues.contains($0) }
            }
            if !hasMatch { return false }
        }

        return true
    }
}
