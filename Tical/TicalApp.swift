import SwiftUI

@main
struct TicalApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            HomeView(model: model)
                .navigationDestination(item: $model.activeImport) { ticket in
                    ReviewView(ticket: ticket, model: model)
                }
        }
        .onOpenURL { url in
            if url.isFileURL {
                model.open(fileAt: url)
            } else if url.scheme == TicketDefaults.urlScheme {
                model.openInbox()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.openInbox()
                model.signing.reload()
            }
        }
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
            presenting: model.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }
}
