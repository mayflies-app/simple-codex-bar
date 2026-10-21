import SwiftUI
import AppKit
import CodexUsageCore
import ServiceManagement

struct UsagePopover: View {
    let store: AccountStore
    let login: LoginController?
    let simulation: SimulationSession?
    let refreshController: RefreshController
    let loginItem: LoginItemController
    let dates: DateDisplayController
    let language: LanguageController
    let languageChanged: () -> Void
    let addLinked: () -> Void
    let linkCurrent: () -> Void
    let rename: (Account) -> Void
    let remove: (Account) -> Void
    let reauthenticate: (Account) -> Void
    var maximumHeight: CGFloat = StatusPanelWindow.maximumContentHeight
    var heightChanged: (CGFloat) -> Void = { _ in }
    @State private var contentHeight = StatusPanelWindow.minimumContentHeight
    private var busy: Bool { login?.busy == true || simulation?.busy == true }
    private var height: CGFloat {
        let maximum = max(1, min(StatusPanelWindow.maximumContentHeight, maximumHeight))
        return min(maximum, max(min(StatusPanelWindow.minimumContentHeight, maximum), ceil(contentHeight)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.50percent").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text("panel.title")).font(.headline)
                            .accessibilityIdentifier("panel-title")
                        Text(activityLabel)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("mac-activity")
                            .help(text("panel.activity.help"))
                    }
                    Spacer()
                    Button { refreshController.refreshManually() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(text("panel.refresh.help"))
                    .accessibilityLabel(text("panel.refresh.label"))
                    .accessibilityIdentifier("refresh-all")
                    .disabled(store.rows.isEmpty || store.isRefreshing || busy)
                    settingsMenu
                }.padding(16)
                Divider()
                if let error = loginItem.errorMessage {
                    Text(language.resolve(error)).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(12)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .measurePanelHeight(.header)
            ScrollView {
                // Measure every card, including those below the scroll viewport.
                VStack(spacing: 12) {
                    if store.rows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text(text("panel.empty.title")).font(.headline)
                            Text(text("panel.empty.description"))
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(.vertical, 40).padding(.horizontal, 12)
                            .accessibilityIdentifier("empty-accounts")
                    }
                    ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                        AccountCard(row: row, disabled: busy, dates: dates, language: language,
                                    canMoveUp: index > 0, canMoveDown: index < store.rows.count - 1,
                                    staleAfter: refreshController.automaticRefreshEnabled ? max(600, refreshController.refreshInterval.seconds * 2) : 600,
                                    refresh: { store.refresh(row.id) },
                                    setAutomatic: { enabled in Task { await store.setAutomaticRefreshEnabled(row.id, enabled: enabled) } },
                                    move: { offset in Task { await store.move(row.id, by: offset) } },
                                    reauthenticate: { reauthenticate(row.account) },
                                    rename: { rename(row.account) }, remove: { remove(row.account) })
                    }
                }.padding(12)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .measurePanelHeight(.accounts)
            }.scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                if let message = login?.message ?? simulation?.message {
                    HStack(alignment: .top, spacing: 10) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(language.resolve(message)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        if login?.busy == true { Button(text("panel.cancel")) { login?.cancel() }.buttonStyle(.borderless) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
                }
                if let error = store.storageMessage {
                    Text(language.resolve(error)).font(.caption).foregroundStyle(.red).padding(12)
                }
                Divider()
                HStack {
                    Menu {
                        if let simulation {
                            Button(text("panel.add.simulated")) { simulation.perform { try await simulation.addAccount() } }
                            Button(text("panel.simulate.failure")) { simulation.perform { await simulation.failNextRefresh() } }
                        } else {
                            Button(text("panel.add.login")) { login?.start() }
                            Button(text("panel.add.current")) { linkCurrent() }
                            Button(text("panel.add.file")) { addLinked() }
                        }
                    } label: { Label(text("panel.add"), systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(busy)
                    if let version = appVersion {
                        Text(text("app.version", version))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("app.version")
                    } else {
                        Spacer()
                    }
                    Button(text("panel.quit")) { NSApp.terminate(nil) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityIdentifier("quit-app")
                }.padding(14)
            }
            .fixedSize(horizontal: false, vertical: true)
            .measurePanelHeight(.footer)
        }
        .frame(width: StatusPanelWindow.contentWidth, height: height)
        .onPreferenceChange(PanelHeightPreference.self) { measurements in
            guard measurements.count == 3 else { return }
            contentHeight = measurements.values.reduce(0, +)
        }
        .onChange(of: height, initial: true) { _, height in heightChanged(height) }
        .environment(\.controlActiveState, .active)
        .environment(\.locale, language.language.locale)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle(text("panel.launch"), isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                .disabled(!loginItem.available)
                .accessibilityIdentifier("launch-at-login")
                .help(text("panel.launch.help"))
            if loginItem.requiresApproval {
                Button(text("panel.launch.approve")) { SMAppService.openSystemSettingsLoginItems() }
            } else if !loginItem.available {
                Button(text("panel.launch.packaged")) {}.disabled(true)
            }
            Divider()
            Toggle(text("panel.automatic"), isOn: Binding(get: { refreshController.automaticRefreshEnabled },
                                                        set: { refreshController.setAutomaticRefreshEnabled($0) }))
                .accessibilityIdentifier("automatic-refresh")
                .help(text("panel.automatic.help"))
            Picker(text("panel.interval"), selection: Binding(get: { refreshController.refreshInterval },
                                                            set: { refreshController.setRefreshInterval($0) })) {
                ForEach(RefreshInterval.allCases) { interval in Text(interval.title(in: language.language)).tag(interval) }
            }.pickerStyle(.menu)
                .accessibilityIdentifier("refresh-interval")
                .help(text("panel.interval.help"))
            Divider()
            Picker(text("panel.language"), selection: Binding(get: { language.language }, set: {
                language.setLanguage($0)
                languageChanged()
            })) {
                Text(text("panel.language.chinese")).tag(AppLanguage.simplifiedChinese)
                Text(text("panel.language.english")).tag(AppLanguage.english)
            }.pickerStyle(.menu)
                .accessibilityIdentifier("language-select")
                .help(text("panel.language.help"))
            Toggle(text("panel.dates.absolute"), isOn: Binding(get: { dates.absolute }, set: {
                if $0 != dates.absolute { dates.toggle() }
            })).accessibilityIdentifier("absolute-dates")
        } label: {
            Image(systemName: "gearshape").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(text("panel.settings.help"))
        .accessibilityLabel(text("panel.settings"))
        .accessibilityIdentifier("settings-menu")
    }

    private func text(_ key: String) -> String { language.text(key, table: "Panel") }
    private func text(_ key: String, _ first: String) -> String { language.text(key, first, table: "Panel") }
    private func text(_ key: String, _ first: String, _ second: String, _ third: String) -> String {
        language.text(key, first, second, third, table: "Panel")
    }

    private var appVersion: String? {
        guard let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return build.flatMap { $0.isEmpty ? nil : "\(version) (\($0))" } ?? version
    }

    private var activityLabel: String {
        let prefix = simulation != nil ? text("panel.simulated") : text(store.rows.count == 1 ? "panel.account.one" : "panel.account.count", store.rows.count.formatted(.number.locale(language.language.locale)))
        let state = text(refreshController.activity.isActive ? "panel.active" : "panel.inactive")
        if !refreshController.automaticRefreshEnabled {
            return text("panel.activity.summary", prefix, state, text("panel.manual.only"))
        }
        if refreshController.activity.isActive {
            return text("panel.activity.summary", prefix, state, text("panel.automatic"))
        }
        return text("panel.activity.summary", state, refreshController.activity.title(in: language.language), text("panel.paused"))
    }
}

private enum PanelSection: Hashable { case header, accounts, footer }

private struct PanelHeightPreference: PreferenceKey {
    static var defaultValue: [PanelSection: CGFloat] { [:] }
    static func reduce(value: inout [PanelSection: CGFloat], nextValue: () -> [PanelSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func measurePanelHeight(_ section: PanelSection) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightPreference.self, value: [section: geometry.size.height])
            }
        }
    }
}

private struct AccountCard: View {
    let row: AccountRow
    let disabled: Bool
    let dates: DateDisplayController
    let language: LanguageController
    let canMoveUp: Bool
    let canMoveDown: Bool
    let staleAfter: TimeInterval
    let refresh: () -> Void
    let setAutomatic: (Bool) -> Void
    let move: (Int) -> Void
    let reauthenticate: () -> Void
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.account.displayName(in: language.language)).font(.system(.subheadline, weight: .semibold))
                        .lineLimit(2).frame(minHeight: 24, alignment: .leading)
                    if let email = row.account.identity.email, email != row.account.displayName(in: language.language) {
                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Button(action: refresh) {
                        ZStack {
                            if row.refreshing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                        }.frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless).disabled(disabled || row.refreshing)
                    .help(text("card.refresh.help"))
                    .accessibilityLabel(text("card.refresh.label", row.account.displayName(in: language.language)))
                    .accessibilityIdentifier("refresh-account-\(row.id)")
                    Menu {
                        Button(text("card.rename"), action: rename)
                        if row.account.isManaged { Button(text("card.reauthenticate"), action: reauthenticate) }
                        Divider()
                        Button(text("card.remove"), role: .destructive, action: remove)
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(disabled)
                    .help(text(row.account.isManaged ? "card.actions.managed.help" : "card.actions.linked.help"))
                    .accessibilityLabel(text("card.actions.label", row.account.displayName(in: language.language)))
                }.font(.system(size: 14)).frame(height: 24)
            }
            HStack(spacing: 5) {
                Text(PlanPresentation.title(usage: row.snapshot?.plan, auth: row.snapshot?.authPlan))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .help(text("card.plan.help", row.snapshot?.plan ?? text("card.not.provided"), row.snapshot?.authPlan ?? text("card.not.provided")))
                    .accessibilityIdentifier("plan-\(row.id)")
                if let credits = row.snapshot?.credits {
                    Text("· \(creditLabel(credits))").monospacedDigit().fixedSize()
                        .help(text("card.credits.help"))
                        .accessibilityIdentifier("credits-\(row.id)")
                }
                Spacer(minLength: 0)
                Text(text(row.account.isManaged ? "card.managed" : "card.linked")).fixedSize()
            }.font(.system(size: 10)).foregroundStyle(.secondary)

            if let snapshot = row.snapshot {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.displayTitle(in: language.language)).font(.caption)
                                .accessibilityIdentifier("window-title-\(row.id)-\(window.id)")
                            Spacer()
                            Text(text("card.remaining.percent", number(window.remainingPercent)))
                                .font(.system(.caption, weight: .medium)).monospacedDigit()
                                .help(text("card.percentage.help", number(window.usedPercent), number(window.remainingPercent)))
                                .accessibilityIdentifier("percentage-\(row.id)-\(window.id)")
                        }
                        ProgressView(value: window.remainingPercent, total: 100)
                            .tint(window.remainingPercent <= 10 ? .red : window.remainingPercent <= 25 ? .orange : .accentColor)
                            .accessibilityLabel(text("card.remaining.label", window.displayTitle(in: language.language)))
                        if let used = window.usedAmount, let limit = window.limitAmount {
                            Text(text("card.usage", number(used), number(limit), number(max(0, limit - used))))
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                                .help(text("card.usage.help"))
                        } else if let limit = window.limitAmount {
                            Text(text("card.limit", number(limit))).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let date = window.resetsAt {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Button { dates.toggle() } label: {
                                    Text(dates.absolute ? text("time.reset.absolute", fullDate(date)) : resetLabel(date, now: context.date))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(text("time.toggle.help"))
                                .accessibilityHint(text("time.toggle.help"))
                                .accessibilityIdentifier("reset-\(row.id)-\(window.id)")
                            }
                        } else { Text(text("time.reset.unavailable")).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
            } else if row.errorMessage == nil {
                Text(text(row.refreshing ? "card.loading" : "card.unavailable"))
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if let error = row.errorMessage {
                Label(language.resolve(error), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("error-\(row.id)")
            }
            if let notice = row.snapshot?.displayNotice(in: language.language) {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notice-\(row.id)")
            }
            HStack(spacing: 6) {
                if let snapshot = row.snapshot {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let stale = row.restoredFromCache || context.date.timeIntervalSince(snapshot.fetchedAt) > staleAfter || row.errorMessage != nil
                        let dateText = dates.absolute ? fullDate(snapshot.fetchedAt) : updateLabel(snapshot.fetchedAt, now: context.date)
                        Button { dates.toggle() } label: {
                            HStack(spacing: 3) {
                                Image(systemName: stale ? "clock.badge.exclamationmark" : "checkmark.circle")
                                Text(row.restoredFromCache ? text("time.cached", dateText) : stale ? text("time.stale", dateText) : dateText)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }.foregroundStyle(stale ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(text("time.toggle.help"))
                        .accessibilityLabel(text(stale ? "time.updated.stale.label" : "time.updated.label", dateText))
                        .accessibilityHint(text("time.toggle.help"))
                        .accessibilityIdentifier("updated-\(row.id)")
                    }
                }
                Spacer(minLength: 0)
                Toggle(text("card.automatic"), isOn: Binding(get: { row.account.automaticRefreshEnabled }, set: { setAutomatic($0) }))
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .disabled(disabled)
                    .help(text("card.automatic.help"))
                    .accessibilityLabel(text("card.automatic.label", row.account.displayName(in: language.language)))
                    .accessibilityIdentifier("automatic-account-\(row.id)")
                Button { move(-1) } label: { Image(systemName: "arrow.up").frame(width: 16, height: 18) }
                    .disabled(disabled || !canMoveUp).help(text("card.move.up.help"))
                    .accessibilityLabel(text("card.move.up.label", row.account.displayName(in: language.language)))
                    .accessibilityIdentifier("move-up-\(row.id)")
                Button { move(1) } label: { Image(systemName: "arrow.down").frame(width: 16, height: 18) }
                    .disabled(disabled || !canMoveDown).help(text("card.move.down.help"))
                    .accessibilityLabel(text("card.move.down.label", row.account.displayName(in: language.language)))
                    .accessibilityIdentifier("move-down-\(row.id)")
            }.font(.system(size: 10)).buttonStyle(.borderless)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func text(_ key: String) -> String { language.text(key, table: "Panel") }
    private func text(_ key: String, _ first: String) -> String { language.text(key, first, table: "Panel") }
    private func text(_ key: String, _ first: String, _ second: String) -> String { language.text(key, first, second, table: "Panel") }
    private func text(_ key: String, _ first: String, _ second: String, _ third: String) -> String {
        language.text(key, first, second, third, table: "Panel")
    }

    private func integer(_ value: Int) -> String {
        value.formatted(.number.locale(language.language.locale))
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(language.language.locale))
    }

    private func creditLabel(_ credits: CreditBalance) -> String {
        if credits.unlimited == true { return text("card.credits.unlimited") }
        if let balance = credits.balance { return text("card.credits.balance", number(balance)) }
        if let hasCredits = credits.hasCredits { return text(hasCredits ? "card.credits.available" : "card.credits.none") }
        return text("card.credits.limited")
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.language.locale
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func updateLabel(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return text("time.updated.just.now") }
        if seconds < 3600 { return text("time.updated.minutes", integer(Int(seconds / 60))) }
        if seconds < 86400 { return text("time.updated.hours", integer(Int(seconds / 3600))) }
        return text("time.updated.days", integer(Int(seconds / 86400)))
    }

    private func resetLabel(_ date: Date, now: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return text("time.reset.pending") }
        let minutes = Int(ceil(remaining / 60))
        if minutes >= 1440 { return text("time.reset.days.hours", integer(minutes / 1440), integer((minutes % 1440) / 60)) }
        if minutes >= 60 { return text("time.reset.hours.minutes", integer(minutes / 60), integer(minutes % 60)) }
        return text("time.reset.minutes", integer(minutes))
    }
}
