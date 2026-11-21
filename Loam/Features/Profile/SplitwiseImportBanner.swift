import SwiftUI

/// Owns the importer subscription, so each progress tick redraws only the card and not the
/// tab view underneath it.
struct SplitwiseImportOverlay: View {
    @ObservedObject private var importer = SplitwiseImporter.shared

    var body: some View {
        if importer.progress != nil || importer.finished != nil {
            SplitwiseImportBanner(importer: importer)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.default, value: importer.progress != nil)
        }
    }
}

/// Floats over the app while a Splitwise import uploads, so the person can keep using Loam,
/// and stays with the result until it is dismissed.
struct SplitwiseImportBanner: View {
    @ObservedObject var importer: SplitwiseImporter

    var body: some View {
        Group {
            if let progress = importer.progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Importing from Splitwise").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if progress.total > 0 {
                            Text("\(progress.done) of \(progress.total)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                        Text(progress.step).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if let message = importer.finished {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(message).font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Done") { importer.dismissResult() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .opacity(importer.progress != nil || importer.finished != nil ? 1 : 0)
        .allowsHitTesting(importer.finished != nil)
    }
}
