import HootCore

@MainActor
func hootArtTests() {
    Harness.test("grid is 18x18 in every eye state") {
        for eyes in [HootEyes.normal, .wide, .closed] {
            let grid = HootArt.grid(eyes: eyes)
            Harness.expectEqual(grid.count, HootArt.size)
            Harness.expect(grid.allSatisfy { $0.count == HootArt.size }, "row width for \(eyes)")
        }
    }
    Harness.test("grid is left-right symmetric") {
        let grid = HootArt.grid(eyes: .wide)
        Harness.expect(grid.allSatisfy { $0 == $0.reversed() }, "asymmetric row")
    }
    Harness.test("eye states differ as intended") {
        let count = { (eyes: HootEyes, px: HootPixel) in HootArt.grid(eyes: eyes).joined().filter { $0 == px }.count }
        Harness.expect(count(.normal, .eye) > 0 && count(.normal, .pupil) == 8, "normal shows both pupils")
        Harness.expect(count(.wide, .eye) > count(.normal, .eye), "wide eyes are bigger than normal")
        Harness.expectEqual(count(.wide, .pupil), count(.normal, .pupil))
        Harness.expect(count(.closed, .eye) == 0 && count(.closed, .pupil) == 0, "closed hides the eyes")
    }
    Harness.test("renders template and icon images at the requested size") {
        let template = HootRenderer.image(pixels: 36, style: .template, eyes: .wide, badge: true)
        Harness.expectEqual(template?.width, 36)
        let icon = HootRenderer.image(pixels: 1024, style: .color(tile: true), eyes: .normal)
        Harness.expectEqual(icon?.height, 1024)
        Harness.expect(HootRenderer.image(pixels: 0, style: .template, eyes: .normal) == nil, "zero size rejected")
    }
}
