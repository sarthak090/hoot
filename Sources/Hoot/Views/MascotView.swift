import HootCore
import SwiftUI

/// Full-color Hoot with a subtle idle blink. Pure SwiftUI Canvas, no timers while hidden.
struct MascotView: View {
    var alert: Bool
    /// Keep this a multiple of 18 so every pixel lands on whole points.
    var size: CGFloat = 54

    @State private var blinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let eyes: HootEyes = blinking ? .closed : (alert ? .wide : .normal)
        Canvas { ctx, canvas in
            let cell = canvas.width / CGFloat(HootArt.size)
            for (r, row) in HootArt.grid(eyes: eyes).enumerated() {
                for (c, px) in row.enumerated() {
                    guard let rgba = HootPalette.color(for: px) else { continue }
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(alert ? "Hoot, looking alert" : "Hoot")
        // .task is cancelled when the dropdown closes, so the loop only runs while visible.
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            await blinkLoop()
        }
    }

    private func blinkLoop() async {
        while true {
            do {
                try await Task.sleep(for: .seconds(Double.random(in: 2.5...6)))
                blinking = true
                try await Task.sleep(for: .milliseconds(140))
                blinking = false
            } catch {
                blinking = false
                return
            }
        }
    }
}
