import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PickedPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedPhoto(data: data)
        }
    }
}

struct HomeView: View {
    @Bindable var model: TicketImportModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Turn a ticket screenshot into a calendar event. The reading stays on this iPhone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isStaticText)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose Screenshot", systemImage: "photo")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .extracting)
                .accessibilityLabel("Choose screenshot")
                .accessibilityHint("Opens your photo library so Tical can read a ticket image on this iPhone.")

                Button {
                    showingFileImporter = true
                } label: {
                    Label("Choose File", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(model.phase == .extracting)
                .accessibilityLabel("Choose file")
                .accessibilityHint("Opens Files so Tical can read a ticket image on this iPhone.")

                VStack(alignment: .leading, spacing: 8) {
                    Label("Or share a screenshot to Tical from Photos.", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text("Wallet still needs an Apple signing certificate, which this app does not create. You can review the code and add the event to Calendar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(20)
        }
        .navigationTitle("Tical")
        .overlay {
            if model.phase == .extracting {
                extractingOverlay
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await load(newItem)
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            loadFile(result)
        }
    }

    private var extractingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Reading the ticket on this iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(32)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reading the ticket on this iPhone")
        }
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func load(_ item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        do {
            guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else {
                model.notice = .message("Tical couldn't open that photo.")
                return
            }
            await model.importImageData(picked.data)
        } catch {
            model.notice = .message("Tical couldn't open that photo.")
        }
    }

    private func loadFile(_ result: Result<[URL], Error>) {
        let url: URL
        do {
            guard let picked = try result.get().first else { return }
            url = picked
        } catch {
            model.notice = .message("Tical couldn't open that file.")
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            Task { await model.importImageData(data) }
        } catch {
            model.notice = .message("Tical couldn't open that file.")
        }
    }
}
