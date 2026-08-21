import Foundation

extension EditorViewModel {
    @discardableResult
    func updateDuckingSettings(
        _ settings: TimelineDuckingSettings,
        actionName: String = "Change Ducking"
    ) -> Bool {
        let normalized = settings.normalized
        let before = timeline.ducking
        guard before != normalized else { return false }
        timeline.ducking = normalized
        registerTimelineUndo(actionName) { vm in
            vm.updateDuckingSettings(before, actionName: actionName)
        }
        notifyTimelineChanged()
        return true
    }

    func setDuckingRole(_ role: DuckingRole, clipIds: [String], actionName: String = "Set Ducking Role") {
        commitClipProperties(clipIds: clipIds, actionName: actionName) { clip in
            guard clip.mediaType == .audio else { return }
            clip.duckingRole = role
        }
    }
}
