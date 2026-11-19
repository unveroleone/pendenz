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

// The state of something an agent reports, and its one color. The rest of the screen stays
// black and white, as the app does: color only says whether something is fine.
enum AgentLevel {
    case good, warning, problem, idle

    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .problem: .red
        case .idle: .secondary
        }
    }

    // A share of a limit or of the machine: fine below 75 %, a warning to 90 %, a problem above.
    init(percent: Double) {
        self = percent >= 90 ? .problem : percent >= 75 ? .warning : .good
    }
}

// What the agents do and cost, as one grouped list like Settings: what needs the owner first,
// then the limits, the work, the jobs, the money and the machine. Details open on pages of
// their own, so the list stays short on the iPhone.
struct AgentsView: View {
    @Environment(AgentBoard.self) private var board
    @SceneStorage("chosenAgent") private var chosenAgent = ""
    @AppStorage(AgentBoard.orderKey) private var order = ""

    private var agents: [AgentEntry] {
        board.reporting(in: order)
    }

    private var entry: AgentEntry? {
        agents.first { $0.id == chosenAgent } ?? agents.first
    }

    var body: some View {
        Group {
            if let entry, entry.isReportUnreadable {
                ContentUnavailableView(
                    "Report Not Readable", systemImage: "exclamationmark.triangle",
                    description: Text(
                        "\(entry.name) sent a report this version of the app cannot read. Update the app.",
                    ),
                )
            } else if let entry, let report = entry.report {
                AgentForm(entry: entry, report: report)
            } else if board.list == nil, board.problem == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Agent Reports", systemImage: Place.agents.systemImage)
                } description: {
                    Text(
                        board.problem == .outdated
                            ? "The server is older than agent reports. Update it to see your agents."
                            : "An agent shows up here once it sends a report. Connect one in Settings.",
                    )
                }
            }
        }
        // Above every state of the screen, so an unreadable report never hides the way back.
        .safeAreaInset(edge: .top, spacing: 0) {
            if agents.count > 1, let entry {
                AgentSwitcher(agents: agents, chosen: entry.id) { chosenAgent = $0 }
            }
        }
        .navigationTitle("Agents")
        .refreshable { await board.refresh() }
        .task { await board.watch() }
    }
}

private struct AgentForm: View {
    @Environment(AgentBoard.self) private var board
    @Environment(Store.self) private var store
    let entry: AgentEntry
    let report: AgentReport

    private var waiting: [Item] {
        store.openItems.filter { ["needs_answer", "review"].contains($0.agentStage) }
    }

    private var working: [Item] {
        store.openItems.filter { ["running", "gathering", "ready"].contains($0.agentStage) }
    }

    private var windows: [(account: AgentAccount, window: AgentWindow)] {
        (report.accounts ?? []).flatMap { account in
            (account.windows ?? []).map { (account, $0) }
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AgentDetailView(entry: entry, report: report)
                } label: {
                    StatusRow(entry: entry, report: report, age: board.age(of: entry))
                }
            } footer: {
                if board.problem == .unreachable, let fetchedAt = board.fetchedAt {
                    Text(
                        "Offline. Shown as the server reported it \(fetchedAt, format: .relative(presentation: .named)).",
                    )
                } else if board.problem == .outdated {
                    Text("The server is older than agent reports. Update it to see new ones.")
                }
            }
            if !waiting.isEmpty {
                Section("Waiting for You") {
                    ForEach(waiting) { item in
                        ItemLine(item: item, note: item.agentStage == "review" ? "To review" : "Question")
                    }
                }
            }
            if !windows.isEmpty {
                Section("Limits") {
                    ForEach(windows, id: \.window) { pair in
                        LimitRow(account: pair.account, window: pair.window)
                    }
                }
            }
            WorkingSection(items: working, runs: report.runs ?? [])
            if let jobs = report.jobs, !jobs.isEmpty {
                JobsSection(jobs: jobs)
            }
            if let accounts = report.accounts, !accounts.isEmpty {
                SpendSection(accounts: accounts)
            }
            if let host = report.host {
                MachineSection(host: host)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Formats

private func tokens(_ count: Int) -> String {
    count.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
}

private func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .memory))
}

private func money(_ amount: Double) -> String {
    amount.formatted(.currency(code: "USD").presentation(.narrow).precision(.fractionLength(amount < 10 ? 2 : 0)))
}

