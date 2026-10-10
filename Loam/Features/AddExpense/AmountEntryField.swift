import SwiftUI

/// The large, centered amount typed on the first step of adding an expense or
/// recording a repayment. A hidden field drives the keypad; the label animates.
struct AmountEntryField: View {
    @Binding var text: String
    let currencyCode: String
    var focus: FocusState<Bool>.Binding
    /// Draws the amount in red, e.g. when it exceeds what can be paid.
    var isInvalid = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(amountStyle)
                    .contentTransition(.numericText(value: displayValue))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(currencyCode)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: displayValue)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isInvalid)

            TextField("", text: sanitizedBinding)
                .keyboardType(.decimalPad)
                .focused(focus)
                .opacity(0.015)
                .accessibilityLabel("Amount")
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                focus.wrappedValue = true
            }
        )
        .sensoryFeedback(.selection, trigger: text)
    }

    private var parsedMoney: Money? {
        Money(majorString: text, currencyCode: currencyCode)
    }

    private var amountStyle: AnyShapeStyle {
        if isInvalid { return AnyShapeStyle(Color.red) }
        return parsedMoney != nil || !text.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    private var displayValue: Double {
        Double(parsedMoney?.amountMinor ?? 0) / 100.0
    }

    private var displayText: String {
        if text.isEmpty {
            return "0"
        }
        if text.hasSuffix(","), let money = Money(majorString: text) {
            return MoneyFormatter.typingAmount(from: money) + ","
        }
        if let money = parsedMoney {
            return MoneyFormatter.typingAmount(from: money)
        }
        return text
    }

    private var sanitizedBinding: Binding<String> {
        Binding(
            get: { text },
            set: { text = Money.sanitizeTypingInput($0) }
        )
    }
}
