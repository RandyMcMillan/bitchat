import Foundation

final class PersistentEventStore {
    private let fileURL: URL
    private var eventsByID: [String: RelayEvent] = [:]
    private var orderedIDs: [String] = []

    init(directoryURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.fileURL = directoryURL.appendingPathComponent("events.jsonl")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        try loadFromDisk()
    }

    var count: Int { orderedIDs.count }

    func appendIfNew(_ event: RelayEvent) throws -> Bool {
        guard eventsByID[event.id] == nil else { return false }
        eventsByID[event.id] = event
        orderedIDs.append(event.id)
        try appendToDisk(event)
        return true
    }

    func allEvents() -> [RelayEvent] {
        orderedIDs.compactMap { eventsByID[$0] }
    }

    func matchingEvents(for filters: [RelayFilter]) -> [RelayEvent] {
        guard !filters.isEmpty else { return [] }

        let sorted = allEvents().sorted {
            if $0.created_at == $1.created_at { return $0.id < $1.id }
            return $0.created_at > $1.created_at
        }

        var seen: Set<String> = []
        var results: [RelayEvent] = []
        for filter in filters {
            let matches = sorted.filter { filter.matches($0) }
            let limited = filter.limit.map { Array(matches.prefix($0)) } ?? matches
            for event in limited where seen.insert(event.id).inserted {
                results.append(event)
            }
        }
        return results
    }

    private func loadFromDisk() throws {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let event = try? JSONDecoder().decode(RelayEvent.self, from: lineData) {
                eventsByID[event.id] = event
                orderedIDs.append(event.id)
            }
        }
    }

    private func appendToDisk(_ event: RelayEvent) throws {
        let data = try JSONEncoder().encode(event)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0a]))
    }
}
