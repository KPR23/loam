import SwiftUI

struct SplitExpenseSection: View {
    let totalMinor: Int
    let myUserId: UUID
    let myDisplayName: String
    let availablePartners: [SplitPartnerOption]
    let currencyCode: String
    /// Recent split partners for quick-select (must already exclude the current user).
    var recentPartners: [SplitPartnerOption] = []
    /// When false, at least one partner must stay selected (edit-split / propose-edit flows).
    var requiresPartner: Bool = false
    var onFriendConnected: ((SplitPartnerOption) -> Void)?

    @Binding var selectedPartnerUserIds: Set<UUID>
    @Binding var splitMode: SplitExpenseMode
    @Binding var paidByUserId: UUID
    @Binding var participantPercentages: [UUID: Int]
    @Binding var participantAmountTexts: [UUID: String]

    @State private var partnerSearchText = ""

    private var isSplit: Bool { !selectedPartnerUserIds.isEmpty }

    /// Current user is never selectable in the picker UI.
    private var selectablePartners: [SplitPartnerOption] {
        availablePartners.filter { $0.userId != myUserId }
    }

    private var normalizedSearch: String {
        partnerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !normalizedSearch.isEmpty }

    private var searchResults: [SplitPartnerOption] {
        selectablePartners.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var displayedRecent: [SplitPartnerOption] {
        guard !isSearching else { return [] }
        let selectableIds = Set(selectablePartners.map(\.userId))
        return recentPartners.filter { selectableIds.contains($0.userId) }
    }

    private var displayedPeople: [SplitPartnerOption] {
        if isSearching {
            return searchResults
        }
        let recentIds = Set(displayedRecent.map(\.userId))
        return selectablePartners.filter { !recentIds.contains($0.userId) }
    }

    /// Every selected person, including existing participants that are not in
    /// `availablePartners` (yet): connections load asynchronously, and a
    /// co-participant may not be connected to the person editing. Dropping
    /// them would reset the payer and the prefilled shares.
    private var selectedPartners: [SplitPartnerOption] {
        let known = selectablePartners.filter { selectedPartnerUserIds.contains($0.userId) }
        let knownIds = Set(known.map(\.userId))
        let unknown = selectedPartnerUserIds
            .filter { $0 != myUserId && !knownIds.contains($0) }
            .map { SplitPartnerOption(userId: $0, displayName: SplitPartnerOption.displayName(for: $0)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return known + unknown
    }

    private var splitParticipants: [SplitParticipantOption] {
        [SplitParticipantOption(userId: myUserId, displayName: myDisplayName)]
            + selectedPartners.map { SplitParticipantOption(userId: $0.userId, displayName: $0.displayName) }
    }

    /// Paid by may only be someone currently in the split (you + checked Split with partners).
    private var paidBySelection: Binding<UUID> {
        Binding(
            get: {
                let allowed = Set(splitParticipants.map(\.userId))
                return allowed.contains(paidByUserId) ? paidByUserId : myUserId
            },
            set: { newValue in
                let allowed = Set(splitParticipants.map(\.userId))
                let selection = allowed.contains(newValue) ? newValue : myUserId
                if selection != paidByUserId { LoamFeedback.selection() }
                paidByUserId = selection
            }
        )
    }

    private var paidByOptionsID: String {
        splitParticipants.map(\.userId.uuidString).sorted().joined(separator: ",")
    }

    var body: some View {
        Section {
            partnerSearchField
            NavigationLink {
                AddFriendView { friend in
                    selectedPartnerUserIds.insert(friend.userId)
                    onFriendConnected?(friend)
                }
            } label: {
                Label("Add friend", systemImage: "person.badge.plus")
            }
        } header: {
            Text("People")
        } footer: {
            Text("Search for people to include in this expense.")
        }

        if isSearching {
            Section {
                if searchResults.isEmpty {
                    Text("No people match “\(normalizedSearch)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(searchResults) { partner in
                        partnerRow(partner)
                    }
                }
            } header: {
                Text("Results")
            } footer: {
                peopleFooter
            }
        } else {
            if !displayedRecent.isEmpty {
                Section {
                    ForEach(displayedRecent) { partner in
                        partnerRow(partner)
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    if displayedPeople.isEmpty {
                        peopleFooter
                    }
                }
            }

            if !displayedPeople.isEmpty {
                Section {
                    ForEach(displayedPeople) { partner in
                        partnerRow(partner)
                    }
                } header: {
                    Text(displayedRecent.isEmpty ? "Split with" : "People")
                } footer: {
                    peopleFooter
                }
            } else if displayedRecent.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    Text("Split with")
                } footer: {
                    peopleFooter
                }
            }
        }

        if isSplit {
            Section("Split method") {
                // Avoid `.menu` — it often fails to present inside nested sheets
                // (e.g. Suggest changes opened from Pending expenses).
                Picker("Method", selection: $splitMode) {
                    ForEach(SplitExpenseMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Paid by", selection: paidBySelection) {
                    ForEach(splitParticipants) { participant in
                        Text(displayName(for: participant.userId)).tag(participant.userId)
                    }
                }
                .id(paidByOptionsID)
            }
            .sensoryFeedback(.selection, trigger: splitMode)
            .onAppear(perform: clampPaidByToSplitParticipants)
            .onChange(of: paidByOptionsID) { _, _ in
                clampPaidByToSplitParticipants()
                resetShareInputs()
            }
            .onChange(of: splitMode) { _, _ in
                prepareShareInputsIfNeeded()
            }
            .onChange(of: totalMinor) { _, _ in
                if splitMode == .exactAmount {
                    resetShareInputs()
                }
            }

            if !splitParticipants.isEmpty {
                Section(content: {
                    ForEach(splitParticipants) { participant in
                        shareEditor(participant)
                    }
                }, header: {
                    Text("Shares")
                }, footer: {
                    sharesFooter
                })
            }
        }
    }

    @ViewBuilder
    private func shareEditor(_ participant: SplitParticipantOption) -> some View {
        switch effectiveSplitMode {
        case .equal:
            HStack {
                Text(displayName(for: participant.userId))
                Spacer()
                if let share = computedShare(for: participant.userId) {
                    Text(formattedAmount(share.amountMinor))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        case .percentage:
            HStack {
                Text(displayName(for: participant.userId))
                Spacer()
                TextField("0", text: percentageBinding(for: participant.userId))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 72)
                Text("%")
                    .foregroundStyle(.secondary)
            }
        case .exactAmount:
            HStack {
                Text(displayName(for: participant.userId))
                Spacer()
                TextField("0,00", text: amountBinding(for: participant.userId))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 120)
                Text(currencyCode)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentageBinding(for userId: UUID) -> Binding<String> {
        Binding(
            get: { participantPercentages[userId].map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                participantPercentages[userId] = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    private func amountBinding(for userId: UUID) -> Binding<String> {
        Binding(
            get: { participantAmountTexts[userId] ?? "" },
            set: { participantAmountTexts[userId] = Money.sanitizeTypingInput($0) }
        )
    }

    @ViewBuilder
    private var peopleFooter: some View {
        if requiresPartner {
            Text("Select at least one person to share this expense with.")
        }
    }

    private var partnerSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search people", text: $partnerSearchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !partnerSearchText.isEmpty {
                Button {
                    partnerSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
    }

    private func partnerRow(_ partner: SplitPartnerOption) -> some View {
        let isSelected = selectedPartnerUserIds.contains(partner.userId)
        return Button {
            togglePartner(partner.userId)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                    .symbolRenderingMode(.hierarchical)

                AvatarView(userId: partner.userId, size: 30)

                Text(partner.displayName)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LoamPressStyle())
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(partner.displayName)
        .accessibilityHint(isSelected ? "Selected for split" : "Select to split")
    }

    private var effectiveSplitMode: SplitExpenseMode {
        splitMode
    }

    @ViewBuilder
    private var sharesFooter: some View {
        switch effectiveSplitMode {
        case .equal:
            if selectedPartnerUserIds.count == 1 {
                Text("Split 50/50 automatically.")
            } else {
                Text("Split equally among \(splitParticipants.count) people.")
            }
        case .percentage:
            if remainingPercentage == 0 {
                Text("All 100% of this expense is distributed across \(splitParticipants.count) people.")
            } else if remainingPercentage > 0 {
                Text("\(remainingPercentage)% of this expense is still unassigned. Add it to one or more shares before continuing.")
            } else {
                Text("Shares are \(-remainingPercentage)% over 100%. Reduce one or more shares before continuing.")
            }
        case .exactAmount:
            if remainingAmountMinor == 0 {
                Text("The full expense amount of \(formattedAmount(totalMinor)) is distributed across \(splitParticipants.count) people.")
            } else if remainingAmountMinor > 0 {
                Text("\(formattedAmount(remainingAmountMinor)) of this expense is still unassigned. Add it to one or more shares before continuing.")
            } else {
                Text("Shares exceed the expense total by \(formattedAmount(-remainingAmountMinor)). Reduce one or more shares before continuing.")
            }
        }
    }

    private func togglePartner(_ userId: UUID) {
        guard userId != myUserId else { return }
        if selectedPartnerUserIds.contains(userId) {
            if requiresPartner, selectedPartnerUserIds.count == 1 { return }
            selectedPartnerUserIds.remove(userId)
            clampPaidByToSplitParticipants()
        } else {
            selectedPartnerUserIds.insert(userId)
        }
    }

    private func clampPaidByToSplitParticipants() {
        let allowed = Set(splitParticipants.map(\.userId))
        if !allowed.contains(paidByUserId) {
            paidByUserId = myUserId
        }
    }

    private func displayName(for userId: UUID) -> String {
        if userId == myUserId { return "You" }
        return selectedPartners.first(where: { $0.userId == userId })?.displayName ?? "Partner"
    }

    private var participantIds: [UUID] {
        splitParticipants.map(\.userId)
    }

    private var selectedPercentages: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: participantIds.compactMap { userId in
            participantPercentages[userId].map { (userId, $0) }
        })
    }

    private var selectedAmountMinors: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: participantIds.compactMap { userId in
            guard let text = participantAmountTexts[userId],
                  let amount = Money(majorString: text)?.amountMinor else { return nil }
            return (userId, amount)
        })
    }

    private var remainingPercentage: Int {
        100 - selectedPercentages.values.reduce(0, +)
    }

    private var remainingAmountMinor: Int {
        totalMinor - selectedAmountMinors.values.reduce(0, +)
    }

    private func formattedAmount(_ amountMinor: Int) -> String {
        MoneyFormatter.string(from: Money(amountMinor: amountMinor, currencyCode: currencyCode))
    }

    private func computedShare(for userId: UUID) -> SplitCalculator.Share? {
        computedShares?.first(where: { $0.userId == userId })
    }

    private var computedShares: [SplitCalculator.Share]? {
        guard isSplit, totalMinor > 0, validationError == nil else { return nil }

        switch effectiveSplitMode {
        case .equal:
            return SplitCalculator.split(
                totalMinor: totalMinor,
                mode: .equal,
                myUserId: myUserId,
                partnerUserIds: Array(selectedPartnerUserIds),
                paidByUserId: paidByUserId
            )
        case .percentage:
            return SplitCalculator.split(
                totalMinor: totalMinor,
                mode: .percentage,
                myUserId: myUserId,
                partnerUserIds: Array(selectedPartnerUserIds),
                paidByUserId: paidByUserId,
                participantPercentages: participantPercentages
            )
        case .exactAmount:
            return SplitCalculator.split(
                totalMinor: totalMinor,
                mode: .exactAmount,
                myUserId: myUserId,
                partnerUserIds: Array(selectedPartnerUserIds),
                paidByUserId: paidByUserId,
                participantExactAmountMinors: selectedAmountMinors
            )
        }
    }

    private func prepareShareInputsIfNeeded() {
        let ids = Set(participantIds)
        participantPercentages = participantPercentages.filter { ids.contains($0.key) }
        participantAmountTexts = participantAmountTexts.filter { ids.contains($0.key) }

        switch effectiveSplitMode {
        case .equal:
            break
        case .percentage:
            // Initialize only when participant fields are missing. An entered total
            // above or below 100% is valid editing state and must not be replaced.
            if participantPercentages.count != ids.count {
                setEqualPercentages()
            }
        case .exactAmount:
            // Preserve incomplete and over-allocated values while the user edits.
            if participantAmountTexts.count != ids.count {
                setEqualAmounts()
            }
        }
    }

    private func resetShareInputs() {
        switch effectiveSplitMode {
        case .equal:
            break
        case .percentage:
            setEqualPercentages()
        case .exactAmount:
            setEqualAmounts()
        }
    }

    private func setEqualPercentages() {
        guard !participantIds.isEmpty else {
            participantPercentages = [:]
            return
        }
        let base = 100 / participantIds.count
        participantPercentages = Dictionary(uniqueKeysWithValues: participantIds.map { ($0, base) })
        let remainderRecipient = participantIds.contains(paidByUserId) ? paidByUserId : participantIds[0]
        participantPercentages[remainderRecipient, default: 0] += 100 - (base * participantIds.count)
    }

    private func setEqualAmounts() {
        guard totalMinor > 0, !participantIds.isEmpty else {
            participantAmountTexts = [:]
            return
        }
        let shares = SplitCalculator.equal(
            totalMinor: totalMinor,
            participants: participantIds,
            paidByUserId: paidByUserId
        )
        participantAmountTexts = Dictionary(uniqueKeysWithValues: shares.map {
            ($0.userId, MoneyFormatter.editableAmount(from: Money(amountMinor: $0.amountMinor, currencyCode: currencyCode)))
        })
    }

    var validationError: String? {
        Self.validationError(
            totalMinor: totalMinor,
            selectedPartnerCount: selectedPartnerUserIds.count,
            requiresPartner: requiresPartner,
            splitMode: effectiveSplitMode,
            participantUserIds: participantIds,
            participantPercentages: participantPercentages,
            participantAmountTexts: participantAmountTexts
        )
    }

    static func validationError(
        totalMinor: Int,
        selectedPartnerCount: Int,
        requiresPartner: Bool = false,
        splitMode: SplitExpenseMode,
        participantUserIds: [UUID],
        participantPercentages: [UUID: Int],
        participantAmountTexts: [UUID: String]
    ) -> String? {
        if selectedPartnerCount == 0 {
            return requiresPartner ? "Select at least one person to split with." : nil
        }
        guard totalMinor > 0 else { return "Enter a valid amount." }

        switch splitMode {
        case .equal:
            return nil
        case .percentage:
            let percentages = participantUserIds.compactMap { participantPercentages[$0] }
            guard percentages.count == participantUserIds.count,
                  percentages.allSatisfy({ $0 >= 0 }) else {
                return "Enter a percentage for every person."
            }
            guard percentages.reduce(0, +) == 100 else {
                return "Percentage shares must total 100%."
            }
            return nil
        case .exactAmount:
            let amounts = participantUserIds.compactMap { userId in
                participantAmountTexts[userId].flatMap { Money(majorString: $0)?.amountMinor }
            }
            guard amounts.count == participantUserIds.count else {
                return "Enter an amount for every person."
            }
            guard amounts.reduce(0, +) == totalMinor else {
                return "Exact shares must total the expense amount."
            }
            return nil
        }
    }
}

private struct SplitParticipantOption: Identifiable {
    let userId: UUID
    let displayName: String

    var id: UUID { userId }
}