private func percent(_ value: Double) -> String {
    "\(Int(value.rounded())) %"
}

private struct StateDot: View {
    let level: AgentLevel

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

// A thin bar for a share, in the color of its state.
private struct ShareBar: View {
    let percent: Double

    var body: some View {
        ProgressView(value: min(max(percent, 0), 100), total: 100)
            .tint(AgentLevel(percent: percent).color)
            .accessibilityHidden(true)
    }
}

// MARK: Status

// How an agent is doing, from its report and how old that is.
private func agentHealth(_ report: AgentReport?, age: TimeInterval?) -> (text: String, level: AgentLevel) {
    guard let report, (age ?? .infinity) <= AgentBoard.staleAfter else { return ("No recent report", .idle) }
    switch report.agent?.health {
    case .online, nil: return ("Online", .good)
    case .degraded: return ("Partly working", .warning)
    case .offline: return ("Offline", .problem)
    }
}

// One pill per agent that reports, with the state of each, so another agent is one tap away.
// The chosen pill is filled like the app's other selected controls: black, or white in dark mode.
private struct AgentSwitcher: View {
    @Environment(AgentBoard.self) private var board
    let agents: [AgentEntry]
    let chosen: String
    let choose: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                pills
            }
            .scrollIndicators(.hidden)
            // A choice kept from before may be off the edge when there are many agents.
            .onAppear { proxy.scrollTo(chosen, anchor: .center) }
        }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            ForEach(agents) { agent in
                let health = agentHealth(agent.report, age: board.age(of: agent))
                let isChosen = agent.id == chosen
                Button {
                    choose(agent.id)
                } label: {
                    HStack(spacing: 6) {
                        StateDot(level: health.level)
                        Text(agent.name)
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(isChosen ? .semibold : .regular))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .foregroundStyle(isChosen ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                    .background(
                        Capsule().fill(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.fill.tertiary)),
                    )
                    // The pill is drawn 36 points high and takes taps over 44.
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(agent.name), \(health.text)")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
                .id(agent.id)
            }
        }
        .padding(.horizontal)
        // More room below than above: the pills belong to the title, and the list starts after.
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

private struct StatusRow: View {
    let entry: AgentEntry
    let report: AgentReport
    let age: TimeInterval?

    private var failing: Int {
        (report.jobs ?? []).count(where: \.isFailing)
    }

