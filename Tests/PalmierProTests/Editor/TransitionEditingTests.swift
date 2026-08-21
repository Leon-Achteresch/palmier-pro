import AppKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("Transitions — editing and undo")
@MainActor
struct TransitionEditingTests {

    @MainActor
    final class Harness {
        let editor = EditorViewModel()
        let undoManager = UndoManager()

        init() {
            editor.timeline = Fixtures.timeline(tracks: [
                Fixtures.videoTrack(id: "v1", clips: [
                    Fixtures.clip(id: "a", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
                    Fixtures.clip(id: "b", start: 30, duration: 30, trimStart: 30, trimEnd: 30),
                ])
            ])
            editor.undo.attach(undoManager)
        }

        @discardableResult
        func addTransition() throws -> ResolvedTransition {
            try editor.addTransition(
                fromClipId: "a", toClipId: "b", style: .crossDissolve,
                direction: nil, durationFrames: 10, alignment: .centered
            )
        }
    }

    @Test func addingATransitionLeavesClipTimingUntouched() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        #expect(resolved.window.startFrame == 25)
        #expect(editor.timeline.tracks[0].transitions.count == 1)
        #expect(editor.timeline.tracks[0].clips[0].durationFrames == 30)
        #expect(editor.timeline.tracks[0].clips[1].startFrame == 30)
    }

    @Test func addingIsOneUndoableActionThatRestoresExactly() throws {
        let h = Harness()
        let editor = h.editor
        let before = editor.timeline
        try h.addTransition()
        #expect(editor.timeline != before)

        #expect(editor.undo.undoLatest() == "Add Transition")
        #expect(editor.timeline == before)
        #expect(editor.timeline.tracks[0].transitions.isEmpty)
    }

    @Test func arefusedRequestRegistersNoUndoStep() throws {
        let h = Harness()
        let editor = h.editor
        editor.timeline.tracks[0].clips[1].trimStartFrame = 0
        let before = editor.timeline

        #expect(throws: TransitionRefusal.self) { try h.addTransition() }
        #expect(editor.timeline == before)
        #expect(editor.undo.undoLatest() == nil)
    }

    @Test func removingANeighbourDropsTheTransitionAndUndoBringsItBack() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        let withTransition = editor.timeline

        editor.removeClips(ids: ["b"])
        #expect(editor.timeline.tracks.first?.transitions.isEmpty ?? true)

