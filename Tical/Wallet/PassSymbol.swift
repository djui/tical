import CoreGraphics
import Foundation

/// The pictogram on a pass, next to the logo text and in notifications: Tical's ticket, or one
/// that says what kind of event it is. Tical draws its own, since SF Symbols can't be used in logos.
nonisolated enum PassSymbol: String, CaseIterable, Identifiable, Sendable {
    case ticket, music, film, theater, sports, museum, talk, star

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .ticket: "Ticket"
        case .music: "Music"
        case .film: "Film"
        case .theater: "Theater"
        case .sports: "Sports"
        case .museum: "Museum"
        case .talk: "Talk"
        case .star: "Star"
        }
    }

    /// Width over height.
    var aspectRatio: CGFloat { self == .ticket ? 1.6 : 1 }

    /// The size in the pass logo, in points. The square symbols are a little taller than the
    /// ticket, so they look about as large.
    var logoSize: CGSize {
        self == .ticket ? CGSize(width: 32, height: 20) : CGSize(width: 22, height: 22)
    }

    /// The symbol, as large as fits in `rect`, centered.
    func path(in rect: CGRect) -> CGPath {
        var size = rect.size
        if size.width / size.height > aspectRatio {
            size.width = size.height * aspectRatio
        } else {
            size.height = size.width / aspectRatio
        }
        let frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let unit: CGPath
        switch self {
        case .ticket: return TicketGlyph.path(in: frame, perforated: true)
        case .music: unit = Artwork.music
        case .film: unit = Artwork.film
        case .theater: unit = Artwork.theater
        case .sports: unit = Artwork.sports
        case .museum: unit = Artwork.museum
        case .talk: unit = Artwork.talk
        case .star: unit = Artwork.star
        }
        var transform = CGAffineTransform(translationX: frame.minX, y: frame.minY).scaledBy(x: frame.width, y: frame.height)
        return unit.copy(using: &transform) ?? unit
    }

    /// The symbols other than the ticket, in a unit square with y pointing down.
    private enum Artwork {
        /// Two beamed eighth notes.
        static var music: CGPath {
            let heads = CGMutablePath()
            for center in [CGPoint(x: 0.25, y: 0.79), CGPoint(x: 0.75, y: 0.69)] {
                let tilt = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.42)
                heads.addEllipse(in: CGRect(x: -0.175, y: -0.125, width: 0.35, height: 0.25), transform: tilt)
            }
            let stems = CGMutablePath()
            stems.addRect(CGRect(x: 0.34, y: 0.2, width: 0.08, height: 0.58))
            stems.addRect(CGRect(x: 0.84, y: 0.1, width: 0.08, height: 0.58))
            let beam = CGMutablePath()
            beam.addLines(between: [CGPoint(x: 0.34, y: 0.15), CGPoint(x: 0.92, y: 0.03), CGPoint(x: 0.92, y: 0.2), CGPoint(x: 0.34, y: 0.32)])
            beam.closeSubpath()
            return heads.union(stems).union(beam)
        }

        /// A clapperboard with its arm open.
        static var film: CGPath {
            let board = CGPath(roundedRect: CGRect(x: 0.05, y: 0.42, width: 0.9, height: 0.5), cornerWidth: 0.08, cornerHeight: 0.08, transform: nil)
            let boardStripes = CGMutablePath()
            for index in 0..<3 {
                let x = 0.22 + CGFloat(index) * 0.26
                boardStripes.addLines(between: [CGPoint(x: x, y: 0.42), CGPoint(x: x + 0.1, y: 0.42), CGPoint(x: x + 0.02, y: 0.56), CGPoint(x: x - 0.08, y: 0.56)])
                boardStripes.closeSubpath()
            }
            var tilt = CGAffineTransform(translationX: 0.05, y: 0.36).rotated(by: -0.2).translatedBy(x: -0.05, y: -0.36)
            let arm = CGPath(roundedRect: CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.16), cornerWidth: 0.04, cornerHeight: 0.04, transform: &tilt)
            let armStripes = CGMutablePath()
            for index in 0..<3 {
                let x = 0.2 + CGFloat(index) * 0.26
                armStripes.addLines(between: [CGPoint(x: x, y: 0.1), CGPoint(x: x + 0.1, y: 0.1), CGPoint(x: x - 0.02, y: 0.55), CGPoint(x: x - 0.12, y: 0.55)])
                armStripes.closeSubpath()
            }
            let openArm = arm.subtracting(armStripes.copy(using: &tilt) ?? armStripes)
            return board.subtracting(boardStripes).union(openArm)
        }

        /// A smiling theater mask.
        static var theater: CGPath {
            let face = CGMutablePath()
            face.move(to: CGPoint(x: 0.1, y: 0.1))
            face.addCurve(to: CGPoint(x: 0.9, y: 0.1), control1: CGPoint(x: 0.36, y: 0.2), control2: CGPoint(x: 0.64, y: 0.2))
            face.addCurve(to: CGPoint(x: 0.5, y: 0.95), control1: CGPoint(x: 0.94, y: 0.52), control2: CGPoint(x: 0.8, y: 0.88))
            face.addCurve(to: CGPoint(x: 0.1, y: 0.1), control1: CGPoint(x: 0.2, y: 0.88), control2: CGPoint(x: 0.06, y: 0.52))
            face.closeSubpath()
            let features = CGMutablePath()
            for x in [0.33, 0.67] {
                features.move(to: CGPoint(x: x - 0.12, y: 0.42))
                features.addQuadCurve(to: CGPoint(x: x + 0.12, y: 0.42), control: CGPoint(x: x, y: 0.26))
                features.addQuadCurve(to: CGPoint(x: x - 0.12, y: 0.42), control: CGPoint(x: x, y: 0.36))
                features.closeSubpath()
            }
            features.move(to: CGPoint(x: 0.27, y: 0.58))
            features.addQuadCurve(to: CGPoint(x: 0.73, y: 0.58), control: CGPoint(x: 0.5, y: 0.86))
            features.addQuadCurve(to: CGPoint(x: 0.27, y: 0.58), control: CGPoint(x: 0.5, y: 0.68))
            features.closeSubpath()
            return face.subtracting(features)
        }

        /// A ball with seams.
        static var sports: CGPath {
            let ball = CGPath(ellipseIn: CGRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94), transform: nil)
            let seams = CGMutablePath()
            seams.move(to: CGPoint(x: 0.5, y: 0))
            seams.addLine(to: CGPoint(x: 0.5, y: 1))
            seams.move(to: CGPoint(x: 0, y: 0.5))
            seams.addLine(to: CGPoint(x: 1, y: 0.5))
            // The side seams bend toward the middle: arcs around centers outside the ball.
            for (centerX, middle) in [(-0.14, 0.0), (1.14, CGFloat.pi)] {
                let center = CGPoint(x: centerX, y: 0.5)
                let start = middle - 1.15
                seams.move(to: CGPoint(x: center.x + 0.48 * cos(start), y: center.y + 0.48 * sin(start)))
                seams.addArc(center: center, radius: 0.48, startAngle: start, endAngle: middle + 1.15, clockwise: false)
            }
            return ball.subtracting(seams.copy(strokingWithWidth: 0.07, lineCap: .butt, lineJoin: .miter, miterLimit: 4))
        }

        /// A building with columns.
        static var museum: CGPath {
            let building = CGMutablePath()
            building.addLines(between: [CGPoint(x: 0.5, y: 0.04), CGPoint(x: 0.97, y: 0.3), CGPoint(x: 0.03, y: 0.3)])
            building.closeSubpath()
            building.addRect(CGRect(x: 0.08, y: 0.34, width: 0.84, height: 0.08))
            for x in [0.13, 0.34, 0.56, 0.77] {
                building.addRect(CGRect(x: x, y: 0.46, width: 0.1, height: 0.34))
            }
            building.addRect(CGRect(x: 0.03, y: 0.84, width: 0.94, height: 0.12))
            return building
        }

        /// A microphone on a stand.
        static var talk: CGPath {
            let head = CGPath(roundedRect: CGRect(x: 0.34, y: 0.03, width: 0.32, height: 0.56), cornerWidth: 0.16, cornerHeight: 0.16, transform: nil)
            let holder = CGMutablePath()
            holder.addArc(center: CGPoint(x: 0.5, y: 0.42), radius: 0.28, startAngle: .pi, endAngle: 0, clockwise: true)
            let stand = CGMutablePath()
            stand.addRect(CGRect(x: 0.46, y: 0.68, width: 0.08, height: 0.2))
            stand.addPath(CGPath(roundedRect: CGRect(x: 0.28, y: 0.86, width: 0.44, height: 0.09), cornerWidth: 0.045, cornerHeight: 0.045, transform: nil))
            return head
                .union(holder.copy(strokingWithWidth: 0.08, lineCap: .round, lineJoin: .round, miterLimit: 4))
                .union(stand)
        }

        /// A five-pointed star.
        static var star: CGPath {
            let star = CGMutablePath()
            let center = CGPoint(x: 0.5, y: 0.54)
            for index in 0..<10 {
                let radius: CGFloat = index.isMultiple(of: 2) ? 0.5 : 0.21
                let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / 5
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath()
            return star
        }
    }
}

/// Tical's ticket: a rounded rectangle with a notch in each short side.
nonisolated enum TicketGlyph {
    static func path(in rect: CGRect, perforated: Bool = false) -> CGPath {
        let corner = min(rect.width, rect.height) * 0.18
        let notch = rect.height * 0.16
        let outline = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let cutouts = CGMutablePath()
        for x in [rect.minX, rect.maxX] {
            cutouts.addEllipse(in: CGRect(x: x - notch, y: rect.midY - notch, width: notch * 2, height: notch * 2))
        }
        if perforated {
            let holes = 5
            let radius = rect.height * 0.045
            let x = rect.minX + rect.width * 0.68
            for index in 0..<holes {
                let y = rect.minY + rect.height * (CGFloat(index) + 0.5) / CGFloat(holes)
                cutouts.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return outline.subtracting(cutouts)
    }
}
