import SwiftUI

struct SplitExpenseSection: View {
    let totalMinor: Int
    let myUserId: UUID
    let myDisplayName: String
    let availablePartners: [SplitPartnerOption]

    @Binding var selectedPartnerUserIds: Set<UUID>
    @Binding var isSplit: Bool
    @Binding var splitMode: SplitExpenseMode
    @Binding var paidByUserId: UUID
    @Binding var myPercentage: Int
    @Binding var myExactAmountText: String

    private var currencyCode: String { "PLN" }

    private var selectedPartners: [SplitPartnerOption] {
        availablePartners.filter { selectedPartnerUserIds.contains($0.userId) }
    }

    private var splitParticipants: [SplitParticipantOption] {
        [SplitParticipantOption(userId: myUserId, displayName: myDisplayName)]
            + selectedPartners.map { SplitParticipantOption(userId: $0.userId, displayName: $0.displayName) }
    }

    private var supportsAdvancedSplitModes: Bool {
        selectedPartnerUserIds.count == 1
    }

    var body: some View {
        Section {
            Toggle("Split expense", isOn: $isSplit)

            if isSplit {
                ForEach(availablePartners) { partner in
                    Toggle(partner.displayName, isOn: partnerSelectionBinding(for: partner.userId))
                }
            }
        } footer: {
            if isSplit {
                if selectedPartnerUserIds.isEmpty {
                    Text("Select at least one person to split with.")
                } else {
                    Text("Only your share counts toward your monthly total.")
                }
            }
        }

        if isSplit, !selectedPartnerUserIds.isEmpty {
            Section("Split method") {
                if supportsAdvancedSplitModes {
                    Picker("Method", selection: $splitMode) {
                        ForEach(SplitExpenseMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    LabeledContent("Method", value: SplitExpenseMode.equal.displayName)
                }
            }

            Section("Paid by") {
                Picker("Paid by", selection: $paidByUserId) {
                    ForEach(splitParticipants) { participant in
                        Text(participant.displayName).tag(participant.userId)
                    }
                }
                .pickerStyle(.menu)
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
                        TextField("0.00", text: $myExactAmountText)
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

    private func partnerSelectionBinding(for userId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedPartnerUserIds.contains(userId) },
            set: { isSelected in
                if isSelected {
                    selectedPartnerUserIds.insert(userId)
                } else {
                    selectedPartnerUserIds.remove(userId)
                    if paidByUserId == userId {
                        paidByUserId = myUserId
                    }
                }
            }
        )
    }

    private func displayName(for userId: UUID) -> String {
        if userId == myUserId { return "You" }
        return selectedPartners.first(where: { $0.userId == userId })?.displayName ?? "Partner"
    }

    private var parsedExactAmount: Int? {
        Money(majorString: myExactAmountText)?.amountMinor
    }

    private var computedShares: [SplitCalculator.Share]? {
        guard isSplit, totalMinor > 0, !selectedPartnerUserIds.isEmpty else { return nil }

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
            isSplit: isSplit,
            selectedPartnerCount: selectedPartnerUserIds.count,
            splitMode: effectiveSplitMode,
            myPercentage: myPercentage,
            myExactAmountText: myExactAmountText
        )
    }

    static func validationError(
        totalMinor: Int,
        isSplit: Bool,
        selectedPartnerCount: Int,
        splitMode: SplitExpenseMode,
        myPercentage: Int,
        myExactAmountText: String
    ) -> String? {
        guard isSplit else { return nil }
        guard totalMinor > 0 else { return "Enter a valid amount." }
        guard selectedPartnerCount > 0 else { return "Select at least one person to split with." }

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
}

private struct SplitParticipantOption: Identifiable {
    let userId: UUID
    let displayName: String

    var id: UUID { userId }
}
