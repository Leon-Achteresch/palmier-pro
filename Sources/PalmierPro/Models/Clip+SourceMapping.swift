import Foundation

extension Clip {
    func timelineRange(sourceStartFrame: Double, sourceEndFrame: Double) -> FrameRange? {
        guard speed.isFinite, speed > 0, sourceStartFrame.isFinite, sourceEndFrame.isFinite else { return nil }
        let s0 = max(sourceStartFrame, Double(trimStartFrame))
        let s1 = min(sourceEndFrame, Double(trimStartFrame + sourceFramesConsumed))
        guard s1 > s0 else { return nil }
        let t0 = Double(startFrame) + (s0 - Double(trimStartFrame)) / speed
        let t1 = Double(startFrame) + (s1 - Double(trimStartFrame)) / speed
        guard t0.isFinite, t1.isFinite else { return nil }
        let range = FrameRange(start: Int(t0.rounded()), end: Int(t1.rounded()))
        return range.length > 0 ? range : nil
    }
}
