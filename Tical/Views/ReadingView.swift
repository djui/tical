import SwiftUI

/// Shown while Tical reads the ticket: the image with a scan sweep, and the steps so far.
struct ReadingView: View {
    let image: UIImage?
    let step: TicketImport.ReadingStep

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                preview
                    .frame(maxWidth: 420)
                steps
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(step.title))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var preview: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scanning()
            } else {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.quaternary)
                    .aspectRatio(0.62, contentMode: .fit)
                    .scanning()
            }
        }
        .frame(maxHeight: 420)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        .accessibilityHidden(true)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(TicketImport.ReadingStep.allCases, id: \.self) { item in
                HStack(spacing: 14) {
                    ZStack {
                        if item < step {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                                .transition(.scale.combined(with: .opacity))
                        } else if item == step {
                            ProgressView()
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .font(.title3)
                    .frame(width: 28, height: 28)

                    Text(item.title)
                        .font(.body.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(item <= step ? .primary : .secondary)
                }
            }
        }
        .animation(.smooth, value: step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 24))
        .frame(maxWidth: 420)
    }
}

private extension View {
    /// Rounds the view and sweeps a band of light down it.
    func scanning() -> some View {
        overlay { ScanSweep() }
            .clipShape(.rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
    }
}

/// A soft band of light that sweeps down the ticket.
private struct ScanSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                let period = 2.2
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let eased = 0.5 - cos(phase * .pi * 2) / 2
                let band = proxy.size.height * 0.28
                LinearGradient(
                    colors: [.clear, Color.accentColor.opacity(0.35), .white.opacity(0.6), Color.accentColor.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: band)
                .offset(y: -band + (proxy.size.height + band) * eased)
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}
