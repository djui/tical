import SwiftUI

/// The ticket image as Tical read it, with the code it found outlined.
struct OriginalImageView: View {
    let image: UIImage?
    /// Normalized, top-left origin.
    let highlight: CGRect?

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .overlay { outline }
                            .frame(
                                width: proxy.size.width * scale * pinch,
                                height: proxy.size.height * scale * pinch
                            )
                            .accessibilityLabel("Original ticket image")
                    }
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.center)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in scale = min(max(scale * value.magnification, 1), 5) }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.smooth) { scale = scale > 1 ? 1 : 2.5 }
                }
            }
            .background(.black)
            .navigationTitle("Original")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var outline: some View {
        if let highlight {
            GeometryReader { proxy in
                let rect = CGRect(
                    x: highlight.minX * proxy.size.width,
                    y: highlight.minY * proxy.size.height,
                    width: highlight.width * proxy.size.width,
                    height: highlight.height * proxy.size.height
                ).insetBy(dx: -6, dy: -6)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityHidden(true)
            }
        }
    }
}