    private var health: (text: String, level: AgentLevel) {
        agentHealth(report, age: age)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Place.agents.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    StateDot(level: health.level)
                    Text(health.text)
                    if let age {
                        Text("· \(Date.now.addingTimeInterval(-age), format: .relative(presentation: .named))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // On its own line, so it never squeezes the state on a narrow screen.
                if failing > 0 {
                    Label(
                        failing == 1 ? "1 job failed" : "\(failing) jobs failed",
                        systemImage: "exclamationmark.circle.fill",
                    )
                    .font(.subheadline)
                    .foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentDetailView: View {
    let entry: AgentEntry
    let report: AgentReport

    var body: some View {
        Form {
            if let agent = report.agent {
                Section {
                    LabeledContent(
                        "Software",
                        value: [agent.software, agent.version].compactMap(\.self).joined(separator: " "),
                    )
                    if let model = agent.model {
                        LabeledContent("Model", value: model)
                    }
                    if let fallbacks = agent.fallbacks, !fallbacks.isEmpty {
                        LabeledContent("Fallbacks", value: fallbacks.joined(separator: ", "))
                    }
                    if let since = agent.since {
                        LabeledContent("Running since") {
                            Text(since, format: .relative(presentation: .named))
                        }
                    }
                } footer: {
                    if let detail = agent.healthDetail { Text(detail) }
                }
                if let channels = agent.channels, !channels.isEmpty {
                    Section("Channels") {
                        ForEach(channels, id: \.self) { channel in
                            LabeledContent(channel.name) {
                                HStack(spacing: 6) {
                                    StateDot(level: channel.connected ? .good : .problem)
                                    Text(channel.connected ? "Connected" : "Not connected")
                                }
                            }
                        }
                    }
                }
            }
            Section("Today") {
                LabeledContent("Items added", value: "\(entry.today.created)")
                LabeledContent("Items changed", value: "\(entry.today.updated)")
                LabeledContent("Items completed", value: "\(entry.today.completed)")
                LabeledContent("Comments", value: "\(entry.today.commented)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entry.name)
    }
}

// MARK: Items

private struct ItemLine: View {
    @Environment(Navigation.self) private var navigation
    @Environment(Store.self) private var store
    let item: Item
    let note: String

    var body: some View {
        Button {
            navigation.itemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text([note, store.projectName(item.projectId)].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct WorkingSection: View {
    let items: [Item]
    let runs: [AgentRun]

    private var busy: [AgentRun] {
        runs.filter(\.isBusy)
    }

    private static func note(for stage: String?) -> String {
        switch stage {
        case "gathering": "Gathering"
        case "ready": "Ready to start"
        default: "Running"
        }
    }

    var body: some View {
        if !items.isEmpty || !runs.isEmpty {
            Section("Working On") {
                ForEach(items) { item in
                    ItemLine(item: item, note: Self.note(for: item.agentStage))
                }
                ForEach(busy) { run in
                    HStack(spacing: 10) {
                        StateDot(level: .good)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.title)
                                .lineLimit(1)
                            if let started = run.startedAt {
                                Text("\(run.kind) · started \(started, format: .relative(presentation: .named))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                let idle = runs.count - busy.count
                if idle > 0 {
                    Text(idle == 1 ? "1 idle session" : "\(idle) idle sessions")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Limits

private struct LimitRow: View {
    let account: AgentAccount
    let window: AgentWindow

    // "Claude plan" and "Current week" read as "Claude · Current week".
    private var title: String {
        let name = account.name.replacingOccurrences(of: " plan", with: "")
        return "\(name) · \(window.label)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(percent(window.usedPercent))
                    .monospacedDigit()
                    .foregroundStyle(window.usedPercent >= 90 ? .red : .primary)
            }
            ShareBar(percent: window.usedPercent)
            if let resets = window.resetsAt {
                Text("Resets \(resets, format: .relative(presentation: .named))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Jobs

// A job that failed, or the time of its next run.
private struct JobRow: View {
    let job: AgentJob

    private var level: AgentLevel {
        if job.isFailing { return .problem }
        if !job.enabled || job.lastStatus == nil { return .idle }
        return .good
    }

    private var detail: Text {
        if job.isFailing, let last = job.lastRunAt {
            return Text("Failed \(last, format: .relative(presentation: .named))")
        }
        if !job.enabled { return Text("Paused") }
        guard let next = job.nextRunAt else { return Text(job.schedule) }
        if next <= .now { return Text("\(job.schedule) · due") }
        return Text("\(job.schedule) · next \(next, format: .relative(presentation: .named))")
    }

    var body: some View {
        HStack(spacing: 10) {
            StateDot(level: level)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                detail
                    .font(.subheadline)
                    .foregroundStyle(job.isFailing ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct JobsSection: View {
    let jobs: [AgentJob]

    // Failing jobs first, then by the next run.
    private var ordered: [AgentJob] {
        jobs.sorted { left, right in
            if left.isFailing != right.isFailing { return left.isFailing }
            return (left.nextRunAt ?? .distantFuture) < (right.nextRunAt ?? .distantFuture)
        }
    }

    var body: some View {
        let ordered = ordered
        // Every failing job, and the next ones to fill three rows.
        let shown = Array(ordered.prefix(max(3, ordered.count(where: \.isFailing))))
        Section("Scheduled Jobs") {
            ForEach(shown) { job in
                NavigationLink {
                    JobDetailView(job: job)
                } label: {
                    JobRow(job: job)
                }
            }
            if ordered.count > shown.count {
                NavigationLink("All \(ordered.count) Jobs") {
                    Form {
                        ForEach(ordered) { job in
                            NavigationLink {
                                JobDetailView(job: job)
                            } label: {
                                JobRow(job: job)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("Scheduled Jobs")
                }
            }
        }
    }
}

private struct JobDetailView: View {
    let job: AgentJob

    var body: some View {
        Form {
            Section {
                LabeledContent("Schedule", value: job.enabled ? job.schedule : "Paused")
                if let next = job.nextRunAt, job.enabled {
                    LabeledContent("Next run") {
                        Text(next, format: .relative(presentation: .named))
                    }
                }
                LabeledContent("Last run") {
                    if let last = job.lastRunAt {
                        Text("\(last, format: .relative(presentation: .named)), \(job.isFailing ? "failed" : "ok")")
                            .foregroundStyle(job.isFailing ? .red : .secondary)
                    } else {
                        Text("Not yet")
                    }
                }
                if job.failureStreak > 1 {
                    LabeledContent("Failed in a row", value: "\(job.failureStreak)")
                }
            } footer: {
                if let error = job.lastError { Text(error).foregroundStyle(.red) }
            }
            Section("This Week") {
                LabeledContent("Model runs", value: "\(job.runsWeek)")
                LabeledContent("Tokens", value: tokens(job.tokensWeek))
                if let seconds = job.lastDurationS {
                    LabeledContent(
                        "Last model run",
                        value: Duration.seconds(seconds).formatted(.units(width: .abbreviated, maximumUnitCount: 2)),
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(job.name)
    }
}

// MARK: Spend

private struct SpendSection: View {
    let accounts: [AgentAccount]

    private var paid: [AgentAccount] {
        accounts.filter { $0.kind == .api }
    }

    private var plans: [AgentAccount] {
        accounts.filter { $0.kind == .subscription && ($0.daily ?? []).contains { $0.tokens > 0 } }
    }

    var body: some View {
        let spends = paid.compactMap(\.spend)
        Section {
            if !spends.isEmpty {
                NavigationLink {
                    SpendView(accounts: paid)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Today")
                        Spacer()
                        Text(money(spends.reduce(0) { $0 + $1.today }))
                            .monospacedDigit()
                        Text("· \(money(spends.reduce(0) { $0 + $1.month })) in 30 days")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !plans.isEmpty {
                NavigationLink {
                    PlanUsageView(accounts: plans)
                } label: {
                    LabeledContent(
                        "Plan usage",
                        value: "\(tokens(plans.flatMap { $0.daily ?? [] }.reduce(0) { $0 + $1.tokens })) tokens",
                    )
                }
            }
        } header: {
            Text("Spend")
        } footer: {
            if spends.contains(where: \.estimated) {
                Text("API keys, estimated from the providers' prices. Plans are counted in tokens.")
            }
        }
    }
}

private struct SpendView: View {
    let accounts: [AgentAccount]

    private struct Bar: Identifiable {
        var day: Date
        var account: String
        var cost: Double
        var id: String { "\(account) \(day)" }
    }

    private var bars: [Bar] {
        accounts.flatMap { account in
            (account.daily ?? []).compactMap { day in
                guard let date = day.day, let cost = day.cost, cost > 0 else { return nil }
                return Bar(day: date, account: account.name, cost: cost)
            }
        }
    }

    var body: some View {
        let spends = accounts.compactMap(\.spend)
        Form {
            Section {
                LabeledContent("Today", value: money(spends.reduce(0) { $0 + $1.today }))
                LabeledContent("7 days", value: money(spends.reduce(0) { $0 + $1.week }))
                LabeledContent("30 days", value: money(spends.reduce(0) { $0 + $1.month }))
            }
            Section("Per Day") {
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Cost", bar.cost))
                        .foregroundStyle(by: .value("Account", bar.account))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let cost = value.as(Double.self) { Text(money(cost)) } }
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 8)
            }
            ForEach(accounts) { account in
                Section(account.name) {
                    ForEach(account.models ?? []) { model in
                        LabeledContent {
                            Text(money(model.cost ?? 0)).monospacedDigit()
                        } label: {
                            Text(model.model)
                            Text("\(model.sessions) sessions · \(tokens(model.tokens)) tokens")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Spend")
    }
}

private struct PlanUsageView: View {
    let accounts: [AgentAccount]

    var body: some View {
        Form {
            ForEach(accounts) { account in
                Section {
                    Chart(account.daily ?? []) { day in
                        if let date = day.day {
                            BarMark(x: .value("Day", date, unit: .day), y: .value("Tokens", day.tokens))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if let count = value.as(Int.self) { Text(tokens(count)) } }
                        }
                    }
                    .frame(height: 140)
                    .padding(.vertical, 8)
                    ForEach(account.models ?? []) { model in
                        LabeledContent {
                            Text(tokens(model.tokens)).monospacedDigit()
                        } label: {
                            Text(model.model)
                            Text("\(model.sessions) sessions")
                        }
                    }
                } header: {
                    Text(account.name)
                } footer: {
                    if let usedBy = account.usedBy, !usedBy.isEmpty {
                        Text("Used by \(usedBy.joined(separator: " and ")) in the last 30 days.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Plan Usage")
    }
}

// MARK: Machine

private func memoryShare(_ host: AgentHost) -> Double {
    host.memoryTotal > 0 ? Double(host.memoryUsed) / Double(host.memoryTotal) * 100 : 0
}

private func diskShare(_ host: AgentHost) -> Double {
    host.diskTotal > 0 ? Double(host.diskUsed) / Double(host.diskTotal) * 100 : 0
}

private struct MeterRow: View {
    let label: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Text(detail)
                    .foregroundStyle(.secondary)
                Text(percent(value))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            ShareBar(percent: value)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// The machine's load, with its programs, its last day and its details folded in below, so
// they open in place.
private struct MachineSection: View {
    enum Sorting: String, CaseIterable, Identifiable {
        case memory = "Memory"
        case cpu = "CPU"
        var id: Self { self }
    }

    let host: AgentHost
    @AppStorage("agentsProcessSorting") private var sorting = Sorting.memory
    @AppStorage("agentsProgramsOpen") private var isProgramsOpen = false
    @AppStorage("agentsHistoryOpen") private var isHistoryOpen = false
    @AppStorage("agentsMachineOpen") private var isDetailsOpen = false

    // Highest first by what is chosen.
    private var programs: [AgentProcess] {
        switch sorting {
        case .memory: host.top.sorted { $0.memory > $1.memory }
        case .cpu: host.top.sorted { $0.cpuPercent > $1.cpuPercent }
        }
    }

    // The share of the machine a program takes: of all memory, or of all cores.
    private func share(_ process: AgentProcess) -> Double {
        switch sorting {
        case .memory: host.memoryTotal > 0 ? Double(process.memory) / Double(host.memoryTotal) * 100 : 0
        case .cpu: process.cpuPercent
        }
    }

    var body: some View {
        Section(host.name) {
            MeterRow(label: "CPU", value: host.cpuPercent, detail: "\(host.cores) cores")
            MeterRow(
                label: "Memory",
                value: memoryShare(host),
                detail: "\(bytes(host.memoryUsed)) of \(bytes(host.memoryTotal))",
            )
            MeterRow(label: "Disk", value: diskShare(host), detail: "\(bytes(host.diskTotal - host.diskUsed)) free")
            DisclosureGroup("Programs", isExpanded: $isProgramsOpen) {
                Picker("Sort by", selection: $sorting) {
                    ForEach(Sorting.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ForEach(programs) { process in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(process.count > 1 ? "\(process.name) (\(process.count))" : process.name)
                                .lineLimit(1)
                            Spacer()
                            Text(
                                sorting == .memory
                                    ? bytes(process.memory)
                                    : "\(process.cpuPercent.formatted(.number.precision(.fractionLength(1)))) %",
                            )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                        ShareBar(percent: share(process))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if host.series.count > 1 {
                DisclosureGroup("CPU, Last 24 Hours", isExpanded: $isHistoryOpen) {
                    Chart(host.series) { sample in
                        AreaMark(x: .value("Time", sample.at), y: .value("CPU", sample.cpuPercent))
                            .foregroundStyle(.green.opacity(0.15))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", sample.at), y: .value("CPU", sample.cpuPercent))
                            .foregroundStyle(.green)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0 ... 100)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) %") } }
                        }
                    }
                    .frame(height: 140)
                    .padding(.vertical, 8)
                    .accessibilityLabel("CPU over the last 24 hours")
                }
            }
            DisclosureGroup("Details", isExpanded: $isDetailsOpen) {
                if let chip = host.chip { LabeledContent("Chip", value: chip) }
                if let os = host.os { LabeledContent("System", value: os) }
                if let load = host.load.first {
                    LabeledContent("Load", value: load.formatted(.number.precision(.fractionLength(2))))
                }
                if let free = host.memoryFreePercent {
                    LabeledContent("Memory free", value: percent(free))
                }
                LabeledContent("Swap", value: bytes(host.swapUsed))
                LabeledContent(
                    "Up",
                    value: Duration.seconds(host.uptimeS)
                        .formatted(.units(
                            allowed: [.days, .hours, .minutes],
                            width: .abbreviated,
                            maximumUnitCount: 2,
                        )),
                )
            }
        }
    }
}
