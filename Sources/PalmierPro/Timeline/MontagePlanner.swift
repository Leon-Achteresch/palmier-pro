import Foundation

/// Lays a run of shots onto a musical grid. Pure: the executor resolves media and places clips, this
/// decides only where the cuts land, so preview, tool, and UI can share one answer.
enum MontagePlanner {

    enum Energy: String, CaseIterable, Sendable {
        /// One grid step per shot — a constant beat cut.
        case flat
        /// Wide holds first, tightening to one step by the last shot.
        case build
        /// Tightens like `build`, then holds the final shot wide again as a payoff.
        case buildAndRelease
    }

    struct Shot: Equatable, Sendable {
        let index: Int
        let startFrame: Int
        let durationFrames: Int
        var endFrame: Int { startFrame + durationFrames }
    }

    struct Request: Sendable {
        let shotCount: Int
        let startFrame: Int
        /// Ascending timeline frames the cuts may land on. Must contain at least two entries.
        let gridFrames: [Int]
        let energy: Energy
        let maxHoldSteps: Int
        /// Per shot, the longest slot the source can fill; nil means unlimited (stills).
        let availableFrames: [Int?]
    }

    struct Plan: Equatable, Sendable {
        let shots: [Shot]
        /// Shot indices left out because even one grid step exceeded their source length.
        let skipped: [Int]
        /// Shot indices whose slot was reduced to fit their source.
        let shortened: [Int]
        var endFrame: Int { shots.last?.endFrame ?? 0 }
    }

    enum PlanError: Error, Equatable {
        case noShots
        case gridTooShort
        case gridEndsBeforeStart
    }

    static func plan(_ request: Request) throws -> Plan {
        guard request.shotCount > 0 else { throw PlanError.noShots }
        let grid = anchored(request.gridFrames.filter { $0 >= request.startFrame }.sorted(),
                            to: request.startFrame)
        guard grid.count >= 2 else { throw PlanError.gridTooShort }
        guard let last = grid.last, last > request.startFrame else { throw PlanError.gridEndsBeforeStart }

        let maxSteps = max(1, request.maxHoldSteps)
        var shots: [Shot] = []
        var skipped: [Int] = []
        var shortened: [Int] = []
        // Cursor is an index into the grid, so a shortened shot pulls every later cut earlier with it.
        var cursor = 0

        for shot in 0..<request.shotCount {
            let wanted = steps(for: shot, of: request.shotCount, energy: request.energy, maxSteps: maxSteps)
            let remaining = grid.count - 1 - cursor
            guard remaining >= 1 else {
                skipped.append(shot)
                continue
            }
            var steps = min(wanted, remaining)
            let start = grid[cursor]
            if let available = request.availableFrames[shot] {
                while steps > 1, grid[cursor + steps] - start > available { steps -= 1 }
                if grid[cursor + steps] - start > available {
                    skipped.append(shot)
                    continue
                }
                if steps < min(wanted, remaining) { shortened.append(shot) }
            }
            shots.append(Shot(index: shot, startFrame: start, durationFrames: grid[cursor + steps] - start))
            cursor += steps
        }

        return Plan(shots: shots, skipped: skipped, shortened: shortened)
    }

    /// Detectors rarely mark a beat at 0, so the raw grid would leave the picture starting after the
    /// bed. A first beat close enough to the start snaps onto it; a distant one gains a pickup slot,
    /// so the montage opens on `startFrame` either way and every cut still lands on a beat.
    private static func anchored(_ grid: [Int], to startFrame: Int) -> [Int] {
        guard let first = grid.first, first > startFrame else { return grid }
        let spacing = grid.count >= 2 ? grid[1] - first : first - startFrame
        if (first - startFrame) * 2 < spacing {
            return [startFrame] + grid.dropFirst()
        }
        return [startFrame] + grid
    }

    /// Grid steps a shot holds for. `build` ramps from the widest hold down to a single step.
    static func steps(for shot: Int, of count: Int, energy: Energy, maxSteps: Int) -> Int {
        switch energy {
        case .flat:
            return 1
        case .build:
            return ramped(shot: shot, of: count, maxSteps: maxSteps)
        case .buildAndRelease:
            return shot == count - 1 ? maxSteps : ramped(shot: shot, of: count, maxSteps: maxSteps)
        }
    }

    private static func ramped(shot: Int, of count: Int, maxSteps: Int) -> Int {
        guard count > 1, maxSteps > 1 else { return 1 }
        let position = Double(shot) / Double(count - 1)
        return max(1, Int((Double(maxSteps) - position * Double(maxSteps - 1)).rounded()))
    }

    /// Beat seconds in the music's own timebase, mapped onto the timeline the bed sits on.
    static func gridFrames(beatSeconds: [Double], musicStartFrame: Int, fps: Int) -> [Int] {
        guard fps > 0 else { return [] }
        var seen = Set<Int>()
        return beatSeconds
            .filter { $0.isFinite && $0 >= 0 }
            .map { musicStartFrame + Int(($0 * Double(fps)).rounded()) }
            .filter { seen.insert($0).inserted }
            .sorted()
    }
}
