import Foundation

extension EditorViewModel {
    @discardableResult
    func applyMotionPreset(
        _ preset: MotionPreset,
        intensity: Double,
        rampFrames: Int,
        focusX: Double? = nil,
        focusY: Double? = nil,
        staggerFrames: Int = 0,
        to clipIds: [String]
    ) -> [String: MotionApplication.Receipt] {
        var order: [String: Int] = [:]
        for (i, id) in clipIds.enumerated() {
            guard let clip = clipFor(id: id) else { return [:] }
            order[clip.id] = i
        }
        var receipts: [String: MotionApplication.Receipt] = [:]
        let actionName = "Apply Motion: \(preset.displayName)"
        undo.perform(actionName) {
            commitClipProperties(clipIds: clipIds, actionName: actionName) { clip in
                let application = MotionApplication(
                    preset: preset,
                    intensity: min(max(intensity, 0), 1),
                    rampFrames: max(rampFrames, 1),
                    focusX: focusX,
                    focusY: focusY,
                    delayFrames: staggerFrames * (order[clip.id] ?? 0)
                )
                receipts[clip.id] = application.apply(to: &clip)
            }
        }
        return receipts
    }
}
