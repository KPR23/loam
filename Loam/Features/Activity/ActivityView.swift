import SwiftUI

/// An inbox: requests waiting on the viewer, then unread notifications. Read
/// events leave the tab and stay in each expense's history.
struct ActivityView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var activityStore: ActivityStore
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedExpense: ExpenseRecord?
    @State private var unavailableMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if activityStore.isLoading && activityStore.events.isEmpty {
                    Section { HStack { Spacer(); ProgressView("Loading activity…"); Spacer() }.padding(.vertical, 28) }
                } else if activityStore.events.isEmpty {
                    Section {
                        ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle",
                                               description: Text("New activity on shared expenses shows up here. Read items stay in each expense's history."))
                    }
                } else {
                    if !requests.isEmpty {
                        Section("Waiting on you") {
                            ForEach(requests) { event in requestRow(event) }
                        }
                    }
                    ForEach(groupedEvents(notifications)) { group in
                        Section(group.title) {
                            ForEach(group.events) { event in notificationRow(event) }
                        }
                    }
                    if activityStore.canLoadMore {
                        Section {
                            Button("Load more") { if let id = authSession.userId { Task { await activityStore.loadMore(userId: id) } } }
                        }
                    }
                }
                if let error = activityStore.lastError {
                    Section { VStack(alignment: .leading, spacing: 8) { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await reload() } } } }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Activity")
            .toolbar {
                if !notifications.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Requests stay; only answering or dismissing one clears it.
                        Button("Mark all read") { markRead(notifications) }
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
        .alert("Expense unavailable", isPresented: Binding(get: { unavailableMessage != nil }, set: { if !$0 { unavailableMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(unavailableMessage ?? "") }
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
                    .tint(HomeTheme.accent)
            }
    }

    @ViewBuilder
    private func activityRow(_ event: ActivityEvent, request: ActivityRequestKind?) -> some View {
        if event.kind.isRepayment {
            // Repayments have no expense to open; Balances shows the running total.
            activityRowContent(event, request: request)
                .accessibilityElement(children: .combine)
        } else {
            Button {
                guard let id = event.expenseId, let userId = authSession.userId else { unavailableMessage = "This expense is no longer available."; return }
                Task {
                    let fetched = await expenseStore.fetchExpense(id: id, userId: userId)
                    if let fetched { selectedExpense = fetched } else { unavailableMessage = "This expense was deleted or you no longer have access to it." }
                }
            } label: {
                activityRowContent(event, request: request)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
    }

    private func activityRowContent(_ event: ActivityEvent, request: ActivityRequestKind?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ActivityAvatar(event: event)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.headline(viewerId: authSession.userId ?? event.actorId))
                        .font(.system(.body, design: .rounded))
                        .multilineTextAlignment(.leading)
                    Text(subtitle(for: event, request: request))
                        .font(.caption)
                        .foregroundStyle(request == nil ? Color.secondary : HomeTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if request != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HomeTheme.accent)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
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

/// The actor's avatar with a badge saying what they did.
private struct ActivityAvatar: View {
    let event: ActivityEvent

    var body: some View {
        AvatarView(userId: event.actorId, size: 34)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: event.kind.badgeSymbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
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
        case .repaymentRecorded: .teal
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
        case .repaymentRecorded: "banknote.fill"
        case .repaymentReversed: "arrow.uturn.backward"
        }
    }
}
