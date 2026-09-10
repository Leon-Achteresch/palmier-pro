import AppKit
import Testing
import XCTest
@testable import PalmierPro

@Suite("Project autosave continuation", .serialized)
@MainActor
struct ProjectAutosaveContinuationTests {
    @Test func autosaveCompletesAndReleasesMediaMutation() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let document = VideoProject()
            document.fileURL = package.url
            document.fileType = VideoProject.typeIdentifier
            document.editorViewModel.projectURL = package.url
            let saved = XCTestExpectation(description: "initial save")
            document.save(to: package.url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { Issue.record(error) }
                saved.fulfill()
            }
            let initial = await XCTWaiter.fulfillment(of: [saved], timeout: 5)
            try #require(initial == .completed)
            document.editorViewModel.timeline.name = "Autosaved scene"
            document.updateChangeCount(.changeDone)
            let autosaved = XCTestExpectation(description: "autosave")
            document.autosave(withImplicitCancellability: false) { error in
                if let error { Issue.record(error) }
                autosaved.fulfill()
            }
            let completed = await XCTWaiter.fulfillment(of: [autosaved], timeout: 5)
            try #require(completed == .completed)
            let coordinator = document.editorViewModel.projectPackageCoordinator
            try await coordinator.performMutation {}
            let contents = try await Self.read(package.url)
            #expect(contents.projectFile.timelines.first?.name == "Autosaved scene")
            try await package.remove()
        } catch {
            try await package.remove()
            throw error
        }
    }

    @Test func saveCapturesStateAfterAdmittedFileMutationCommits() async throws {
        let package = try await MotionTestPackage.make()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        do {
            let document = VideoProject()
            document.fileURL = package.url
            document.fileType = VideoProject.typeIdentifier
            let started = XCTestExpectation(description: "file mutation started")
            let mutation = Task {
                try await document.editorViewModel.projectPackageCoordinator.performFileMutation(validate: {}) {
                    started.fulfill()
                    release.wait()
                } rollback: { _ in } commit: { _ in
                    document.editorViewModel.timeline.name = "Committed import"
                }
            }
            let admitted = await XCTWaiter.fulfillment(of: [started], timeout: 5)
            try #require(admitted == .completed)
            let saved = XCTestExpectation(description: "save after file mutation")
            document.save(to: package.url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { Issue.record(error) }
                saved.fulfill()
            }
            release.signal()
            let completed = await XCTWaiter.fulfillment(of: [saved], timeout: 5)
            try #require(completed == .completed)
            try await mutation.value
            let contents = try await Self.read(package.url)
            #expect(contents.projectFile.timelines.first?.name == "Committed import")
            try await package.remove()
        } catch {
            try await package.remove()
            throw error
        }
    }

    @Test func cancellationWhileWaitingForDocumentAccessDoesNotCommit() async throws {
        let document = VideoProject()
        let finishAccess: @MainActor () -> Void = await withCheckedContinuation { continuation in
            document.performAsynchronousFileAccess { finish in
                MainActor.assumeIsolated { continuation.resume(returning: { finish() }) }
            }
        }
        defer { finishAccess() }
        let admitted = XCTestExpectation(description: "mutation admitted")
        let cancelled = XCTestExpectation(description: "mutation cancelled")
        let mutation = Task {
            do {
                try await document.editorViewModel.projectPackageCoordinator.performFileMutation(validate: {
                    admitted.fulfill()
                }) {
                    Issue.record("cancelled operation must not run")
                } rollback: { _ in } commit: { _ in
                    Issue.record("cancelled operation must not commit")
                }
                Issue.record("expected cancellation")
            } catch is CancellationError {
            } catch { Issue.record(error) }
            cancelled.fulfill()
        }
        let started = await XCTWaiter.fulfillment(of: [admitted], timeout: 5)
        try #require(started == .completed)
        mutation.cancel()
        let completed = await XCTWaiter.fulfillment(of: [cancelled], timeout: 5)
        try #require(completed == .completed)
        await mutation.value
        await document.editorViewModel.projectPackageCoordinator.beginClosing()
    }

    @concurrent private static func read(_ url: URL) async throws -> ProjectPackageContents {
        try VideoProject.readProjectPackage(at: url)
    }
}
