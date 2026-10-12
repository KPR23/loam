import SwiftUI
import UIKit

struct NotificationSettingsView: View {
    @EnvironmentObject private var pushStore: PushNotificationStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            permissionSection
            Section {
                ForEach(NotificationCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(category.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            NotificationCategoryIcon(symbolName: category.symbolName, tint: category.tint)
                        }
                    }
                    .tint(HomeTheme.accentFill)
                }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("These match what appears in your Activity tab. Your own actions never notify you.")
            }
            .disabled(pushStore.permission != .allowed || pushStore.preferencesState != .loaded)

            if pushStore.preferencesState == .failed {
                Section {
                    Text("Couldn't load your notification settings.")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await pushStore.loadPreferences() } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await pushStore.refreshPermission()
            if pushStore.preferencesState != .loaded { await pushStore.loadPreferences() }
        }
        // Coming back from iOS Settings, where the permission may have changed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await pushStore.refreshPermission() } }
        }
        .alert("Couldn't save", isPresented: Binding(get: { pushStore.lastError != nil }, set: { if !$0 { pushStore.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pushStore.lastError ?? "")
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        switch pushStore.permission {
        case .notDetermined:
            Section {
                Button("Allow notifications") { Task { await pushStore.requestPermission() } }
            } footer: {
                Text("Loam asks iOS for permission the first time. You can change it later.")
            }
        case .denied:
            Section {
                Label {
                    Text("Notifications are off for Loam")
                } icon: {
                    NotificationCategoryIcon(symbolName: "bell.slash.fill", tint: Color(.systemGray))
                }
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } footer: {
                Text("Turn on Allow Notifications in iOS Settings to hear about activity. Your choices below are kept.")
            }
        case .allowed, .unknown:
            EmptyView()
        }
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { pushStore.preferences[category] },
            set: { enabled in Task { await pushStore.setPreference(category, enabled: enabled) } }
        )
    }
}

/// A white glyph on a rounded colored tile, the way iOS Settings marks its rows.
private struct NotificationCategoryIcon: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}
