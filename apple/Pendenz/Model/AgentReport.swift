import Foundation

// The agents of the server and the latest status report of each, as `GET /api/agents` sends
// them. A report is what the agent's own machine says about itself: the agent software, what it
// spends, its scheduled jobs and the machine's load. Every part of a report may be missing.
nonisolated struct AgentList: Decodable, Sendable {
    var agents: [AgentEntry]
    // The server's clock when it answered, so an age is measured against the server's time.
    var now: Date
}

nonisolated struct AgentEntry: Decodable, Sendable, Identifiable {
    var id: String
    var name: String
    var scopes: [String]
    var lastUsedAt: Date?
    var receivedAt: Date?
    var today: AgentToday
    var report: AgentReport?
    // The lines the owner wrote about the agent's jobs. Missing from a server older than them,
    // which is how the app knows not to offer writing one.
    var jobDescriptions: [AgentJobDescription]?
    // True when the agent sent a report this app cannot read, such as one from a newer agent.
    // The other agents still show.
    var isReportUnreadable = false

    private enum CodingKeys: String, CodingKey {
        case id, name, scopes, lastUsedAt, receivedAt, today, report, jobDescriptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scopes = try container.decode([String].self, forKey: .scopes)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt)
        today = (try? container.decode(AgentToday.self, forKey: .today))
            ?? AgentToday(created: 0, updated: 0, completed: 0, commented: 0)
        jobDescriptions = try? container.decodeIfPresent([AgentJobDescription].self, forKey: .jobDescriptions)
        do {
            report = try container.decodeIfPresent(AgentReport.self, forKey: .report)
        } catch {
            report = nil
            isReportUnreadable = true
        }
    }
}

nonisolated extension AgentEntry {
    // The owner's line about a job, by the job's name as the report gives it.
    func description(ofJob name: String) -> String? {
        jobDescriptions?.first { $0.job == name }?.text
    }
}

nonisolated struct AgentJobDescription: Decodable, Sendable, Hashable {
    var job: String
    var text: String
}

// What an agent did today in the server's time zone, from the activity log.
nonisolated struct AgentToday: Decodable, Sendable {
    var created: Int
    var updated: Int
    var completed: Int
    var commented: Int
}

nonisolated struct AgentReport: Decodable, Sendable {
    var schema: Int
    var sentAt: Date
    var agent: AgentInfo?
    var accounts: [AgentAccount]?
    var jobs: [AgentJob]?
    var runs: [AgentRun]?
    var host: AgentHost?
}

nonisolated struct AgentInfo: Decodable, Sendable {
    enum Health: String, Decodable, Sendable {
        case online, degraded, offline
    }

    var software: String
    var version: String?
    var model: String?
    var fallbacks: [String]?
    var health: Health
    var healthDetail: String?
    var since: Date?
    var channels: [AgentChannel]?
}

nonisolated struct AgentChannel: Decodable, Sendable, Hashable {
    var name: String
    var connected: Bool
}

nonisolated struct AgentAccount: Decodable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable {
        // Paid per token: shown in money.
        case api
        // A plan with limits: shown as windows and tokens, never as money.
        case subscription
    }

    var id: String
    var name: String
    var kind: Kind
    var plan: String?
    var usedBy: [String]?
    var windows: [AgentWindow]?
    var spend: AgentSpend?
    var daily: [AgentDay]?
    var models: [AgentModelUse]?
}

nonisolated struct AgentWindow: Decodable, Sendable, Hashable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
}

nonisolated struct AgentSpend: Decodable, Sendable {
    var estimated: Bool
    var today: Double
    var week: Double
    var month: Double
}

nonisolated struct AgentDay: Decodable, Sendable, Identifiable {
    // "2026-11-18", on the agent machine's calendar.
    var date: String
    var cost: Double?
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    var id: String { date }
    var tokens: Int { input + output + cacheRead + cacheWrite }

    // Midnight of that day on this device's calendar, which is how the charts group days.
    var day: Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

nonisolated struct AgentModelUse: Decodable, Sendable, Identifiable {
    var model: String
    var cost: Double?
    var sessions: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    var id: String { model }
    var tokens: Int { input + output + cacheRead + cacheWrite }
}

nonisolated struct AgentJob: Decodable, Sendable, Identifiable {
    var name: String
    var schedule: String
    var enabled: Bool
    var lastRunAt: Date?
    // "ok" or "error"; missing before the first run.
    var lastStatus: String?
    var nextRunAt: Date?
    var failureStreak: Int
    var lastError: String?
    // How often the job woke a model in the last seven days, and the tokens that took.
    var runsWeek: Int
    var tokensWeek: Int
    var lastDurationS: Double?
    // The first sentence of the description of the skill the job runs, from the agent's machine.
    var skillSummary: String?

    var id: String { name }
    var isFailing: Bool { lastStatus == "error" || failureStreak > 0 }
}

nonisolated struct AgentRun: Decodable, Sendable, Identifiable, Hashable {
    var title: String
    var kind: String
    var state: String
    var startedAt: Date?

    var id: String { "\(kind) \(title) \(startedAt?.timeIntervalSince1970 ?? 0)" }
    var isBusy: Bool { state == "busy" }
}

nonisolated struct AgentHost: Decodable, Sendable {
    var name: String
    var os: String?
    var chip: String?
    var cores: Int
    var uptimeS: Int
    var cpuPercent: Double
    var load: [Double]
    var memoryUsed: Int64
    var memoryTotal: Int64
    var swapUsed: Int64
    var memoryFreePercent: Double?
    var diskUsed: Int64
    var diskTotal: Int64
    var top: [AgentProcess]
    var series: [AgentSample]
    // Missing from a machine without an energy sampler and from older collectors.
    var energy: AgentEnergy?
}

nonisolated struct AgentEnergy: Decodable, Sendable {
    // The last minute's average power and the last CPU temperature, each with its time.
    var powerAt: Date?
    var watts: Double?
    var tempAt: Date?
    var tempC: Double?
    // The machine's current month, such as "2026-11". Missing from collectors before it.
    var thisMonth: String?
    // This month, then the last. A month without readings is missing.
    var months: [AgentEnergyMonth]
}

nonisolated struct AgentEnergyMonth: Decodable, Sendable, Identifiable {
    // "2026-11".
    var month: String
    // Missing when the month has temperatures but no power readings.
    var kwh: Double?
    // The hours that were measured.
    var hours: Double
    var tempMax: Double?
    var tempMedian: Double?

    var id: String { month }
}

nonisolated struct AgentProcess: Decodable, Sendable, Identifiable {
    var name: String
    var count: Int
    var cpuPercent: Double
    var memory: Int64

    var id: String { name }
}

nonisolated struct AgentSample: Decodable, Sendable, Identifiable {
    var at: Date
    var cpuPercent: Double
    var memoryUsed: Int64

    var id: Date { at }
}

nonisolated extension AgentList {
    // The server writes times with fractions of a second, which `.iso8601` does not take.
    static func decode(_ data: Data) throws -> AgentList {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a time: \(text)"),
            )
        }
        return try decoder.decode(AgentList.self, from: data)
    }

    // The agents that sent a report, newest first: the server sorts them so.
    var reporting: [AgentEntry] {
        agents.filter { $0.report != nil || $0.isReportUnreadable }
    }
}
