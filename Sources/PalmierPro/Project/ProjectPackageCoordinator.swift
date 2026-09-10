import AppKit

@MainActor
final class ProjectPackageCoordinator {
    weak var document: NSDocument?
    private var savesInProgress = 0
    private var activeMutations = 0
    private var nextMutationID = 0
    private var pendingMutations: [(id: Int, run: () -> Void, cancel: () -> Void)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosing = false
    private var fileMutations = 0
    private var fileAccessWaiters: [UUID: CheckedContinuation<@MainActor () -> Void, Error>] = [:]

    func saveStarted() { savesInProgress += 1 }

    func saveFinished(success: Bool) {
        guard savesInProgress > 0 else {
            assertionFailure("Unbalanced project save completion")
            return
        }
        savesInProgress -= 1
        guard savesInProgress == 0 else { return }
        if !success {
            let mutations = pendingMutations
            pendingMutations.removeAll()
            mutations.forEach { $0.cancel() }
        } else { runPendingMutations() }
        resumeIdleWaitersIfNeeded()
    }

    func beginMutation() throws {
        try Task.checkCancellation()
        guard !isClosing else { throw CancellationError() }
        activeMutations += 1
    }

    func endMutation() {
        guard activeMutations > 0 else {
            assertionFailure("Unbalanced project package mutation")
            return
        }
        activeMutations -= 1
        resumeIdleWaitersIfNeeded()
    }

    func performMutation<T: Sendable>(_ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard savesInProgress > 0 || fileMutations > 0 else { return try operation() }

        let id = nextMutationID
        nextMutationID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingMutations.append((
                    id: id,
                    run: { continuation.resume(with: Result { try operation() }) },
                    cancel: { continuation.resume(throwing: CancellationError()) }
                ))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelMutation(id: id) } }
    }

    func performFileMutation<T: Sendable>(
        validate: @escaping () throws -> Void,
        operation: @escaping @Sendable () throws -> T,
        rollback: @escaping @Sendable (T) throws -> Void,
        commit: (T) throws -> Void
    ) async throws -> T {
        try beginMutation()
        defer { endMutation() }
        try await performMutation {
            try validate()
            self.fileMutations += 1
        }
        defer { finishFileMutation() }
        let finishAccess = try await beginFileAccess()
        defer { finishAccess() }
        try Task.checkCancellation()
        try validate()
        let task = Task.detached(priority: .userInitiated, operation: operation)
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        do {
            try Task.checkCancellation()
            try commit(result)
            return result
        } catch {
            try await Task.detached(priority: .utility) { try rollback(result) }.value
            throw error
        }
    }

    private func beginFileAccess() async throws -> @MainActor () -> Void {
        try Task.checkCancellation()
        guard let document else { return {} }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fileAccessWaiters[id] = continuation
                document.performAsynchronousFileAccess { finish in
                    MainActor.assumeIsolated {
                        guard let waiter = self.fileAccessWaiters.removeValue(forKey: id) else {
                            finish()
                            return
                        }
                        waiter.resume(returning: { finish() })
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.fileAccessWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func finishFileMutation() {
        fileMutations -= 1
        guard fileMutations == 0 else { return }
        runPendingMutations()
    }

    private func runPendingMutations() {
        while savesInProgress == 0, fileMutations == 0, !pendingMutations.isEmpty {
            pendingMutations.removeFirst().run()
        }
    }

    func beginClosing() async {
        isClosing = true
        await waitUntilIdle()
    }

    func cancelClosing() { isClosing = false }

    func waitUntilIdle() async {
        guard savesInProgress > 0 || activeMutations > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func cancelMutation(id: Int) {
        guard let index = pendingMutations.firstIndex(where: { $0.id == id }) else { return }
        let mutation = pendingMutations.remove(at: index)
        mutation.cancel()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard savesInProgress == 0, activeMutations == 0 else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
