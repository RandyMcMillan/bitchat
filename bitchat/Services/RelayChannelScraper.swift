import Foundation
import Combine

struct RelayScrapedChannel: Identifiable, Equatable {
    let channel: GeohashChannel
    let eventCount: Int
    let lastSeen: Date

    var id: String { channel.id }
}

struct RelayScrapedGeohash: Identifiable, Equatable {
    let geohash: String
    let eventCount: Int
    let lastSeen: Date
    let level: GeohashChannelLevel

    var id: String { geohash }
}

@MainActor
final class RelayChannelScraper: ObservableObject {
    static let shared = RelayChannelScraper()

    @Published private(set) var channels: [RelayScrapedChannel] = []
    @Published private(set) var geohashes: [RelayScrapedGeohash] = []

    private struct ChannelStats {
        var channel: GeohashChannel
        var eventCount: Int
        var lastSeen: Date
    }

    private var channelStats: [String: ChannelStats] = [:]
    private var seenEventIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false
    private let subscriptionID = "relay-channel-scrape"

    func start() {
        guard !didStart else { return }
        didStart = true

        NostrRelayManager.shared.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self, connected else { return }
                self.refresh()
            }
            .store(in: &cancellables)

        refresh()
    }

    func refresh() {
        var filter = NostrFilter()
        filter.kinds = [NostrProtocol.EventKind.ephemeralEvent.rawValue]
        filter.since = Int(Date().addingTimeInterval(-TransportConfig.nostrRelayChannelScrapeLookbackSeconds).timeIntervalSince1970)
        filter.limit = TransportConfig.nostrRelayChannelScrapeLimit

        NostrRelayManager.shared.subscribe(filter: filter, id: subscriptionID) { [weak self] event in
            Task { @MainActor in
                self?.ingest(event)
            }
        }
    }

    private func ingest(_ event: NostrEvent) {
        guard seenEventIDs.insert(event.id).inserted else { return }
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
        guard let geohash = event.tags.first(where: { $0.first == "g" })?.dropFirst().first,
              !geohash.isEmpty else { return }

        let level = Self.level(forGeohashLength: geohash.count)
        let channel = GeohashChannel(level: level, geohash: geohash)
        let now = Date()

        if var stats = channelStats[geohash] {
            stats.channel = channel
            stats.eventCount += 1
            stats.lastSeen = now
            channelStats[geohash] = stats
        } else {
            channelStats[geohash] = ChannelStats(channel: channel, eventCount: 1, lastSeen: now)
        }

        publishChannels()
    }

    private func publishChannels() {
        let sorted = channelStats.values
            .sorted {
                if $0.lastSeen == $1.lastSeen {
                    if $0.eventCount == $1.eventCount {
                        return $0.channel.geohash < $1.channel.geohash
                    }
                    return $0.eventCount > $1.eventCount
                }
                return $0.lastSeen > $1.lastSeen
            }

        channels = sorted.map { RelayScrapedChannel(channel: $0.channel, eventCount: $0.eventCount, lastSeen: $0.lastSeen) }
        geohashes = sorted.map {
            RelayScrapedGeohash(
                geohash: $0.channel.geohash,
                eventCount: $0.eventCount,
                lastSeen: $0.lastSeen,
                level: $0.channel.level
            )
        }
    }

    private static func level(forGeohashLength length: Int) -> GeohashChannelLevel {
        switch length {
        case 0...2: return .region
        case 3...4: return .province
        case 5: return .city
        case 6: return .neighborhood
        default: return .block
        }
    }
}
