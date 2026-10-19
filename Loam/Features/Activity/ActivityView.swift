import SwiftUI

/// An inbox: requests waiting on the viewer, then unread notifications. Read
/// events leave the tab and stay in each expense's history.
struct ActivityView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var activityStore: ActivityStore
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var pushStore: PushNotificationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedExpense: ExpenseRecord?
    @AppStorage("loam.notificationPromptDismissed") private var promptDismissed = false

    var body: some View {
        NavigationStack {
            List {
                if showsNotificationPrompt { notificationPrompt }
                if activityStore.isLoading && activityStore.events.isEmpty {
                    Section {
                        SkeletonRows(count: 4, leading: .avatar(40), showsAmount: false)
                    }
                    .listRowBackground(HomeTheme.surface)
                } else if activityStore.events.isEmpty {
                    Section { emptyState }
                    .listRowBackground(HomeTheme.surface)
                } else {
                    if !requests.isEmpty {
                        Section {
                            ForEach(requests) { event in requestRow(event) }
                        } header: {
                            sectionHeader("Waiting on you")
                        }
                        .listRowBackground(HomeTheme.surface)
                    }

                    ForEach(groupedEvents(notifications)) { group in
                        Section {
                            ForEach(group.events) { event in notificationRow(event) }
                        } header: {
                            sectionHeader(group.title)
                        }
                        .listRowBackground(HomeTheme.surface)
                    }

                    if activityStore.canLoadMore {
                        Section { loadMoreButton }
                        .listRowBackground(HomeTheme.surface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 2, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !notifications.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Requests stay; only answering or dismissing one clears it.
                        Button {
                            LoamFeedback.tap()
                            markRead(notifications)
                        } label: {
                            Text("Mark all read")
                        }
                    }
                }
            }
            .task(id: authSession.userId) { await reload() }
            .task(id: responseExpenseIds) {
                // Requests can sit outside the Expenses period; load them so they can be answered here.
                guard let userId = authSession.userId, !responseExpenseIds.isEmpty else { return }
                await expenseStore.loadDetachedExpenses(ids: responseExpenseIds, userId: userId)
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
            .refreshable {
                // Pull to refresh also picks up new requests.
                await expenseStore.refresh(userId: authSession.userId)
                await reload()
            }
        }
        .expenseActionsHost(selectedExpense: $selectedExpense)
        .onChange(of: pushStore.pendingRoute, initial: true) { _, route in
            // Unstructured, so consuming the route doesn't cancel the lookup it starts.
            if route != nil { Task { await openPendingRoute() } }
        }
        .onChange(of: waitingCount) { oldValue, newValue in
            // An answer from anywhere reads its request; drop it from the inbox.
            guard newValue < oldValue else { return }
            Task { await reload() }
        }
        .onChange(of: selectedExpense?.id) { oldValue, newValue in
            // Answers given on the detail screen read their requests; show that on return.
            guard oldValue != nil, newValue == nil else { return }
            Task { await reload() }
        }
    }

    private var loadMoreButton: some View {
        Button {
            guard let userId = authSession.userId else { return }
            Task { await activityStore.loadMore(userId: userId) }
        } label: {
            Text("Load more")
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .disabled(activityStore.isLoading)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
    }

    private var emptyState: some View {
        LoamEmptyState(
            title: "You’re all caught up",
            message: "When a friend splits an expense with you, suggests an edit, or records a repayment, it shows up here for you to review. Read items stay in each expense’s history.",
            systemImage: "tray"
        )
        .onAppear { Telemetry.capture(.emptyStateViewed(.activity)) }
    }

    // MARK: - Notifications

    private var showsNotificationPrompt: Bool {
        pushStore.permission == .notDetermined && !promptDismissed && !authSession.usesDemoMode
    }

    /// Asked here, where the value is obvious, instead of at launch.
    private var notificationPrompt: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.title3)
                        .foregroundStyle(HomeTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(HomeTheme.accent.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Get notified")
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(HomeTheme.text)
                        Text("Know when friends split an expense, reply or pay you back.")
                            .font(.subheadline)
                            .foregroundStyle(HomeTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button {
                        promptDismissed = true
                    } label: {
                        // A 28pt circle inside a 44pt tap target; the negative padding keeps the row's layout.
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(HomeTheme.secondary)
                            .frame(width: 28, height: 28)
                            .background(HomeTheme.tileEmpty, in: .circle)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                    .accessibilityLabel("Not now")
                }

                Button {
                    LoamFeedback.tap()
                    Task { await pushStore.requestPermission() }
                } label: {
                    Text("Turn on notifications")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(HomeTheme.accentFill)
                .buttonBorderShape(.capsule)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(HomeTheme.surface)
    }

    /// A tapped push lands here: refresh, then open the expense it was about.
    private func openPendingRoute() async {
        guard let userId = authSession.userId, let route = pushStore.consumeRoute(for: userId) else { return }
        await reload()
        guard let expenseId = route.expenseId else { return }
        if let fetched = await expenseStore.fetchExpense(id: expenseId, userId: userId) {
            selectedExpense = fetched
        } else {
            ToastCenter.shared.show(.warning("This expense was deleted or you no longer have access to it."))
        }
    }

    // MARK: - Rows

    private func requestRow(_ event: ActivityEvent) -> some View {
        activityRow(event, request: requestKind(for: event))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { respond(to: event, accept: true) } label: { Label("Accept", systemImage: "checkmark") }
                    .tint(.green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { respond(to: event, accept: false) } label: { Label("Decline", systemImage: "xmark") }
                    .tint(.red)
                // Leaves the request pending on Expenses; only the inbox forgets it.
                Button { markRead([event]) } label: { Label("Dismiss", systemImage: "eye.slash") }
                    .tint(Color(.systemGray))
            }
    }

    private func notificationRow(_ event: ActivityEvent) -> some View {
        activityRow(event, request: nil)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { markRead([event]) } label: { Label("Mark as read", systemImage: "checkmark.circle") }
                    .tint(HomeTheme.accentFill)
            }
    }

    @ViewBuilder
    private func activityRow(_ event: ActivityEvent, request: ActivityRequestKind?) -> some View {
        let row = ActivityRow(
            event: event,
            headline: event.headline(viewerId: authSession.userId ?? event.actorId),
            caption: subtitle(for: event, request: request),
            isRequest: request != nil
        )
        if event.kind.isRepayment {
            // Repayments have no expense to open; Balances shows the running total.
            row
        } else {
            Button {
                open(event)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the expense")
        }
    }

    private func open(_ event: ActivityEvent) {
        guard let id = event.expenseId, let userId = authSession.userId else {
            ToastCenter.shared.show(.warning("This expense is no longer available."))
            return
        }
        Task {
            if let fetched = await expenseStore.fetchExpense(id: id, userId: userId) {
                selectedExpense = fetched
            } else {
                ToastCenter.shared.show(.warning("This expense was deleted or you no longer have access to it."))
            }
        }
    }

    /// Time, plus what a request needs or a repayment's note. The expense
    /// title is already in the headline.
    private func subtitle(for event: ActivityEvent, request: ActivityRequestKind?) -> String {
        // Requests sit outside the day sections, so older ones carry their date.
        let showsDate = request != nil && !Calendar.current.isDateInToday(event.occurredAt)
        var parts: [String] = []
        if let request { parts.append(request.title) }
        if event.kind.isRepayment, event.expenseTitle != "Repayment" { parts.append(event.expenseTitle) }
        parts.append(event.occurredAt.formatted(date: showsDate ? .abbreviated : .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    // MARK: - Requests

    private var requests: [ActivityEvent] { activityStore.events.filter { requestKind(for: $0) != nil } }
    private var notifications: [ActivityEvent] { activityStore.events.filter { requestKind(for: $0) == nil } }

    /// Expenses behind others' shares and edits, which may be waiting on the viewer.
    private var responseExpenseIds: [UUID] {
        let userId = authSession.userId
        return activityStore.events
            .filter { ($0.kind == .shared || $0.kind == .edited) && $0.actorId != userId }
            .compactMap(\.expenseId)
    }

    /// Whether the viewer still has to answer this event, judged from what Expenses has loaded.
    private func requestKind(for event: ActivityEvent) -> ActivityRequestKind? {
        guard let userId = authSession.userId, event.actorId != userId, let expenseId = event.expenseId else { return nil }
        switch event.kind {
        case .shared, .edited:
            return expenseStore.knownExpense(id: expenseId)?.isPendingAcceptance(for: userId) == true ? .response : nil
        case .proposalCreated:
            return proposal(for: event, userId: userId) == nil ? nil : .review
        default:
            return nil
        }
    }

    private func proposal(for event: ActivityEvent, userId: UUID) -> ExpenseEditProposal? {
        expenseStore.incomingProposals(for: userId).first { $0.expenseId == event.expenseId && $0.proposedBy == event.actorId }
    }

    private var waitingCount: Int {
        guard let userId = authSession.userId else { return 0 }
        return expenseStore.pendingAcceptanceExpenses.count + expenseStore.incomingProposals(for: userId).count
    }

    /// The answer is a new event of the viewer's own, which reads the request.
    private func respond(to event: ActivityEvent, accept: Bool) {
        guard let userId = authSession.userId, let expenseId = event.expenseId else { return }
        Task {
            if event.kind == .proposalCreated {
                guard let proposal = proposal(for: event, userId: userId) else { return }
                await expenseStore.respondToProposal(proposalId: proposal.id, userId: userId, accept: accept)
            } else {
                await expenseStore.respondToShare(expenseId: expenseId, userId: userId, action: accept ? .accept : .reject)
            }
            await reload()
        }
    }

    private func markRead(_ events: [ActivityEvent]) {
        guard let userId = authSession.userId else { return }
        Task { await activityStore.markRead(events, userId: userId) }
    }

    private func reload() async {
        await activityStore.refresh(userId: authSession.userId)
    }

    private func groupedEvents(_ events: [ActivityEvent]) -> [ActivityDayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: events) { event -> String in
            if calendar.isDateInToday(event.occurredAt) { return "Today" }
            if calendar.isDateInYesterday(event.occurredAt) { return "Yesterday" }
            return event.occurredAt.formatted(date: .complete, time: .omitted)
        }
        return groups.map { ActivityDayGroup(title: $0.key, events: $0.value) }.sorted { lhs, rhs in
            (lhs.events.first?.occurredAt ?? .distantPast) > (rhs.events.first?.occurredAt ?? .distantPast)
        }
    }
}

private struct ActivityDayGroup: Identifiable {
    let title: String
    let events: [ActivityEvent]
    var id: String { title }
}

private enum ActivityRequestKind {
    /// A shared or edited expense the viewer hasn't accepted or declined.
    case response
    /// A suggestion to the viewer's own expense.
    case review

    var title: String {
        switch self {
        case .response: "Needs your response"
        case .review: "Review suggestion"
        }
    }
}

// MARK: - Rows

private struct ActivityRow: View {
    let event: ActivityEvent
    let headline: AttributedString
    let caption: String
    /// Requests wait on the viewer, so their caption and chevron take the accent.
    let isRequest: Bool

    var body: some View {
        HStack(spacing: 12) {
            ActivityAvatar(event: event)

            VStack(alignment: .leading, spacing: 2) {
                // Regular weight, so the bold expense title inside stands out.
                Text(headline)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HomeTheme.text)
                    .multilineTextAlignment(.leading)
                Text(caption)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(isRequest ? HomeTheme.accent : HomeTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isRequest {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HomeTheme.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The actor's avatar with a badge saying what they did.
private struct ActivityAvatar: View {
    let event: ActivityEvent

    var body: some View {
        AvatarView(userId: event.actorId, size: 40)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: event.kind.badgeSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(event.kind.tint, in: Circle())
                    .overlay(Circle().stroke(HomeTheme.surface, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            .padding(.trailing, 2)
            .accessibilityHidden(true)
    }
}

extension ActivityEventKind {
    /// One color per kind of change, so the feed reads at a glance.
    var tint: Color {
        switch self {
        case .shared: .blue
        case .accepted, .proposalAccepted, .autoAccepted: .green
        case .rejected, .proposalRejected: .red
        case .edited: .orange
        case .proposalCreated: .purple
        case .repaymentRecorded, .repaymentReceived: .teal
        case .participantRemoved, .deleted, .proposalSuperseded, .repaymentReversed: Color(.systemGray)
        }
    }

    var badgeSymbol: String {
        switch self {
        case .shared: "plus"
        case .accepted, .proposalAccepted, .autoAccepted: "checkmark"
        case .rejected, .proposalRejected: "xmark"
        case .edited: "pencil"
        case .proposalCreated: "text.bubble.fill"
        case .participantRemoved: "person.fill.xmark"
        case .deleted: "trash.fill"
        case .proposalSuperseded: "arrow.triangle.2.circlepath"
        case .repaymentRecorded, .repaymentReceived: RepaymentRecord.symbolName
        case .repaymentReversed: "arrow.uturn.backward"
        }
    }
}
