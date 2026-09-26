import CoreGraphics
import Testing
@testable import Tical

struct ColorSamplerTests {
    private let green = RGBColor(red: 0.10, green: 0.62, blue: 0.33)
    private let appBlue = RGBColor(red: 0.12, green: 0.44, blue: 0.85)
    private let teal = RGBColor(red: 0.05, green: 0.52, blue: 0.55)
    private let adOrange = RGBColor(red: 1.0, green: 0.5, blue: 0.05)
    private let paperBlue = RGBColor(red: 0.10, green: 0.35, blue: 0.80)
    private let tableRed = RGBColor(red: 0.72, green: 0.16, blue: 0.12)

    private func sample(_ image: CGImage) -> RGBColor {
        let barcode = VisionTicketScanner.detectBarcode(in: image)
        return ColorSampler.passColor(from: image, barcode: barcode?.bounds)
    }

    private func isHue(_ color: RGBColor, near expected: RGBColor) -> Bool {
        let difference = abs(color.hue - expected.hue)
        return min(difference, 1 - difference) < 0.04
    }

    // MARK: - Where the color comes from

    @Test func ignoresAppBarsAroundTheTicket() {
        let color = sample(TicketScene.screenshot(header: green, appBars: appBlue))
        #expect(isHue(color, near: green), "got hue \(color.hue)")
    }

    @Test func usesAppBarsWhenTheTicketHasNoColor() {
        let color = sample(TicketScene.screenshot(header: nil, appBars: tableRed))
        #expect(isHue(color, near: tableRed), "got hue \(color.hue)")
    }

    @Test func ignoresAnAdOutsideTheTicketBox() {
        let color = sample(TicketScene.pageWithAd(header: teal, ad: adOrange))
        #expect(isHue(color, near: teal), "got hue \(color.hue)")
    }

    @Test func ignoresTheSurfaceUnderAPhotographedTicket() {
        let color = sample(TicketScene.photo(band: paperBlue, table: tableRed))
        #expect(isHue(color, near: paperBlue), "got hue \(color.hue)")
    }

    @Test func samplesFullyBrightColors() {
        let yellow = RGBColor(red: 1.0, green: 0.9, blue: 0.0)
        let color = sample(TicketScene.screenshot(header: yellow, appBars: nil))
        #expect(isHue(color, near: yellow), "got hue \(color.hue)")
        #expect(color.prefersDarkText)
    }

    @Test func fallsBackToTicalVioletWithoutColor() {
        #expect(sample(TicketScene.screenshot(header: nil, appBars: nil)) == .brand)
    }

    // MARK: - Readable text

    @Test(arguments: [
        RGBColor(red: 1.0, green: 0.9, blue: 0.0),
        RGBColor(red: 1.0, green: 0.78, blue: 0.2),
        RGBColor(red: 0.65, green: 0.9, blue: 0.2),
        RGBColor(red: 0.2, green: 0.8, blue: 0.95),
    ])
    func keepsLightColorsLightWithDarkText(_ input: RGBColor) {
        let output = ColorSampler.readable(input)
        #expect(output.prefersDarkText)
        let brightness = { (color: RGBColor) in max(color.red, color.green, color.blue) }
        #expect(brightness(output) >= brightness(input) - 0.01, "darkened to \(output)")
        #expect(isHue(output, near: input))
    }

    @Test func keepsColorsThatAlreadyWorkWithWhiteText() {
        let pink = RGBColor(red: 0.85, green: 0.16, blue: 0.33)
        let output = ColorSampler.readable(pink)
        #expect(!output.prefersDarkText)
        #expect(abs(output.red - pink.red) < 0.01 && abs(output.green - pink.green) < 0.01 && abs(output.blue - pink.blue) < 0.01)
    }

    @Test(arguments: [
        RGBColor(red: 0.85, green: 0.16, blue: 0.33),
        RGBColor(red: 1.0, green: 0.9, blue: 0.0),
        RGBColor(red: 1.0, green: 0.55, blue: 0.1),
        RGBColor(red: 0.2, green: 0.47, blue: 0.96),
        RGBColor(red: 0.10, green: 0.62, blue: 0.33),
        RGBColor(red: 0.05, green: 0.1, blue: 0.35),
        RGBColor(red: 0.5, green: 0.5, blue: 0.5),
    ])
    func sampledColorsHaveReadableText(_ input: RGBColor) {
        let output = ColorSampler.readable(input)
        #expect(output.contrast(with: output.foreground) >= 4.5)
        #expect(output.contrast(with: output.label) >= 3)
    }

    @Test(arguments: RGBColor.presets)
    func presetsHaveReadableText(_ preset: RGBColor) {
        #expect(preset.contrast(with: preset.foreground) >= 4.5)
        #expect(preset.contrast(with: preset.label) >= 3)
    }
}
