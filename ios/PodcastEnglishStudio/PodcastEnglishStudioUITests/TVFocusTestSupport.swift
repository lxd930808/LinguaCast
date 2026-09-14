import XCTest

#if os(tvOS)
extension XCUIApplication {
    /// Navigate from the actual focused frame; a fixed down/right sequence can
    /// overshoot a target when the system chooses a different initial control.
    func moveRemoteFocus(to target: XCUIElement) -> Bool {
        for _ in 0..<24 {
            if target.hasFocus { return true }
            guard let focused = descendants(matching: .any).allElementsBoundByIndex.first(where: { $0.hasFocus }) else {
                XCUIRemote.shared.press(.down)
                continue
            }
            print("V17 remote focus: \(focused.elementType) \(focused.identifier) \(focused.label) \(focused.frame) -> \(target.identifier) \(target.frame)")
            let origin = focused.frame
            let destination = target.frame
            if focused.label == target.label,
               abs(origin.midX - destination.midX) < 1,
               abs(origin.midY - destination.midY) < 1 { return true }
            let verticalThreshold = min(origin.height, destination.height) * 0.45
            if destination.midY < origin.midY - verticalThreshold {
                XCUIRemote.shared.press(.up)
            } else if destination.midY > origin.midY + verticalThreshold {
                XCUIRemote.shared.press(.down)
            } else if destination.midX > origin.midX {
                XCUIRemote.shared.press(.right)
            } else {
                XCUIRemote.shared.press(.left)
            }
        }
        print("V17 focus failure hierarchy: \(debugDescription)")
        let screenshot = screenshot()
        let directory = URL(fileURLWithPath: "/private/tmp/LinguaCastV17", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("V17-tv-focus-failure.png"))
        return target.hasFocus
    }
}
#endif
