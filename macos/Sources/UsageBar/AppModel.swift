import Foundation
import ServiceManagement

struct AccountState {
    var snapshot: Snapshot?
    var error: UsageError?
    var lastUpdated: Date?
    var isLoading = false

    var ratio: Double { snapshot == nil && error.map { !$0.isRateLimit } == true ? 1 : (snapshot?.ratio ?? 0) }
    var menuBarText: String {
        if let snapshot { return snapshot.headline }
        if let error { return error.short }
        return "…"
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var states: [String: AccountState] = [:]
    @Published private(set) var disabled: Set<String>
    @Published private(set) var lastActive: [String: Date]
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var flashUntil: [String: Date] = [:]
    private var lastFetch: [String: Date] = [:]
    private var lastActivityKey: [String: Double] = [:]
    private var backoffUntil: [String: Date] = [:]
    private var backoffStep: [String: Int] = [:]
    private var lastDiscovery = Date.distantPast

    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        disabled = Set(defaults.stringArray(forKey: "disabledAccounts") ?? [])
        let stored = defaults.dictionary(forKey: "lastActive") as? [String: Double] ?? [:]
        lastActive = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Selected accounts, most recently used first.
    var visibleAccounts: [Account] {
        accounts.filter { !disabled.contains($0.id) }.sorted {
            (lastActive[$0.id] ?? .distantPast) > (lastActive[$1.id] ?? .distantPast)
        }
    }

    /// The account shown in the menu bar: whichever sent the latest request.
    var activeAccount: Account? { visibleAccounts.first }

    func state(_ account: Account) -> AccountState { states[account.id] ?? AccountState() }

    func isFlashing(_ account: Account) -> Bool { Date() < (flashUntil[account.id] ?? .distantPast) }

    func isEnabled(_ account: Account) -> Bool { !disabled.contains(account.id) }

    func setEnabled(_ account: Account, _ enabled: Bool) {
        if enabled { disabled.remove(account.id) } else { disabled.insert(account.id) }
        UserDefaults.standard.set(Array(disabled), forKey: "disabledAccounts")
        if enabled { Task { await refresh(account, force: true) } }
        onChange?()
    }

    // MARK: Refresh

    /// Called every 15s. Re-scans accounts every few minutes and refreshes whatever is due.
    func tick(force: Bool = false) async {
        if force || accounts.isEmpty || Date().timeIntervalSince(lastDiscovery) > 300 {
            lastDiscovery = Date()
            accounts = await Task.detached { AccountDiscovery.discover() }.value
            seedLastActive()
        }
        await updateLocalActivity()
        await withTaskGroup(of: Void.self) { group in
            for account in visibleAccounts {
                group.addTask { await self.refresh(account, force: force) }
            }
        }
        onChange?()
    }

    func refresh(_ account: Account, force: Bool = false) async {
        var state = states[account.id] ?? AccountState()
        if state.isLoading { return }
        // Rate limited: wait it out even on a forced refresh, or we only dig the hole deeper.
        if Date() < (backoffUntil[account.id] ?? .distantPast) { return }
        if !force, let last = lastFetch[account.id] {
            // Claude: fetch early if this account just sent a request (transcript changed).
            let usedSince = account.provider == .claude && (lastActive[account.id] ?? .distantPast) > last
            let due = Date().timeIntervalSince(last) >= account.provider.pollInterval - 1
            if !due && !(usedSince && Date().timeIntervalSince(last) > 20) { return }
        }
        lastFetch[account.id] = Date()
        state.isLoading = true
        states[account.id] = state

        do {
            let snap: Snapshot
            switch account.provider {
            case .cursor: snap = try await CursorProvider.fetch(account)
            case .claude: snap = try await ClaudeProvider.fetch(account)
            }
            if let previous = lastActivityKey[account.id], snap.activityKey > previous + 0.009 {
                flashUntil[account.id] = Date().addingTimeInterval(8)
                markActive(account, at: Date())
            }
            lastActivityKey[account.id] = snap.activityKey
            backoffStep[account.id] = nil
            state.snapshot = snap
            state.error = nil
            state.lastUpdated = Date()
        } catch {
            // Keep the last good numbers for transient failures (rate limits, network blips).
            let usageError = (error as? UsageError) ?? UsageError(short: L.offline, long: error.localizedDescription)
            if usageError.isRateLimit {
                // 2, 4, 8 … up to 30 minutes, unless the server named a time.
                let step = (backoffStep[account.id] ?? 0) + 1
                backoffStep[account.id] = step
                let wait = usageError.retryAfter ?? min(1800, 60 * pow(2, Double(step)))
                backoffUntil[account.id] = Date().addingTimeInterval(wait)
            }
            state.error = usageError
        }
        state.isLoading = false
        states[account.id] = state
        onChange?()
    }

    // MARK: Last-used tracking

    private func markActive(_ account: Account, at date: Date) {
        guard date > (lastActive[account.id] ?? .distantPast) else { return }
        lastActive[account.id] = date
        UserDefaults.standard.set(lastActive.mapValues { $0.timeIntervalSince1970 }, forKey: "lastActive")
    }

    /// Claude Code writes a transcript line for every request, so its newest mtime is an exact "last used".
    private func updateLocalActivity() async {
        let claude = accounts.filter { $0.provider == .claude && !disabled.contains($0.id) }
        let found = await Task.detached {
            claude.compactMap { a in AccountDiscovery.claudeLastActivity(configDir: a.source).map { (a, $0) } }
        }.value
        for (account, date) in found { markActive(account, at: date) }
    }

    /// First run: until an account is seen in use, order Cursor accounts by their state DB mtime.
    private func seedLastActive() {
        for account in accounts where account.provider == .cursor && lastActive[account.id] == nil {
            let attrs = try? FileManager.default.attributesOfItem(atPath: account.source)
            if let date = attrs?[.modificationDate] as? Date { markActive(account, at: date) }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("UsageBar: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Demo data

extension AppModel {
    /// Fake accounts run through the real parsers, so README screenshots never show anyone's data.
    func loadDemo() {
        func iso(_ hours: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600))
        }
        let claude = Account(provider: .claude, source: "~/.claude-work", isDefault: false, email: "you@example.com", name: "work")
        let cursorWork = Account(provider: .cursor, source: "~/.cursor-work", isDefault: false, email: "you@example.com", name: "work")
        let cursorHome = Account(provider: .cursor, source: "~/.cursor", isDefault: true, email: "you@example.com", name: "Cursor")

        let claudeSnap = ClaudeProvider.parse([
            "five_hour": ["utilization": 42, "resets_at": iso(2.2)],
            "seven_day": ["utilization": 67, "resets_at": iso(81)],
            "seven_day_opus": ["utilization": 18, "resets_at": iso(81)],
            "extra_usage": ["is_enabled": true, "used_credits": 1234, "monthly_limit": 5000, "currency": "USD"],
        ], plan: "max")
        let cycleEnd = (Date().timeIntervalSince1970 + 12 * 86_400) * 1000
        let workSnap = CursorProvider.parse([
            "spendLimitUsage": ["limitType": "team", "pooledUsed": 4210, "individualUsed": 1180, "pooledLimit": 20000],
            "planUsage": ["totalSpend": 2000, "limit": 2000, "autoPercentUsed": 64, "apiPercentUsed": 38],
            "billingCycleEnd": cycleEnd,
        ])
        let homeSnap = CursorProvider.parse([
            "spendLimitUsage": ["individualUsed": 0, "individualLimit": 1000],
            "planUsage": ["totalSpend": 740, "limit": 2000, "autoPercentUsed": 23, "apiPercentUsed": 9],
            "billingCycleEnd": cycleEnd,
        ])

        accounts = [claude, cursorWork, cursorHome]
        disabled = []
        let now = Date()
        lastActive = [claude.id: now, cursorWork.id: now.addingTimeInterval(-600), cursorHome.id: now.addingTimeInterval(-7200)]
        for (account, snap) in [(claude, claudeSnap), (cursorWork, workSnap), (cursorHome, homeSnap)] {
            states[account.id] = AccountState(snapshot: snap, error: nil, lastUpdated: now)
        }
    }
}
