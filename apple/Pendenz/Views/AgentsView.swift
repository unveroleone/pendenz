import Charts
import SwiftUI

// Whether the app offers the Agents screen. Automatic: once an agent has sent a report.
enum AgentsVisibility: String, CaseIterable, Identifiable {
    case automatic, always, never

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .always: "Always"
        case .never: "Never"
        }
    }

    static let key = "agentsShown"

    func isShown(_ board: AgentBoard) -> Bool {
        switch self {
        case .automatic: !board.reporting.isEmpty
        case .always: true
        case .never: false
        }
    }
}

extension Color {
    // The one color of the agents, next to red for what needs attention. The rest of the app is
    // black and white.
    static let agent = Color.teal
}

// What the agents do and cost: their state, what waits for the owner, plan limits, spend, the
// scheduled jobs and the machine they run on. Cards in one column on the iPhone, a grid where
// the window is wide.
struct AgentsView: View {
    @Environment(AgentBoard.self) private var board
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var chosenAgent: String?

    private var entry: AgentEntry? {
        let reporting = board.reporting
        return reporting.first { $0.id == chosenAgent } ?? reporting.first
    }

    var body: some View {
        Group {
            if let entry, entry.isReportUnreadable {
                ContentUnavailableView(
                    "Report Not Readable", systemImage: "exclamationmark.triangle",
                    description: Text("\(entry.name) sent a report this version of the app cannot read. Update the app."),
                )
            } else if let entry, let report = entry.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if board.reporting.count > 1 {
                            Picker("Agent", selection: Binding { entry.id } set: { chosenAgent = $0 }) {
                                ForEach(board.reporting) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.segmented)
                        }
                        problemNote
                        cards(entry, report)
                    }
                    .padding(16)
                }
            } else if board.list == nil, board.problem == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                empty
            }
        }
        .navigationTitle("Agents")
        .refreshable { await board.refresh() }
        .task { await board.watch() }
    }

    @ViewBuilder
    private var problemNote: some View {
        switch board.problem {
        case .outdated:
            Label("The server is older than agent reports. Update it to see your agents.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .unreachable:
            if let fetchedAt = board.fetchedAt {
                Label {
                    Text("Offline. Showing what the server said \(fetchedAt, format: .relative(presentation: .named)).")
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Agent Reports", systemImage: "sparkles")
        } description: {
            if board.problem == .outdated {
                Text("The server is older than agent reports. Update it to see your agents.")
            } else {
                Text(
                    "An agent shows up here once it sends a report. Run `pendenz report` on the agent's machine with a token that has the report scope.",
                )
            }
        }
    }

    // One column where the window is narrow. Where it is wide, two columns that each stack
    // their cards, so a short card leaves no gap under it: the agent and its work on the left,
    // what it uses on the right.
    @ViewBuilder
    private func cards(_ entry: AgentEntry, _ report: AgentReport) -> some View {
        let accounts = report.accounts ?? []
        let plans = accounts.filter { $0.kind == .subscription && !($0.windows ?? []).isEmpty }
        let paid = accounts.filter { $0.kind == .api }
        let planTokens = accounts.filter { $0.kind == .subscription && ($0.daily ?? []).contains { $0.tokens > 0 } }
        let left = Group {
            AgentStatusCard(entry: entry, report: report, age: board.age(of: entry))
            WaitingCard()
            WorkingCard(runs: report.runs ?? [])
            if let jobs = report.jobs, !jobs.isEmpty { JobsCard(jobs: jobs) }
        }
        let right = Group {
            if !plans.isEmpty { PlanLimitsCard(accounts: plans) }
            if !paid.isEmpty { SpendCard(accounts: paid) }
            if !planTokens.isEmpty { PlanTokensCard(accounts: planTokens) }
            if let host = report.host { MachineCard(host: host) }
        }
        if sizeClass == .compact {
            VStack(spacing: 16) {
                left
                right
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) { left }
                VStack(spacing: 16) { right }
            }
        }
    }
}

// MARK: Pieces

private struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .font(.headline)
            .labelStyle(.titleAndIcon)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

private struct StateDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

private func tokens(_ count: Int) -> String {
    count.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
}

private func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .memory))
}

