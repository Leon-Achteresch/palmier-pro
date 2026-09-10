import Foundation
import Testing
@testable import PalmierPro

@Suite("Motion component import")
struct MotionComponentImportTests {
    @Test @MainActor func invalidAndCancelledSceneAttachmentsDoNotRegisterMedia() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let editor = EditorViewModel()
            editor.projectURL = package.url
            let url = package.url.appendingPathComponent("invalid.motion")
            try await Self.write("{\"version\":1}", to: url)
            #expect(await editor.addMediaAsset(from: url, finalize: false) == nil)
            #expect(editor.mediaPanelToast != nil)
            editor.dismissMediaPanelToast()
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return await editor.addMediaAsset(from: url, finalize: false)
            }
            #expect(await cancelled.value == nil)
            #expect(editor.mediaPanelToast == nil)
            #expect(editor.mediaAssetsById.isEmpty)
            try await package.remove()
        } catch { try await package.remove(); throw error }
    }

    @Test func infersTypedControlsAndLiteralDefaults() async throws {
        let result = try await MotionComponentAnalyzer.shared.analyze(source: """
            type Props = {price: number; label: string; selected: boolean; size: 'small' | 'large'; onClick: () => void};
            export default function Card({price = 19, label = 'Buy', selected = false, size = 'small'}: Props) { return <div>{label}</div> }
            """, filename: "Card.tsx", exportName: "default")
        #expect(result.exports == ["default"])
        #expect(result.props.map(\.id) == ["price", "label", "selected", "size"])
        #expect(result.props[0].defaultValue == .number(19))
        #expect(result.props[2].kind == .boolean)
        #expect(result.props[3].choices == ["small", "large"])
    }

    @Test func storyArgsBecomeControlledFixtureStates() async throws {
        let result = try await MotionComponentAnalyzer.shared.analyze(source: """
            import {Card} from './Card';
            const meta = {component: Card, args: {label: 'Buy', selected: false}, argTypes: {label: {options: ['Buy', 'Upgrade']}}};
            export default meta;
            export const Basic = {args: {selected: true}};
            export const Pro = {args: {label: 'Upgrade'}};
            """, filename: "Card.stories.tsx", exportName: "Basic")
        #expect(result.isStory)
        #expect(result.fixtures["Basic"]?["selected"] == .bool(true))
        #expect(result.fixtures["Pro"]?["label"] == .string("Upgrade"))
        #expect(result.props.first { $0.id == "label" }?.kind == .choice)
    }

    @Test func reportsUncontrolledFrameEffects() async throws {
        let result = try await MotionComponentAnalyzer.shared.analyze(source: """
            export default function Card() { setTimeout(() => {}, 100); return null }
            """, filename: "Card.tsx", exportName: "default")
        #expect(result.diagnostics == ["setTimeout requires a frame-driven adapter"])
    }

    @Test func bundlesActualSourceCSSFontsAndImagesWithoutSourceCheckout() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let entry = try await Self.fixture(in: package.url)
            let result = try await MotionComponentCompiler.shared.compile(at: entry)
            #expect(result.component.source.contains("Actual product card"))
            #expect(result.component.source.contains("data:image/svg+xml"))
            #expect(result.component.stylesheet.contains("#123456"))
            #expect(result.component.stylesheet.contains("base64,"))
            #expect(result.component.props.first?.id == "price")
            var scene = MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 30)
            scene.components = [result.component]
            let encoded = try scene.encoded()
            try await package.remove()
            #expect(try MotionScene.decoded(from: encoded).components == scene.components)
        } catch {
            try await package.remove()
            throw error
        }
    }

    @Test func rejectsDOMDependenciesInNativeComponents() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let entry = package.url.appendingPathComponent("NativeCard.tsx")
            try await Self.write("import {createPortal} from 'react-dom'; export default function Card() { return createPortal(null, null) }", to: entry)
            await #expect(throws: MotionSceneError.invalidField("React DOM components require a web scene")) {
                try await MotionComponentCompiler.shared.compile(at: entry, runtime: .reactNative)
            }
            try await package.remove()
        } catch {
            try await package.remove()
            throw error
        }
    }

    @concurrent private static func write(_ source: String, to url: URL) async throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    @concurrent private static func fixture(in directory: URL) async throws -> URL {
        try "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2' fill='red'/></svg>".write(to: directory.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
        let font = try #require(BundledResource.url("Fonts/Inter/Inter[opsz,wght].ttf"))
        try FileManager.default.copyItem(at: font, to: directory.appendingPathComponent("Inter.ttf"))
        try "@font-face {font-family: Product;src:url('./Inter.ttf')} .card {color:#123456;font-family:Product}".write(to: directory.appendingPathComponent("Card.css"), atomically: true, encoding: .utf8)
        let entry = directory.appendingPathComponent("Card.tsx")
        try """
            import React from 'react';
            import './Card.css';
            import icon from './icon.svg';
            export default function Card({price = 19}: {price: number}) {
              return <div className="card"><img src={icon}/>Actual product card {price}</div>;
            }
            """.write(to: entry, atomically: true, encoding: .utf8)
        return entry
    }
}
