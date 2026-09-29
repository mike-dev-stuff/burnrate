import AppKit
import Foundation
import SwiftUI

@Observable
final class UsageViewModel {
    var currentSession: CurrentSession?
    var usageLimits: UsageLimits?
    var codexUsageLimits: CodexUsageLimits?
    var accountInfo: AccountInfo = .empty
    var recentSessions: [SessionInfo] = []
    var isTokenExpired: Bool = true
    var errorMessage: String?
    var isLoading: Bool = false

    /// Whether the menubar popover is on screen. Set by AppDelegate from the
    /// popover delegate callbacks. SwiftUI's onDisappear does not fire when an
    /// NSPopover closes (its content view stays alive in a hidden window), so
    /// views use this to stop repeating animations that would otherwise keep
    /// the hidden popover rendering at full frame rate.
    var isPopoverVisible: Bool = false

    // Multi-provider usage data
    var providerUsages: [String: ProviderUsage] = [:]

    // Provider registry (order determines display order)
    let providerInfos: [ProviderInfo] = [
        ProviderInfo(id: "claude", name: "Claude", icon: "message.fill", brandColor: 0xDA7756, unavailableMessage: "Run 'claude' to refresh your OAuth token", installCommand: "npm install -g @anthropic-ai/claude-code"),
        ProviderInfo(id: "codex", name: "Codex", icon: "terminal.fill", brandColor: 0x10A37F, unavailableMessage: "Install Codex CLI to track usage", installCommand: "npm install -g @openai/codex"),
    ]

    // Analytics data
    var snapshots: [UsageSnapshot] = []
    var todayStats: DailyStats = .empty
    var weekStats: (tokens: Int, sessions: Int, cost: Double) = (0, 0, 0)

    // Services
    let notificationService = NotificationService()
    let settingsService = SettingsService()
    private let sessionParser = SessionParser()
    private let codexSessionParser = CodexSessionParser()
    private let accountParser = AccountParser()
    private let usageAPI = UsageAPIClient()
    private let analyticsStore = AnalyticsStore()
    private let supabaseClient = SupabaseClient()
    private var refreshTimer: Timer?
    @ObservationIgnored private var isRefreshing = false

    /// Everything read from local files during one refresh. Gathered on a
    /// background task so disk and keychain I/O never block the main thread.
    private struct LocalSnapshot {
        let recentSessions: [SessionInfo]
        let currentSession: CurrentSession?
        let accountInfo: AccountInfo
        let isTokenExpired: Bool
        let codexUsageLimits: CodexUsageLimits?
    }

    // Track previous values for threshold detection
    private var previousFiveHour: Double?
    private var previousSevenDay: Double?

    var isCodexInstalled: Bool {
        codexSessionParser.isCodexInstalled
    }

    func providerIsInstalled(_ providerId: String) -> Bool {
        switch providerId {
        case "claude": return !isTokenExpired
        case "codex": return isCodexInstalled
        default: return false
        }
    }

    /// Whether a provider has real usage tracking implemented (vs stub)
    func providerHasTracking(_ providerId: String) -> Bool {
        switch providerId {
        case "claude", "codex": return true
        default: return false
        }
    }

    var menubarTitle: String {
        // Get limits based on selected source
        let (fiveHour, sevenDay) = getMenubarLimits()

        guard fiveHour != nil || sevenDay != nil else {
            switch settingsService.menubarSource {
            case .claude:
                return isTokenExpired ? "!" : "--"
            case .codex:
                return isCodexInstalled ? "--" : "!"
            }
        }

        let fiveHourValue = fiveHour ?? 0
        let sevenDayValue = sevenDay ?? 0

        switch settingsService.menubarDisplay {
        case .sevenDay:
            return "\(Int(sevenDayValue.rounded()))%"
        case .fiveHour:
            return "\(Int(fiveHourValue.rounded()))%"
        case .both:
            return "\(Int(fiveHourValue.rounded()))|\(Int(sevenDayValue.rounded()))"
        case .iconOnly, .chart:
            return ""
        }
    }

    var menubarEmoji: String {
        let (fiveHour, sevenDay) = getMenubarLimits()

        guard fiveHour != nil || sevenDay != nil else {
            return "🔥"
        }

        let fiveHourValue = fiveHour ?? 0
        let sevenDayValue = sevenDay ?? 0

        // Use the displayed metric, or max of both if showing "both" or "icon only"
        let percentage: Double
        switch settingsService.menubarDisplay {
        case .sevenDay:
            percentage = sevenDayValue
        case .fiveHour:
            percentage = fiveHourValue
        case .both, .iconOnly, .chart:
            percentage = max(fiveHourValue, sevenDayValue)
        }

        if percentage >= 90 {
            return "🚨"
        } else {
            return "🔥"
        }
    }

    private func getMenubarLimits() -> (fiveHour: Double?, sevenDay: Double?) {
        let sourceId: String
        switch settingsService.menubarSource {
        case .claude: sourceId = "claude"
        case .codex: sourceId = "codex"
        }

        if let usage = providerUsages[sourceId] {
            return (usage.primaryUtilization, usage.secondaryUtilization)
        }

        // Fallback for Claude (uses legacy path before providerUsages is populated)
        if sourceId == "claude", let limits = usageLimits {
            return (limits.fiveHourUtilization, limits.sevenDayUtilization)
        }
        if sourceId == "codex", let limits = codexUsageLimits {
            return (limits.fiveHourUtilization, limits.weeklyUtilization)
        }

        return (nil, nil)
    }

