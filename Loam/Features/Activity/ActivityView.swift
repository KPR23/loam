import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var activityStore: ActivityStore
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedExpense: ExpenseRecord?
    @State private var expensePendingProposeEdit: ActivityProposeEditPresentation?
    @State private var unavailableMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if activityStore.isLoading && activityStore.events.isEmpty {
                    Section { HStack { Spacer(); ProgressView("Loading activity…"); Spacer() }.padding(.vertical, 28) }
                } else if activityStore.events.isEmpty {
                    Section { ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath", description: Text("Shared expense actions will appear here.")) }
                } else {
                    ForEach(groupedEvents) { group in
                        Section(group.title) {
                            ForEach(group.events) { event in activityRow(event) }
                            if group.events.last?.id == activityStore.events.last?.id, activityStore.canLoadMore {
                                Button("Load more") { if let id = authSession.userId { Task { await activityStore.loadMore(userId: id) } } }
                            }
                        }
                    }
                }
                if let error = activityStore.lastError {
                    Section { VStack(alignment: .leading, spacing: 8) { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await activityStore.refresh(userId: authSession.userId) } } } }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Activity")
            .task(id: authSession.userId) { await activityStore.refresh(userId: authSession.userId) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await activityStore.refresh(userId: authSession.userId) } } }
            .refreshable { await activityStore.refresh(userId: authSession.userId) }
        }
        .sheet(item: $selectedExpense) { expense in
            ExpenseDetailSheet(
                expense: expense,
                pendingActions: pendingDetailActions(for: expense)
            )
        }
        .sheet(item: $expensePendingProposeEdit) { presentation in
            ProposeEditSheet(expense: presentation.expense, myUserId: presentation.myUserId)
        }
        .alert("Expense unavailable", isPresented: Binding(get: { unavailableMessage != nil }, set: { if !$0 { unavailableMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(unavailableMessage ?? "") }
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        Button {
            guard let id = event.expenseId, let userId = authSession.userId else { unavailableMessage = "This expense is no longer available."; return }
            Task {
                let fetched = await expenseStore.fetchExpense(id: id, userId: userId)
                if let fetched { selectedExpense = fetched } else { unavailableMessage = "This expense was deleted or you no longer have access to it." }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                eventContent(event)
                    .frame(maxWidth: .infinity, alignment: .leading)
                amounts(event)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func eventContent(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.symbolName).foregroundStyle(HomeTheme.accent).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.sentence(viewerId: authSession.userId ?? event.actorId)).font(.system(.body, design: .rounded).weight(.medium)).multilineTextAlignment(.leading)
                Text(event.expenseTitle).font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
                Text(event.occurredAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func amounts(_ event: ActivityEvent) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(MoneyFormatter.string(from: Money(amountMinor: event.affectedShareMinor, currencyCode: event.currency))).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
            Text("of \(MoneyFormatter.string(from: Money(amountMinor: event.expenseTotalMinor, currencyCode: event.currency)))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func pendingDetailActions(for expense: ExpenseRecord) -> ExpenseDetailPendingActions? {
        guard let userId = authSession.userId, expense.isPendingAcceptance(for: userId) else { return nil }
        return ExpenseDetailPendingActions(
            creatorName: SplitPartnerOption.displayName(for: expense.createdBy),
            onAccept: {
                selectedExpense = nil
                Task { await expenseStore.respondToShare(expenseId: expense.id, userId: userId, action: .accept) }
            },
            onAcceptWithTrust: {
                selectedExpense = nil
                Task { await expenseStore.respondToShare(expenseId: expense.id, userId: userId, action: .acceptWithTrust) }
            },
            onReject: {
                selectedExpense = nil
                Task { await expenseStore.respondToShare(expenseId: expense.id, userId: userId, action: .reject) }
            },
            onProposeEdit: {
                selectedExpense = nil
                expensePendingProposeEdit = ActivityProposeEditPresentation(expense: expense, myUserId: userId)
            }
        )
    }

    private var groupedEvents: [ActivityDayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: activityStore.events) { event -> String in
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

private struct ActivityProposeEditPresentation: Identifiable {
    let expense: ExpenseRecord
    let myUserId: UUID
    var id: UUID { expense.id }
}
