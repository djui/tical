import SwiftUI

@main
struct TicalApp: App {
    @State private var model = TicketImportModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

struct RootView: View {
    @Bindable var model: TicketImportModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            HomeView(model: model)
                .navigationDestination(
                    isPresented: Binding(
                        get: { model.phase == .review },
                        set: { isPresented in
                            if !isPresented, model.phase == .review {
                                model.dismissReview()
                            }
                        }
                    )
                ) {
                    ReviewView(model: model)
                }
        }
        .task {
            await model.consumePendingImport()
        }
        .onOpenURL { url in
            guard url.scheme == TicketDefaults.urlScheme else { return }
            Task { await model.consumePendingImport() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.consumePendingImport() }
        }
        .alert(
            noticeTitle,
            isPresented: Binding(
                get: { model.notice != nil },
                set: { isPresented in
                    if !isPresented { model.notice = nil }
                }
            ),
            presenting: model.notice
        ) { notice in
            switch notice {
            case .calendarDenied:
                Button("Open Settings") { model.openSettings() }
                Button("Not now", role: .cancel) {}
            default:
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(noticeMessage(notice))
        }
    }

    private var noticeTitle: String {
        switch model.notice {
        case .calendarSaved:
            return "Added to Calendar"
        case .calendarDenied:
            return "Calendar access is off"
        default:
            return "Tical"
        }
    }

    private func noticeMessage(_ notice: TicketImportModel.Notice) -> String {
        switch notice {
        case .message(let text):
            return text
        case .calendarSaved:
            return "The event is on your default calendar. The notes include the confirmation code when there is one."
        case .calendarDenied:
            return "Tical only adds an event. It does not read your other events. You can allow write access in Settings."
        }
    }
}
