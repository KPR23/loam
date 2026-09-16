import SwiftUI

struct SplitExpenseSection: View {
    let totalMinor: Int
    let myUserId: UUID
    let myDisplayName: String
    let availablePartners: [SplitPartnerOption]
    /// Recent split partners for quick-select (must already exclude the current user).
    var recentPartners: [SplitPartnerOption] = []
    /// When false, at least one partner must stay selected (edit-split / propose-edit flows).
    var requiresPartner: Bool = false

    @Binding var selectedPartnerUserIds: Set<UUID>
    @Binding var splitMode: SplitExpenseMode
    @Binding var paidByUserId: UUID
    @Binding var myPercentage: Int
    @Binding var myExactAmountText: String

    @State private var partnerSearchText = ""

    private var currencyCode: String { "PLN" }

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

    private var selectedPartners: [SplitPartnerOption] {
        selectablePartners.filter { selectedPartnerUserIds.contains($0.userId) }
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
                paidByUserId = allowed.contains(newValue) ? newValue : myUserId
            }
        )
    }

    private var paidByOptionsID: String {
        splitParticipants.map(\.userId.uuidString).sorted().joined(separator: ",")
    }

    private var supportsAdvancedSplitModes: Bool {
        selectedPartnerUserIds.count == 1
    }

    var body: some View {
        Section {
            partnerSearchField
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
                if supportsAdvancedSplitModes {
                    // Avoid `.menu` — it often fails to present inside nested sheets
                    // (e.g. Suggest changes opened from Pending expenses).
                    Picker("Method", selection: $splitMode) {
                        ForEach(SplitExpenseMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } else {
                    LabeledContent("Method", value: SplitExpenseMode.equal.displayName)
                }
            }

            Section("Paid by") {
                Picker("Paid by", selection: paidBySelection) {
                    ForEach(splitParticipants) { participant in
                        Text(participant.displayName).tag(participant.userId)
                    }
                }
                .id(paidByOptionsID)
            }
            .onAppear(perform: clampPaidByToSplitParticipants)
            .onChange(of: paidByOptionsID) { _, _ in
                clampPaidByToSplitParticipants()
            }

            switch effectiveSplitMode {
            case .equal:
                equalSplitPreview
            case .percentage:
                percentageSplitControls
            case .exactAmount:
                exactAmountControls
            }

            if let shares = computedShares, !shares.isEmpty {
                Section("Shares") {
                    ForEach(shares, id: \.userId) { share in
                        LabeledContent(displayName(for: share.userId)) {
                            Text(MoneyFormatter.string(from: Money(amountMinor: share.amountMinor, currencyCode: currencyCode)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var peopleFooter: some View {
        if requiresPartner {
            Text("Select at least one person to share this expense with.")
        } else if selectedPartnerUserIds.isEmpty {
            Text("Leave empty for a personal expense.")
        } else {
            Text("Only your share counts toward your monthly total.")
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

                Text(partner.displayName)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(partner.displayName)
        .accessibilityHint(isSelected ? "Selected for split" : "Select to split")
    }

    private var effectiveSplitMode: SplitExpenseMode {
        supportsAdvancedSplitModes ? splitMode : .equal
    }

    private var equalSplitPreview: some View {
        Section {
            if selectedPartnerUserIds.count == 1 {
                Text("Split 50/50 automatically.")
            } else {
                Text("Split equally among \(splitParticipants.count) people.")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var percentageSplitControls: some View {
        Group {
            if let partner = selectedPartners.first {
                Section {
                    Stepper(value: $myPercentage, in: 1...99, step: 1) {
                        HStack {
                            Text("Your share")
                            Spacer()
                            Text("\(myPercentage)%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("\(partner.displayName)'s share") {
                        Text("\(100 - myPercentage)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var exactAmountControls: some View {
        Group {
            if let partner = selectedPartners.first {
                Section {
                    HStack {
                        Text("Your share")
                        Spacer()
                        TextField("0,00", text: sanitizedExactAmountBinding)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(maxWidth: 120)
                        Text("PLN")
                            .foregroundStyle(.secondary)
                    }

                    if let mine = parsedExactAmount {
                        LabeledContent(partner.displayName) {
                            Text(MoneyFormatter.string(from: Money(amountMinor: max(0, totalMinor - mine), currencyCode: currencyCode)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Your amount plus \(partner.displayName)'s share must equal the total.")
                }
            }
        }
    }

    private var sanitizedExactAmountBinding: Binding<String> {
        Binding(
            get: { myExactAmountText },
            set: { myExactAmountText = Money.sanitizeTypingInput($0) }
        )
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

    private var parsedExactAmount: Int? {
        Money(majorString: myExactAmountText)?.amountMinor
    }

    private var computedShares: [SplitCalculator.Share]? {
        guard isSplit, totalMinor > 0 else { return nil }

        switch effectiveSplitMode {
        case .equal, .percentage:
            return SplitCalculator.split(
                totalMinor: totalMinor,
                mode: effectiveSplitMode,
                myUserId: myUserId,
                partnerUserIds: Array(selectedPartnerUserIds),
                paidByUserId: paidByUserId,
                myPercentage: myPercentage
            )
        case .exactAmount:
            guard let mine = parsedExactAmount, mine >= 0, mine <= totalMinor else { return nil }
            return SplitCalculator.split(
                totalMinor: totalMinor,
                mode: .exactAmount,
                myUserId: myUserId,
                partnerUserIds: Array(selectedPartnerUserIds),
                paidByUserId: paidByUserId,
                myExactAmountMinor: mine
            )
        }
    }

    var validationError: String? {
        Self.validationError(
            totalMinor: totalMinor,
            selectedPartnerCount: selectedPartnerUserIds.count,
            requiresPartner: requiresPartner,
            splitMode: effectiveSplitMode,
            myPercentage: myPercentage,
            myExactAmountText: myExactAmountText
        )
    }

    static func validationError(
        totalMinor: Int,
        selectedPartnerCount: Int,
        requiresPartner: Bool = false,
        splitMode: SplitExpenseMode,
        myPercentage: Int,
        myExactAmountText: String
    ) -> String? {
        if selectedPartnerCount == 0 {
            return requiresPartner ? "Select at least one person to split with." : nil
        }
        guard totalMinor > 0 else { return "Enter a valid amount." }

        switch splitMode {
        case .equal, .percentage:
            return nil
        case .exactAmount:
            guard selectedPartnerCount == 1 else { return nil }
            guard let mine = Money(majorString: myExactAmountText)?.amountMinor else {
                return "Enter your share amount."
            }
            if mine < 0 || mine > totalMinor {
                return "Your share must be between 0 and the total."
            }
            return nil
        }
    }

    /// Compatibility wrapper for call sites that still pass `isSplit`.
    static func validationError(
        totalMinor: Int,
        isSplit: Bool,
        selectedPartnerCount: Int,
        splitMode: SplitExpenseMode,
        myPercentage: Int,
        myExactAmountText: String
    ) -> String? {
        guard isSplit else { return nil }
        return validationError(
            totalMinor: totalMinor,
            selectedPartnerCount: selectedPartnerCount,
            requiresPartner: true,
            splitMode: splitMode,
            myPercentage: myPercentage,
            myExactAmountText: myExactAmountText
        )
    }
}

private struct SplitParticipantOption: Identifiable {
    let userId: UUID
    let displayName: String

    var id: UUID { userId }
}