        _ = editor.undo.undoLatest()
        #expect(editor.timeline == withTransition)
        #expect(editor.timeline.tracks[0].transitions.first?.id == resolved.id)
    }

    @Test func trimmingPastTheHandleDropsTheTransitionAndUndoRestoresIt() throws {
        let h = Harness()
        let editor = h.editor
        try h.addTransition()
        let withTransition = editor.timeline

        editor.mutateClips(ids: ["b"], actionName: "Trim Clip") { clip in
            clip.trimStartFrame = 0
        }
        #expect(editor.timeline.tracks[0].transitions.isEmpty)

        _ = editor.undo.undoLatest()
        #expect(editor.timeline == withTransition)
        #expect(editor.timeline.tracks[0].transitions.count == 1)
    }

    @Test func trimmingWithinTheHandleKeepsTheTransition() throws {
        let h = Harness()
        let editor = h.editor
        try h.addTransition()
        editor.mutateClips(ids: ["b"], actionName: "Trim Clip") { clip in
            clip.trimStartFrame = 8
        }
        #expect(editor.timeline.tracks[0].transitions.count == 1)
        #expect(editor.timeline.tracks[0].resolvedTransitions.count == 1)
    }

    @Test func removingATransitionIsUndoable() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        let withTransition = editor.timeline

        #expect(editor.removeTransition(id: resolved.id)?.id == resolved.id)
        #expect(editor.timeline.tracks[0].transitions.isEmpty)

        #expect(editor.undo.undoLatest() == "Remove Transition")
        #expect(editor.timeline == withTransition)
    }

    @Test func removingAnUnknownTransitionIsANoOpWithoutUndo() throws {
        let h = Harness()
        let editor = h.editor
        try h.addTransition()
        _ = editor.undo.undoLatest()

        #expect(editor.removeTransition(id: "nope") == nil)
        #expect(editor.undo.undoLatest() == nil)
    }

    @Test func duplicatingATimelineRemapsTransitionsToTheNewClipIds() throws {
        let h = Harness()
        let editor = h.editor
        try h.addTransition()
        let sourceId = editor.activeTimelineId

        let copyId = try #require(editor.duplicateTimeline(sourceId))
        let copy = try #require(editor.timeline(for: copyId))
        let transition = try #require(copy.tracks[0].transitions.first)
        #expect(transition.fromClipId == copy.tracks[0].clips[0].id)
        #expect(transition.toClipId == copy.tracks[0].clips[1].id)
        #expect(transition.fromClipId != "a")
        #expect(copy.tracks[0].resolvedTransitions.count == 1)
    }

    @Test func deleteActsOnASelectedTransitionBeforeClips() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        editor.selectedTransitionIds = [resolved.id]
        editor.selectedClipIds = []

        editor.deleteSelectedClips()
        #expect(editor.timeline.tracks[0].transitions.isEmpty)
        #expect(editor.timeline.tracks[0].clips.count == 2)
    }

    @Test func editingDurationReResolvesTheWindowAsOneUndoableAction() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        let before = editor.timeline

        let updated = try #require(try editor.updateTransition(id: resolved.id, .init(durationFrames: 20)))
        #expect(updated.window.startFrame == 20)
        #expect(updated.window.endFrame == 40)
        #expect(editor.timeline.tracks[0].transitions.first?.durationFrames == 20)

        #expect(editor.undo.undoLatest() == "Edit Transition")
        #expect(editor.timeline == before)
    }

    @Test func pickingADirectionalStyleSuppliesADirectionAndClearingItDropsOne() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()

        try editor.updateTransition(id: resolved.id, .init(style: .wipe))
        #expect(editor.timeline.tracks[0].transitions.first?.direction == .left)

        try editor.updateTransition(id: resolved.id, .init(direction: .up))
        #expect(editor.timeline.tracks[0].transitions.first?.direction == .up)

        try editor.updateTransition(id: resolved.id, .init(style: .crossDissolve))
        #expect(editor.timeline.tracks[0].transitions.first?.direction == nil)
    }

    @Test func alignmentMovesTheWindowWithoutMovingTheCut() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()

        let updated = try #require(try editor.updateTransition(id: resolved.id, .init(alignment: .endAtCut)))
        #expect(updated.window.cutFrame == 30)
        #expect(updated.window.startFrame == 20)
        #expect(updated.window.endFrame == 30)
    }

    @Test func anEditBeyondTheAvailableHandleIsRefusedAndRegistersNoUndoStep() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        let before = editor.timeline

        #expect(throws: TransitionRefusal.self) {
            try editor.updateTransition(id: resolved.id, .init(durationFrames: 200))
        }
        #expect(editor.timeline == before)
        #expect(editor.undo.undoLatest() == "Add Transition")
    }

    @Test func anEmptyOrUnchangedEditRegistersNoUndoStep() throws {
        let h = Harness()
        let editor = h.editor
        let resolved = try h.addTransition()
        let before = editor.timeline

        #expect(try editor.updateTransition(id: resolved.id, .init()) == nil)
        #expect(try editor.updateTransition(id: resolved.id, .init(durationFrames: 10))?.id == resolved.id)
        #expect(editor.timeline == before)
        #expect(editor.undo.undoLatest() == "Add Transition")
    }

    @Test func editingAnUnknownTransitionIsRefused() throws {
        let h = Harness()
        #expect(throws: TransitionRefusal.self) {
            try h.editor.updateTransition(id: "nope", .init(durationFrames: 12))
        }
    }

    @Test func transitionsSurviveACodableRoundTrip() throws {
        let h = Harness()
        let editor = h.editor
        try h.addTransition()
        let data = try JSONEncoder().encode(editor.timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(decoded == editor.timeline)
        #expect(decoded.tracks[0].resolvedTransitions.count == 1)
    }
}
