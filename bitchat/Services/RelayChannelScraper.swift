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

enum RelayScrapedGeohashSource: String, Hashable {
    case relay
    case explorer

    var displayName: String {
        switch self {
        case .relay:
            return "relay"
        case .explorer:
            return "explorer"
        }
    }
}

struct GlobalGeohashFeedItem: Identifiable, Equatable {
    let geohash: String
    let level: GeohashChannelLevel
    var eventCount: Int
    var lastSeen: Date
    var sources: Set<RelayScrapedGeohashSource>

    var id: String { geohash }

    var sourceLabel: String {
        [RelayScrapedGeohashSource.relay, RelayScrapedGeohashSource.explorer]
            .filter { sources.contains($0) }
            .map(\.displayName)
            .joined(separator: " + ")
    }
}

private struct ExplorerGeohashActivity: Decodable {
    let geohash: String
    let activeUsers: Int
    let lastActivity: Date
    let messageCount1h: Int
}

@MainActor
final class RelayChannelScraper: ObservableObject {
    static let shared = RelayChannelScraper()

    @Published private(set) var channels: [RelayScrapedChannel] = []
    @Published private(set) var geohashes: [RelayScrapedGeohash] = []
    @Published private(set) var explorerGeohashes: [RelayScrapedGeohash] = []
    @Published private(set) var globalGeohashes: [GlobalGeohashFeedItem] = []

    private struct ChannelStats {
        var channel: GeohashChannel
        var eventCount: Int
        var lastSeen: Date
    }

    private var channelStats: [String: ChannelStats] = [:]
    private var explorerStats: [String: RelayScrapedGeohash] = [:]
    private var seenEventIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false
    private let subscriptionID = "relay-channel-scrape"
    private let explorerFeedURL = URL(string: "https://bitchatexplorer.com/api/geohash-activities/recent")!
    private var explorerRefreshTimer: Timer?

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
        refreshExplorerGeohashes()
        explorerRefreshTimer?.invalidate()
        explorerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshExplorerGeohashes()
        }
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

    func refreshExplorerGeohashes() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: self.explorerFeedURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let activities = try decoder.decode([ExplorerGeohashActivity].self, from: data)
                await MainActor.run {
                    self.ingestExplorerActivities(activities)
                }
            } catch {
                SecureLogger.log("RelayChannelScraper: explorer feed refresh failed: \(error)",
                                 category: SecureLogger.session, level: .warning)
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
        publishGlobalGeohashes()
    }

    private func ingestExplorerActivities(_ activities: [ExplorerGeohashActivity]) {
        for activity in activities {
            let level = Self.level(forGeohashLength: activity.geohash.count)
            explorerStats[activity.geohash] = RelayScrapedGeohash(
                geohash: activity.geohash,
                eventCount: max(activity.activeUsers, activity.messageCount1h),
                lastSeen: activity.lastActivity,
                level: level
            )
        }
        explorerGeohashes = explorerStats.values.sorted {
            if $0.lastSeen == $1.lastSeen {
                if $0.eventCount == $1.eventCount {
                    return $0.geohash < $1.geohash
                }
                return $0.eventCount > $1.eventCount
            }
            return $0.lastSeen > $1.lastSeen
        }
        publishGlobalGeohashes()
    }

    private func publishGlobalGeohashes() {
        var combined: [String: GlobalGeohashFeedItem] = [:]

        func merge(geohash: String, eventCount: Int, lastSeen: Date, level: GeohashChannelLevel, source: RelayScrapedGeohashSource) {
            if var existing = combined[geohash] {
                existing.eventCount = max(existing.eventCount, eventCount)
                existing.lastSeen = max(existing.lastSeen, lastSeen)
                existing.sources.insert(source)
                combined[geohash] = existing
            } else {
                combined[geohash] = GlobalGeohashFeedItem(
                    geohash: geohash,
                    level: level,
                    eventCount: eventCount,
                    lastSeen: lastSeen,
                    sources: [source]
                )
            }
        }

        for stats in channelStats.values {
            merge(
                geohash: stats.channel.geohash,
                eventCount: stats.eventCount,
                lastSeen: stats.lastSeen,
                level: stats.channel.level,
                source: .relay
            )
        }

        for stats in explorerStats.values {
            merge(
                geohash: stats.geohash,
                eventCount: stats.eventCount,
                lastSeen: stats.lastSeen,
                level: stats.level,
                source: .explorer
            )
        }

        globalGeohashes = combined.values.sorted {
            if $0.lastSeen == $1.lastSeen {
                if $0.eventCount == $1.eventCount {
                    return $0.geohash < $1.geohash
                }
                return $0.eventCount > $1.eventCount
            }
            return $0.lastSeen > $1.lastSeen
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
