import Foundation
import Combine

enum TokenUsageAggregator {
    static func report(events: [TokenUsageEvent], catalog: TokenPriceCatalog,
                       calendar: Calendar = .current) -> TokenUsageReport {
        var formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        struct Bucket {
            var counts = TokenCounts()
            var cost = 0.0
            var priced = 0
            var unpriced = 0
        }
        var buckets: [String: Bucket] = [:]
        var dimensions: [String: (String, TokenAgent, String)] = [:]
        for event in events {
            let day = formatter.string(from: event.timestamp)
            let key = "\(day)\u{1f}\(event.agent.rawValue)\u{1f}\(event.model)"
            var bucket = buckets[key] ?? Bucket()
            bucket.counts = bucket.counts + event.counts
            if let price = catalog.rate(agent: event.agent, model: event.model) {
                bucket.cost += price.estimate(event.counts, agent: event.agent)
                bucket.priced += 1
            } else {
                bucket.unpriced += 1
            }
            buckets[key] = bucket
            dimensions[key] = (day, event.agent, event.model)
        }
        var report = TokenUsageReport()
        var daily: [String: Bucket] = [:]
        for (key, bucket) in buckets {
            guard let (day, agent, model) = dimensions[key] else { continue }
            report.lines.append(TokenUsageLine(id: key, day: day, agent: agent, model: model,
                                               counts: bucket.counts,
                                               estimatedUSD: bucket.priced > 0 ? bucket.cost : nil,
                                               unpricedEvents: bucket.unpriced))
            var dayBucket = daily[day] ?? Bucket()
            dayBucket.counts = dayBucket.counts + bucket.counts
            dayBucket.cost += bucket.cost
            dayBucket.unpriced += bucket.unpriced
            daily[day] = dayBucket
            report.counts = report.counts + bucket.counts
            report.estimatedUSD += bucket.cost
            report.unpricedEvents += bucket.unpriced
        }
        report.lines.sort { $0.day == $1.day ? ($0.agent.rawValue, $0.model) < ($1.agent.rawValue, $1.model) : $0.day > $1.day }
        report.days = daily.map { TokenUsageDay(day: $0.key, counts: $0.value.counts,
                                                estimatedUSD: $0.value.cost, unpricedEvents: $0.value.unpriced) }
            .sorted { $0.day > $1.day }
        return report
    }
}

final class TokenUsageManager: ObservableObject {
    static let shared = TokenUsageManager()

    @Published private(set) var report = TokenUsageReport()
    @Published private(set) var statuses: [TokenAgent: TokenSourceStatus] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var isUpdatingPrices = false
    @Published private(set) var priceSource = "Bundled"
    @Published private(set) var priceUpdatedAt: Date?
    @Published private(set) var errorMessage: String?

    private let worker = DispatchQueue(label: "clipy.token-usage", qos: .utility)
    private let databaseURL: URL
    private let catalog: TokenPriceCatalog
    private var store: TokenUsageStore?
    private let paths: TokenUsagePaths
    private var lastScan: Date?

    init(paths: TokenUsagePaths = .standard, directory: URL? = nil,
         seedURL: URL? = Bundle.main.url(forResource: "token-prices-seed", withExtension: "json"),
         overridesURL: URL? = Bundle.main.url(forResource: "token-prices-overrides", withExtension: "json")) {
        self.paths = paths
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        databaseURL = support.appendingPathComponent("token-usage.db")
        catalog = TokenPriceCatalog(seedURL: seedURL, overridesURL: overridesURL,
                                    cacheURL: support.appendingPathComponent("token-prices.json"))
        priceSource = catalog.source
        priceUpdatedAt = catalog.updatedAt
    }

    func refreshIfStale() {
        if let lastScan, Date().timeIntervalSince(lastScan) < 60 { return }
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        worker.async { [self] in
            do {
                let store = try self.ensureStore()
                let sources: [any TokenUsageSource] = [
                    JSONLTokenSource(agent: .codex, root: paths.codex),
                    JSONLTokenSource(agent: .claude, root: paths.claude),
                    GeminiTokenSource(root: paths.gemini),
                    ZCodeTokenSource(database: paths.zcode),
                ]
                var statuses: [TokenAgent: TokenSourceStatus] = [:]
                for source in sources {
                    do { statuses[source.agent] = try source.scan(into: store) }
                    catch { statuses[source.agent] = TokenSourceStatus(state: .failed, detail: error.localizedDescription) }
                }
                let report = try self.currentReport(store: store)
                DispatchQueue.main.async {
                    self.statuses = statuses
                    self.report = report
                    self.lastScan = Date()
                    self.isScanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                }
            }
        }
    }

    func updatePrices() {
        guard !isUpdatingPrices else { return }
        isUpdatingPrices = true
        errorMessage = nil
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: Self.priceRequest()) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            self.worker.async {
                do {
                    if let error { throw error }
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          let data else { throw NSError(domain: "ClipyTokenPrice", code: 2,
                                                         userInfo: [NSLocalizedDescriptionKey: "Price download failed"]) }
                    try self.catalog.installDownloadedPrices(data)
                    let report = try self.currentReport(store: self.ensureStore())
                    DispatchQueue.main.async {
                        self.report = report
                        self.priceSource = self.catalog.source
                        self.priceUpdatedAt = self.catalog.updatedAt
                        self.isUpdatingPrices = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                        self.isUpdatingPrices = false
                    }
                }
            }
        }
        task.resume()
    }

    private static func priceRequest() -> URLRequest {
        var request = URLRequest(url: TokenPriceCatalog.upstream)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func ensureStore() throws -> TokenUsageStore {
        if let store { return store }
        let opened = try TokenUsageStore(databaseURL: databaseURL)
        store = opened
        return opened
    }

    private func currentReport(store: TokenUsageStore) throws -> TokenUsageReport {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
        return TokenUsageAggregator.report(events: try store.events(from: start, through: end),
                                           catalog: catalog, calendar: calendar)
    }

    #if CLIPY_CORE_TESTS
    func setPreview(report: TokenUsageReport, statuses: [TokenAgent: TokenSourceStatus]) {
        self.report = report
        self.statuses = statuses
    }
    #endif
}
