import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @AppStorage(TicketDefaults.Keys.eventDurationMinutes)
    private var eventDuration = TicketDefaults.defaultEventDurationMinutes
    @AppStorage(TicketDefaults.Keys.dateOnlyStartMinutes)
    private var dateOnlyStart = TicketDefaults.defaultDateOnlyStartMinutes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        WalletSetupView(store: model.signing)
                    } label: {
                        LabeledContent {
                            Text(walletStatus)
                        } label: {
                            Label("Wallet Passes", systemImage: "wallet.pass")
                        }
                    }
                } footer: {
                    Text("Tical signs passes on this iPhone with your Pass Type ID certificate.")
                }

                Section {
                    Picker("Length", selection: $eventDuration) {
                        ForEach([60, 90, 120, 150, 180, 240], id: \.self) { minutes in
                            Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                                .tag(minutes)
                        }
                    }
                    DatePicker("Start for Date-Only Tickets", selection: dateOnlyStartBinding, displayedComponents: .hourAndMinute)
                } header: {
                    Text("When the Ticket Doesn't Say")
                } footer: {
                    Text("Used when a ticket prints no end time, or a date without a time. You can change both on each ticket.")
                }

                Section("Privacy") {
                    Label {
                        Text("Tical reads tickets with Vision and Apple Intelligence on this iPhone. Nothing is uploaded, and Tical doesn't read your calendar.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.subheadline)
                }

                Section {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private var walletStatus: String {
        if let certificate = model.signing.certificate {
            return certificate.isExpired ? String(localized: "Expired") : String(localized: "On")
        }
        return model.signing.pendingRequest == nil ? String(localized: "Off") : String(localized: "Waiting")
    }

    private var dateOnlyStartBinding: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: dateOnlyStart / 60,
                minute: dateOnlyStart % 60,
                second: 0,
                of: .now
            ) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            dateOnlyStart = (parts.hour ?? 19) * 60 + (parts.minute ?? 0)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
