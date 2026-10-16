import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: UsageViewModel
    let onQuit: () -> Void
    let onShowSettings: () -> Void

    @State private var isRefreshing = false
    @State private var scrollContentHeight: CGFloat = 0
    @State private var showCopiedToast = false
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var expandedProviders: Set<String>

    init(viewModel: UsageViewModel, onQuit: @escaping () -> Void, onShowSettings: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onQuit = onQuit
        self.onShowSettings = onShowSettings

        // Load persisted expansion state, default to all expanded
        if let saved = UserDefaults.standard.array(forKey: "expandedProviders") as? [String] {
            self._expandedProviders = State(initialValue: Set(saved))
        } else {
            self._expandedProviders = State(initialValue: Set<String>())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(
                isLoading: viewModel.isLoading,
                isRefreshing: isRefreshing,
                onRefresh: {
                    withAnimation(BurnrateTheme.springSnappy) {
                        isRefreshing = true
                    }
                    viewModel.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(BurnrateTheme.springSnappy) {
                            isRefreshing = false
                        }
                    }
                },
                onSettings: onShowSettings,
                onQuit: onQuit
            )
            .padding(.horizontal, BurnrateTheme.spacingLG)
            .padding(.top, BurnrateTheme.spacingLG)
            .padding(.bottom, BurnrateTheme.spacingMD)

            // Content
            ScrollView {
                VStack(spacing: BurnrateTheme.spacingMD) {
                    // Error message
                    if let error = viewModel.errorMessage {
                        ErrorBanner(message: error)
                    }

                    // Usage summary (quick glance across all LLMs)
                    UsageSummaryView(
                        providerInfos: viewModel.providerInfos,
                        providerUsages: viewModel.providerUsages,
                        isInstalled: { viewModel.providerIsInstalled($0) },
                        hasTracking: { viewModel.providerHasTracking($0) }
                    )

                    // Expandable provider detail sections
                    ForEach(viewModel.providerInfos, id: \.id) { info in
                        ProviderUsageCard(
                            providerInfo: info,
                            usage: viewModel.providerUsages[info.id],
                            isInstalled: viewModel.providerIsInstalled(info.id),
                            hasTracking: viewModel.providerHasTracking(info.id),
                            isExpanded: expandedBinding(for: info.id),
                            extraContent: extraContent(for: info.id)
                        )
                    }

                    // Recent Sessions (Claude)
                    RecentSessionsView(
                        sessions: viewModel.recentSessions,
                        onSessionTap: { session in
                            viewModel.copyResumeCommand(for: session)
                            showCopiedConfirmation()
                        }
                    )
                }
                .padding(.horizontal, BurnrateTheme.spacingLG)
                .padding(.bottom, BurnrateTheme.spacingMD)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    scrollContentHeight = height
                }
            }
            .scrollIndicators(.never)
            // Fit the content; scroll only once it outgrows the screen
            .frame(height: min(scrollContentHeight, maxScrollHeight))
        }
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                CopiedToast()
                    .padding(.bottom, BurnrateTheme.spacingLG)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(\.isPopoverVisible, viewModel.isPopoverVisible)
        .onChange(of: expandedProviders) { _, newValue in
            UserDefaults.standard.set(Array(newValue), forKey: "expandedProviders")
        }
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedProviders.insert(id)
                } else {
                    expandedProviders.remove(id)
                }
            }
        )
    }

    private var maxScrollHeight: CGFloat {
        // Leave room for the menu bar, the popover arrow, and the header
        (NSScreen.main?.visibleFrame.height ?? 800) - 120
    }

    private func showCopiedConfirmation() {
        toastDismissTask?.cancel()
        withAnimation(BurnrateTheme.springSnappy) {
            showCopiedToast = true
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(BurnrateTheme.easeOut) {
                showCopiedToast = false
            }
        }
    }

    /// Provides extra inline content for specific providers
    private func extraContent(for providerId: String) -> AnyView? {
        switch providerId {
        case "claude":
            var views: [AnyView] = []

            // Active session card
            views.append(AnyView(
                CurrentSessionView(session: viewModel.currentSession)
            ))

            // Opus usage bar if active
            if let limits = viewModel.usageLimits,
               (limits.opusUtilization > 0 || limits.opusResetsAt != nil) {
                views.append(AnyView(
                    ProgressBarView(
                        value: limits.opusUtilization,
                        label: "Opus",
                        resetsAt: limits.opusResetsAt
                    )
                ))
            }

            // Fable usage bar if active
            if let limits = viewModel.usageLimits,
               (limits.fableUtilization > 0 || limits.fableResetsAt != nil) {
                views.append(AnyView(
                    ProgressBarView(
                        value: limits.fableUtilization,
                        label: "Fable",
                        resetsAt: limits.fableResetsAt
                    )
                ))
            }

            // Extra usage status
            views.append(AnyView(
                ExtraUsageView(accountInfo: viewModel.accountInfo)
            ))

            return AnyView(
                VStack(spacing: BurnrateTheme.spacingXS) {
                    ForEach(0..<views.count, id: \.self) { i in
                        views[i]
                    }
                }
            )

        default:
            return nil
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    let isLoading: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    // The bobbing flame runs only while the popover is on screen. A repeating
    // animation left running in the closed popover keeps SwiftUI rendering the
    // hidden view at full frame rate indefinitely.
    @Environment(\.isPopoverVisible) private var isPopoverVisible
    @State private var isFlameAnimating = false

    var body: some View {
        HStack(spacing: BurnrateTheme.spacingMD) {
            // Logo
            HStack(spacing: BurnrateTheme.spacingSM) {
                ZStack {
                    if let icon = BurnrateIcon.smallImage {
                        // Glow effect
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .blur(radius: 6)
                            .opacity(0.5)

                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .offset(y: isFlameAnimating ? -1.5 : 0)
                            .animation(
                                isFlameAnimating
                                    ? .easeInOut(duration: 2).repeatForever(autoreverses: true)
                                    : .easeInOut(duration: 0.3),
                                value: isFlameAnimating
                            )
                    }
                }
                .onAppear { isFlameAnimating = isPopoverVisible }
                .onDisappear { isFlameAnimating = false }
                .onChange(of: isPopoverVisible) { _, visible in
                    isFlameAnimating = visible
                }

                Text("Burnrate")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(BurnrateTheme.textPrimary)
            }

            Spacer()

            // Loading indicator
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 20, height: 20)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 0.5) : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(IconButtonStyle())

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(IconButtonStyle())

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

// MARK: - Copied Toast

struct CopiedToast: View {
    var body: some View {
        HStack(spacing: BurnrateTheme.spacingSM) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BurnrateTheme.statusGreen)

            Text("Resume command copied")
                .foregroundStyle(BurnrateTheme.textPrimary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, BurnrateTheme.spacingMD)
        .padding(.vertical, BurnrateTheme.spacingSM)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(BurnrateTheme.cardBorder, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: BurnrateTheme.spacingSM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BurnrateTheme.statusOrange)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BurnrateTheme.textSecondary)

            Spacer()
        }
        .padding(BurnrateTheme.spacingMD)
        .background(
            RoundedRectangle(cornerRadius: BurnrateTheme.radiusSM)
                .fill(BurnrateTheme.statusOrange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: BurnrateTheme.radiusSM)
                        .strokeBorder(BurnrateTheme.statusOrange.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

#if DEBUG
#Preview {
    ContentView(
        viewModel: {
            let vm = UsageViewModel()
            vm.currentSession = CurrentSession(
                sessionId: "abc123",
                slug: "Build SwiftUI app",
                projectPath: "/Users/test/project",
                startTime: Date().addingTimeInterval(-3600),
                inputTokens: 15000,
                outputTokens: 8000,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                messageCount: 12
            )
            vm.usageLimits = UsageLimits(
                fiveHourUtilization: 35,
                fiveHourResetsAt: Date().addingTimeInterval(3600),
                sevenDayUtilization: 72,
                sevenDayResetsAt: Date().addingTimeInterval(86400 * 3),
                opusUtilization: 0,
                opusResetsAt: nil
            )
            vm.codexUsageLimits = CodexUsageLimits(
                fiveHourUtilization: 25,
                fiveHourResetsAt: Date().addingTimeInterval(7200),
                weeklyUtilization: 45,
                weeklyResetsAt: Date().addingTimeInterval(86400 * 5),
                inputTokens: 10000,
                outputTokens: 5000,
                reasoningTokens: 2000
            )
            vm.providerUsages["claude"] = ProviderUsage(
                primaryUtilization: 35, primaryLabel: "5-hour",
                primaryResetsAt: Date().addingTimeInterval(3600),
                secondaryUtilization: 72, secondaryLabel: "7-day",
                secondaryResetsAt: Date().addingTimeInterval(86400 * 3),
                extraInfo: nil
            )
            vm.providerUsages["codex"] = ProviderUsage(
                primaryUtilization: 25, primaryLabel: "5-hour",
                primaryResetsAt: Date().addingTimeInterval(7200),
                secondaryUtilization: 45, secondaryLabel: "Weekly",
                secondaryResetsAt: Date().addingTimeInterval(86400 * 5),
                extraInfo: nil
            )
            vm.accountInfo = AccountInfo(hasExtraUsageEnabled: true, billingType: "pro", email: nil)
            vm.isTokenExpired = false
            return vm
        }(),
        onQuit: {},
        onShowSettings: {}
    )
}
#endif