private func money(_ amount: Double) -> String {
    amount.formatted(.currency(code: "USD").presentation(.narrow).precision(.fractionLength(amount < 10 ? 2 : 0)))
}

private func duration(_ seconds: Int) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
}

// MARK: Status

private struct AgentStatusCard: View {
    let entry: AgentEntry
    let report: AgentReport
    let age: TimeInterval?

    private var isStale: Bool {
        (age ?? .infinity) > AgentBoard.staleAfter
    }

    private var health: (String, Color) {
        if isStale { return ("No recent report", .secondary) }
        switch report.agent?.health {
        case .online: return ("Online", .agent)
        case .degraded: return ("Partly working", .orange)
        case .offline: return ("Offline", .red)
        case nil: return ("Reporting", .agent)
        }
    }

    var body: some View {
        Card(title: entry.name, systemImage: "sparkles") {
            HStack(spacing: 8) {
                StateDot(color: health.1)
                Text(health.0)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let age {
                    Text("Updated \(Date.now.addingTimeInterval(-age), format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let detail = report.agent?.healthDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let agent = report.agent {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Software", value: [agent.software, agent.version].compactMap(\.self).joined(separator: " "))
                    if let model = agent.model {
                        LabeledContent("Model", value: model)
                    }
                    if let fallbacks = agent.fallbacks, !fallbacks.isEmpty {
                        LabeledContent("Fallbacks", value: fallbacks.joined(separator: ", "))
                    }
                    ForEach(agent.channels ?? [], id: \.self) { channel in
                        LabeledContent(channel.name) {
                            HStack(spacing: 6) {
                                StateDot(color: channel.connected ? .agent : .red)
                                Text(channel.connected ? "Connected" : "Not connected")
                            }
                        }
                    }
                    if let since = agent.since {
                        LabeledContent("Running since") {
                            Text(since, format: .relative(presentation: .named))
                        }
                    }
                }
                .font(.subheadline)
            }
            let today = entry.today
            Text("Today: \(today.created) added, \(today.updated) changed, \(today.completed) completed, \(today.commented) comments")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Items

// Items an agent waits on: a question for the owner, or work to look at. Shown for the whole
// workspace, since a stage belongs to the item and not to one agent.
private struct WaitingCard: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation

    private var items: [Item] {
        store.openItems.filter { ["needs_answer", "review"].contains($0.agentStage) }
    }

    var body: some View {
        Card(title: "Waiting for You", systemImage: "hand.raised") {
            if items.isEmpty {
                Text("Nothing waits for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    ItemLine(item: item, note: item.agentStage == "review" ? "To review" : "Question")
                }
            }
        }
    }
}

private struct WorkingCard: View {
    @Environment(Store.self) private var store
    let runs: [AgentRun]

    private static func note(for stage: String?) -> String {
        switch stage {
        case "gathering": "Gathering"
        case "ready": "Ready to start"
        default: "Running"
        }
    }

    private var items: [Item] {
        store.openItems.filter { ["running", "gathering", "ready"].contains($0.agentStage) }
    }

    var body: some View {
        Card(title: "Working On", systemImage: "gearshape.2") {
            if items.isEmpty, runs.isEmpty {
                Text("Nothing runs right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ItemLine(item: item, note: Self.note(for: item.agentStage))
            }
            ForEach(runs) { run in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StateDot(color: run.isBusy ? .agent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(run.kind), \(run.isBusy ? "working" : "idle")")
                            if let started = run.startedAt {
                                Text("· started \(started, format: .relative(presentation: .named))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ItemLine: View {
    @Environment(Navigation.self) private var navigation
    @Environment(Store.self) private var store
    let item: Item
    let note: String

    var body: some View {
        Button {
            navigation.itemID = item.id
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text([note, store.projectName(item.projectId)].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Money and limits

private struct PlanLimitsCard: View {
    let accounts: [AgentAccount]

    var body: some View {
        Card(title: "Plan Limits", systemImage: "gauge.with.dots.needle.50percent") {
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name)
                            .font(.subheadline.weight(.medium))
                        if let plan = account.plan {
                            Text(plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let usedBy = account.usedBy, !usedBy.isEmpty {
                            Text(usedBy.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(account.windows ?? [], id: \.self) { window in
                        LimitBar(window: window)
                    }
                }
            }
        }
    }
}

private struct LimitBar: View {
    let window: AgentWindow

    private var isNearLimit: Bool {
        window.usedPercent >= 90
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(window.usedPercent.rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(isNearLimit ? .red : .primary)
            }
            .font(.footnote)
            ProgressView(value: min(window.usedPercent, 100), total: 100)
                .tint(isNearLimit ? .red : .agent)
            if let resets = window.resetsAt {
                Text("Resets \(resets, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SpendCard: View {
    let accounts: [AgentAccount]

    private var total: (today: Double, week: Double, month: Double, estimated: Bool) {
        accounts.compactMap(\.spend).reduce((0, 0, 0, false)) {
            ($0.0 + $1.today, $0.1 + $1.week, $0.2 + $1.month, $0.3 || $1.estimated)
        }
    }

    private struct Bar: Identifiable {
        var day: Date
        var account: String
        var cost: Double
        var id: String { "\(account) \(day)" }
    }

    private var bars: [Bar] {
        accounts.flatMap { account in
            (account.daily ?? []).compactMap { day in
                guard let date = day.day, let cost = day.cost else { return nil }
                return Bar(day: date, account: account.name, cost: cost)
            }
        }
    }

    private var models: [AgentModelUse] {
        accounts.flatMap { $0.models ?? [] }
            .filter { ($0.cost ?? 0) > 0 }
            .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
    }

    var body: some View {
        let total = total
        Card(title: "Spend", systemImage: "dollarsign.circle") {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                figure(total.today, "Today")
                figure(total.week, "7 days")
                figure(total.month, "30 days")
            }
            if total.estimated {
                Text("Estimated from the providers' prices. API keys only; plans are under Plan Limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Cost", bar.cost))
                    .foregroundStyle(by: .value("Account", bar.account))
            }
            .chartForegroundStyleScale(range: [Color.agent, Color.agent.opacity(0.45), Color.secondary])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let cost = value.as(Double.self) { Text(money(cost)) }
                    }
                }
            }
            .chartLegend(accounts.count > 1 ? .visible : .hidden)
            .frame(height: 120)
            .accessibilityLabel("Spend per day over 30 days")
            if !models.isEmpty {
                VStack(spacing: 6) {
                    ForEach(models) { model in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.model)
                                    .font(.subheadline)
                                Text("\(model.sessions) sessions, \(tokens(model.tokens)) tokens")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(model.cost ?? 0))
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func figure(_ amount: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(money(amount))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// Tokens used on plans, which have no price per token.
private struct PlanTokensCard: View {
    let accounts: [AgentAccount]

    var body: some View {
        Card(title: "Plan Usage", systemImage: "chart.bar") {
            ForEach(accounts) { account in
                let days = account.daily ?? []
                let total = days.reduce(0) { $0 + $1.tokens }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(tokens(total)) tokens in 30 days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Chart(days) { day in
                        if let date = day.day {
                            BarMark(x: .value("Day", date, unit: .day), y: .value("Tokens", day.tokens))
                                .foregroundStyle(Color.agent)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let count = value.as(Int.self) { Text(tokens(count)) }
                            }
                        }
                    }
                    .frame(height: 90)
                    ForEach(account.models ?? []) { model in
                        LabeledContent(model.model, value: "\(tokens(model.tokens)), \(model.sessions) sessions")
                            .font(.footnote)
                    }
                }
            }
        }
    }
}

// MARK: Jobs

private struct JobsCard: View {
    let jobs: [AgentJob]
    @State private var openJob: String?

    // Failing jobs first, then by the next run.
    private var ordered: [AgentJob] {
        jobs.sorted { left, right in
            if left.isFailing != right.isFailing { return left.isFailing }
            return (left.nextRunAt ?? .distantFuture) < (right.nextRunAt ?? .distantFuture)
        }
    }

    var body: some View {
        Card(title: "Scheduled Jobs", systemImage: "clock.arrow.circlepath") {
            ForEach(ordered) { job in
                JobRow(job: job, isOpen: openJob == job.name) {
                    withAnimation(.snappy) { openJob = openJob == job.name ? nil : job.name }
                }
                if job.id != ordered.last?.id { Divider() }
            }
        }
    }
}

private struct JobRow: View {
    let job: AgentJob
    let isOpen: Bool
    let toggle: () -> Void

    private var color: Color {
        if job.isFailing { return .red }
        if !job.enabled || job.lastStatus == nil { return .secondary }
        return .agent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StateDot(color: color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name)
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 4) {
                            if job.isFailing {
                                Text("Failed")
                                    .foregroundStyle(.red)
                                Text("·")
                                    .foregroundStyle(.secondary)
                            }
                            Text(job.enabled ? job.schedule : "Paused")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 8)
                    if let next = job.nextRunAt, next <= .now {
                        // The report is a little older than now, so a run it names as next
                        // may be over already.
                        Text("Due")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let next = job.nextRunAt {
                        Text(next, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    if let last = job.lastRunAt {
                        LabeledContent("Last run") {
                            Text("\(last, format: .relative(presentation: .named)), \(job.isFailing ? "failed" : "ok")")
                        }
                    } else {
                        LabeledContent("Last run", value: "Not yet")
                    }
                    if job.failureStreak > 1 {
                        LabeledContent("Failed in a row", value: "\(job.failureStreak)")
                    }
                    if let error = job.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    LabeledContent("Woke a model this week", value: "\(job.runsWeek) times")
                    if job.tokensWeek > 0 {
                        LabeledContent("Tokens this week", value: tokens(job.tokensWeek))
                    }
                    if let seconds = job.lastDurationS {
                        LabeledContent("Last model run took", value: Duration.seconds(seconds).formatted(.units(width: .abbreviated, maximumUnitCount: 2)))
                    }
                }
                .font(.footnote)
                .padding(.leading, 16)
            }
        }
    }
}

// MARK: Machine

private struct MachineCard: View {
    let host: AgentHost

    private var memoryShare: Double {
        host.memoryTotal > 0 ? Double(host.memoryUsed) / Double(host.memoryTotal) * 100 : 0
    }

    private var diskShare: Double {
        host.diskTotal > 0 ? Double(host.diskUsed) / Double(host.diskTotal) * 100 : 0
    }

    var body: some View {
        Card(title: host.name, systemImage: "desktopcomputer") {
            Text([host.chip, host.cores > 0 ? "\(host.cores) cores" : nil, host.os].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                Meter(label: "CPU", percent: host.cpuPercent, detail: host.load.first.map { "Load \($0.formatted(.number.precision(.fractionLength(1))))" })
                Meter(label: "Memory", percent: memoryShare, detail: "\(bytes(host.memoryUsed)) of \(bytes(host.memoryTotal))")
                Meter(label: "Disk", percent: diskShare, detail: "\(bytes(host.diskTotal - host.diskUsed)) free")
            }
            if let free = host.memoryFreePercent {
                Text(free < 20 ? "Memory is tight: \(Int(free)) % free." : "Memory pressure is low: \(Int(free)) % free.")
                    .font(.caption)
                    .foregroundStyle(free < 20 ? .red : .secondary)
            }
            if host.series.count > 1 {
                Chart(host.series) { sample in
                    LineMark(x: .value("Time", sample.at), y: .value("CPU", sample.cpuPercent))
                        .foregroundStyle(Color.agent)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0 ... 100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) %") } }
                    }
                }
                .frame(height: 80)
                .accessibilityLabel("CPU over the last 24 hours")
            }
            VStack(spacing: 6) {
                ForEach(host.top.prefix(6)) { process in
                    HStack {
                        Text(process.count > 1 ? "\(process.name) (\(process.count))" : process.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(process.cpuPercent.formatted(.number.precision(.fractionLength(1)))) %")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 52, alignment: .trailing)
                        Text(bytes(process.memory))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .font(.footnote)
                }
            }
            Text("Up \(duration(host.uptimeS))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Meter: View {
    let label: String
    let percent: Double
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(Int(percent.rounded())) %")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(percent >= 90 ? .red : .primary)
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(percent >= 90 ? .red : .agent)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