    var menubarIcon: NSImage? {
        let (fiveHour, sevenDay) = getMenubarLimits()

        return MenubarIconRenderer.render(
            fiveHour: fiveHour ?? 0,
            sevenDay: sevenDay ?? 0,
            colorScheme: settingsService.menubarColorScheme
        )
    }

    func startAutoRefresh() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        // A refresh already in flight will publish shortly; don't stack another.
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        errorMessage = nil

        let sessionParser = self.sessionParser
        let codexSessionParser = self.codexSessionParser
        let accountParser = self.accountParser

        Task {
            // Session file parsing and the keychain lookup (a `security`
            // subprocess) are blocking work; keep them off the main thread.
            let local = await Task.detached(priority: .utility) {
                LocalSnapshot(
                    recentSessions: sessionParser.getRecentSessions(),
                    currentSession: sessionParser.getCurrentSession(),
                    accountInfo: accountParser.getAccountInfo(),
                    isTokenExpired: KeychainService.isTokenExpired(),
                    codexUsageLimits: codexSessionParser.getUsageLimits()
                )
            }.value

            // Show local data as soon as it is ready; the API call may be slow.
            await MainActor.run {
                self.apply(local)
            }

            let todayTokens = Self.todayTokens(in: local.recentSessions)
            let todaySessions = Self.todaySessionCount(in: local.recentSessions)

            let limits = await usageAPI.fetchUsage()

            // Record analytics
            if let limits = limits {
                await analyticsStore.recordSnapshot(
                    fiveHour: limits.fiveHourUtilization,
                    sevenDay: limits.sevenDayUtilization,
                    opus: limits.opusUtilization
                )

                await analyticsStore.recordDailyStats(tokens: todayTokens, sessions: todaySessions)
            }

            // Load analytics data
            let allSnapshots = await analyticsStore.getAllSnapshots()
            let today = await analyticsStore.getTodayStats()
            let week = await analyticsStore.getWeekStats()

            await MainActor.run {
                self.usageLimits = limits
                self.snapshots = allSnapshots
                self.todayStats = today
                self.weekStats = week
                self.isLoading = false
                self.isRefreshing = false

                // Map Claude to provider usage
                if let limits = limits {
                    var extraInfo: [String: String] = [:]
                    if limits.opusUtilization > 0 || limits.opusResetsAt != nil {
                        extraInfo["opusUtilization"] = String(format: "%.0f", limits.opusUtilization)
                    }

                    self.providerUsages["claude"] = ProviderUsage(
                        primaryUtilization: limits.fiveHourUtilization,
                        primaryLabel: "5-hour",
                        primaryResetsAt: limits.fiveHourResetsAt,
                        secondaryUtilization: limits.sevenDayUtilization,
                        secondaryLabel: "7-day",
                        secondaryResetsAt: limits.sevenDayResetsAt,
                        extraInfo: extraInfo.isEmpty ? nil : extraInfo
                    )

                    // Check for alerts
                    self.notificationService.checkAndNotify(
                        fiveHour: limits.fiveHourUtilization,
                        sevenDay: limits.sevenDayUtilization,
                        previousFiveHour: self.previousFiveHour,
                        previousSevenDay: self.previousSevenDay
                    )

                    self.previousFiveHour = limits.fiveHourUtilization
                    self.previousSevenDay = limits.sevenDayUtilization
                } else {
                    self.providerUsages.removeValue(forKey: "claude")
                }

                // Push all provider data to Supabase
                if self.settingsService.supabaseSyncEnabled && !self.providerUsages.isEmpty {
                    let usages = self.providerUsages
                    let userId = self.settingsService.supabaseUserId
                    Task.detached { [supabaseClient] in
                        await supabaseClient.pushUsage(userId: userId, providers: usages)
                    }
                }
            }
        }
    }

    /// Publishes the locally parsed data. Must be called on the main thread.
    private func apply(_ local: LocalSnapshot) {
        recentSessions = local.recentSessions
        currentSession = local.currentSession
        accountInfo = local.accountInfo
        isTokenExpired = local.isTokenExpired
        codexUsageLimits = local.codexUsageLimits

        // Map Codex to provider usage
        if let codex = local.codexUsageLimits {
            providerUsages["codex"] = ProviderUsage(
                primaryUtilization: codex.fiveHourUtilization,
                primaryLabel: "5-hour",
                primaryResetsAt: codex.fiveHourResetsAt,
                secondaryUtilization: codex.weeklyUtilization,
                secondaryLabel: "Weekly",
                secondaryResetsAt: codex.weeklyResetsAt,
                extraInfo: nil
            )
        } else {
            providerUsages.removeValue(forKey: "codex")
        }
    }

    private static func todayTokens(in sessions: [SessionInfo]) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return sessions
            .filter { calendar.startOfDay(for: $0.timestamp) == today }
            .reduce(0) { $0 + $1.totalTokens }
    }

    private static func todaySessionCount(in sessions: [SessionInfo]) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return sessions
            .filter { calendar.startOfDay(for: $0.timestamp) == today }
            .count
    }

    func openSession(_ session: SessionInfo) {
        let cmd = "cd \"\(session.projectPath)\" && claude --resume \(session.id)"
        let script = "tell application \"Terminal\" to do script \"\(cmd)\""

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func openClaude() {
        let script = "tell application \"Terminal\" to do script \"claude\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}
