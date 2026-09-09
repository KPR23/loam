import SwiftUI

struct SplitExpenseSection: View {
    let totalMinor: Int
    let myUserId: UUID
    let myDisplayName: String
    let partnerUserId: UUID
    let partnerDisplayName: String

    @Binding var isSplit: Bool
    @Binding var splitMode: SplitExpenseMode
    @Binding var paidByUserId: UUID
    @Binding var myPercentage: Int
    @Binding var myExactAmountText: String

    private var currencyCode: String { "PLN" }

    var body: some View {
        Section {
            Toggle("Split with \(partnerDisplayName)", isOn: $isSplit)
        } footer: {
            if isSplit {
                Text("Only your share counts toward your monthly total.")
            }
        }

        if isSplit {
            Section("Split method") {
                Picker("Method", selection: $splitMode) {
                    ForEach(SplitExpenseMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Paid by") {
                Picker("Paid by", selection: $paidByUserId) {
                    Text(myDisplayName).tag(myUserId)
                    Text(partnerDisplayName).tag(partnerUserId)
                }
                .pickerStyle(.segmented)
            }

            switch splitMode {
            case .equal:
                equalSplitPreview
            case .percentage:
                percentageSplitControls
            case .exactAmount:
                exactAmountControls
            }

            if let preview = computedShares {
                Section("Your share") {
                    LabeledContent("You") {
                        Text(MoneyFormatter.string(from: Money(amountMinor: preview.myShare, currencyCode: currencyCode)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(partnerDisplayName) {
                        Text(MoneyFormatter.string(from: Money(amountMinor: preview.partnerShare, currencyCode: currencyCode)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var equalSplitPreview: some View {
        Section {
            Text("Split 50/50 automatically.")
                .foregroundStyle(.secondary)
        }
    }

    private var percentageSplitControls: some View {
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

            LabeledContent("\(partnerDisplayName)'s share") {
                Text("\(100 - myPercentage)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exactAmountControls: some View {
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
                LabeledContent(partnerDisplayName) {
                    Text(MoneyFormatter.string(from: Money(amountMinor: max(0, totalMinor - mine), currencyCode: currencyCode)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Your amount plus \(partnerDisplayName)'s share must equal the total.")
        }
    }

    private var parsedExactAmount: Int? {
        Money(majorString: myExactAmountText)?.amountMinor
    }

    private var computedShares: (myShare: Int, partnerShare: Int)? {
        guard isSplit, totalMinor > 0 else { return nil }

        let shares: [SplitCalculator.Share]
        switch splitMode {
        case .equal:
            shares = SplitCalculator.equal(
                totalMinor: totalMinor,
                participants: [myUserId, partnerUserId],
                paidByUserId: paidByUserId
            )
        case .percentage:
            shares = SplitCalculator.percentage(
                totalMinor: totalMinor,
                userPercentages: [
                    (myUserId, myPercentage),
                    (partnerUserId, 100 - myPercentage),
                ],
                paidByUserId: paidByUserId
            )
        case .exactAmount:
            guard let mine = parsedExactAmount, mine >= 0, mine <= totalMinor else { return nil }
            shares = SplitCalculator.twoPersonSplit(
                totalMinor: totalMinor,
                mode: .exactAmount,
                myUserId: myUserId,
                partnerUserId: partnerUserId,
                paidByUserId: paidByUserId,
                myExactAmountMinor: mine
            )
        }

        let myShare = shares.first(where: { $0.userId == myUserId })?.amountMinor ?? 0
        let partnerShare = shares.first(where: { $0.userId == partnerUserId })?.amountMinor ?? 0
        return (myShare, partnerShare)
    }

    var validationError: String? {
        Self.validationError(
            totalMinor: totalMinor,
            splitMode: splitMode,
            myPercentage: myPercentage,
            myExactAmountText: myExactAmountText
        )
    }

    static func validationError(
        totalMinor: Int,
        splitMode: SplitExpenseMode,
        myPercentage: Int,
        myExactAmountText: String
    ) -> String? {
        guard totalMinor > 0 else { return "Enter a valid amount." }

        switch splitMode {
        case .equal, .percentage:
            return nil
        case .exactAmount:
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
