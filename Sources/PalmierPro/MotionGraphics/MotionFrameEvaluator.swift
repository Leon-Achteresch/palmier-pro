import Foundation
import JavaScriptCore

struct MotionEvaluatedFrame: Codable, Sendable {
    var frame: Int
    var revision: Int
    var width: Int
    var height: Int
    var camera: [Double]
    var nodes: [MotionEvaluatedNode]
}

struct MotionEvaluatedNode: Codable, Sendable, Identifiable {
    struct Bounds: Codable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    var id: String
    var properties: [String: MotionValue]
    var animatedProperties: [String: MotionValue]
    var props: [String: MotionValue]
    var slots: [String: [String: MotionValue]]
    var active: Bool
    var locked: Bool
    var worldMatrix: [Double]
    var inverseParentMatrix: [Double]?
    var bounds: Bounds
}

actor MotionFrameEvaluator {
    static let shared = MotionFrameEvaluator()
    private var context: JSContext?
    private var documentKey: String?

    func inverse(_ matrix: [Double]) throws -> [Double] {
        guard matrix.count == 6, matrix.allSatisfy(\.isFinite) else { throw MotionSceneError.invalidField("invalid slot transform") }
        let context = try preparedContext()
        context.exception = nil
        let result = context.objectForKeyedSubscript("PalmierSceneEvaluation")?.objectForKeyedSubscript("inverse")?.call(withArguments: [matrix])
        try check(context)
        guard let values = result?.toArray() as? [Double], values.count == 6 else { throw MotionSceneError.invalidField("cannot move a slot inside a zero-scale transform") }
        return values
    }

    func evaluate(_ scene: MotionScene, key: String, frame: Int, formatID: String? = nil) throws -> MotionEvaluatedFrame {
        try Task.checkCancellation()
        guard (0..<scene.durationInFrames).contains(frame) else { throw MotionSceneError.invalidField("frame is outside the scene") }
        let context = try preparedContext()
        context.exception = nil
        if documentKey != key {
            _ = try scene.validated()
            var snapshot = scene
            snapshot.sounds = [:]
            snapshot.audioCues = []
            for i in snapshot.components.indices {
                snapshot.components[i].source = ""
                snapshot.components[i].stylesheet = ""
            }
            let data = try snapshot.encoded()
            context.objectForKeyedSubscript("__setMotionDocument")?.call(withArguments: [String(decoding: data, as: UTF8.self)])
            try check(context)
            documentKey = key
        }
        context.exception = nil
        let output = context.objectForKeyedSubscript("__evaluateMotionFrame")?.call(withArguments: [frame, formatID as Any? ?? NSNull()])
        try check(context)
        guard let json = output?.toString() else { throw MotionSceneError.sceneFailed("frame evaluator returned no result") }
        let result = try JSONDecoder().decode(MotionEvaluatedFrame.self, from: Data(json.utf8))
        try Task.checkCancellation()
        return result
    }

    private func preparedContext() throws -> JSContext {
        if let context { return context }
        guard let url = BundledResource.url("MotionRuntime/scene-evaluator.js"), let context = JSContext() else {
            throw MotionSceneError.runtimeMissing
        }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        context.evaluateScript("""
        let __motionDocument;
        function __setMotionDocument(json) { __motionDocument = JSON.parse(json); }
        function __evaluateMotionFrame(frame, format) { return JSON.stringify(PalmierSceneEvaluation.evaluate(__motionDocument, frame, format)); }
        """)
        try check(context)
        self.context = context
        return context
    }

    private func check(_ context: JSContext) throws {
        if let exception = context.exception { throw MotionSceneError.sceneFailed(exception.toString() ?? "frame evaluation failed") }
    }
}
