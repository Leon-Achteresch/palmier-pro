import Foundation
import Testing
@testable import PalmierPro

@Suite("Safe-area guides", .serialized)
@MainActor
struct SafeAreaGuidesTests {
    private static let defaultsKey = "safeAreaGuidesVisible"

    @Test func visibilityPersistsAppWideAcrossEditors() {
        let previous = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
        }

        let editor = EditorViewModel()
        editor.safeAreaGuidesVisible = true
        #expect(UserDefaults.standard.bool(forKey: Self.defaultsKey))
        #expect(EditorViewModel().safeAreaGuidesVisible)

        editor.safeAreaGuidesVisible = false
        #expect(UserDefaults.standard.bool(forKey: Self.defaultsKey) == false)
        #expect(EditorViewModel().safeAreaGuidesVisible == false)
    }

    @Test func guidesAreCentredInsetsOfTheVideoRect() {
        let video = CGRect(x: 20, y: 10, width: 1000, height: 500)
        let action = SafeAreaOverlayView.safeRect(SafeAreaOverlayView.actionSafeFraction, in: video)
        let title = SafeAreaOverlayView.safeRect(SafeAreaOverlayView.titleSafeFraction, in: video)

        #expect(action.width == 900)
        #expect(action.height == 450)
        #expect(title.width == 800)
        #expect(title.height == 400)
        #expect(action.midX == video.midX)
        #expect(action.midY == video.midY)
        #expect(title.midX == video.midX)
        #expect(title.midY == video.midY)
    }

    @Test func guidesScaleWithTheZoomedCanvas() {
        let timeline = Fixtures.timeline()
        let zoomed = PreviewHitTester.videoContentRect(in: CGSize(width: 1920, height: 1080), timeline: timeline)
        let fitted = PreviewHitTester.videoContentRect(in: CGSize(width: 960, height: 540), timeline: timeline)

        let zoomedTitle = SafeAreaOverlayView.safeRect(SafeAreaOverlayView.titleSafeFraction, in: zoomed)
        let fittedTitle = SafeAreaOverlayView.safeRect(SafeAreaOverlayView.titleSafeFraction, in: fitted)
        #expect(zoomedTitle.width == fittedTitle.width * 2)
        #expect(zoomedTitle.height == fittedTitle.height * 2)
    }
}
