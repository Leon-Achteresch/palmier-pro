import Foundation

extension MotionNode.Kind {
    @MainActor var title: String {
        switch self {
        case .component: L10n.string("Component")
        case .group: L10n.string("Group")
        case .text: L10n.string("Text")
        case .shape: L10n.string("Rectangle")
        case .path: L10n.string("Path")
        case .image: L10n.string("Image")
        case .camera: L10n.string("Camera")
        }
    }
    var symbol: String {
        switch self {
        case .component: "square.stack.3d.up"
        case .group: "folder"
        case .text: "textformat"
        case .shape: "rectangle"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .image: "photo"
        case .camera: "video"
        }
    }
}

extension MotionProperty {
    @MainActor var title: String {
        switch self {
        case .x: L10n.string("X")
        case .y: L10n.string("Y")
        case .width: L10n.string("Width")
        case .height: L10n.string("Height")
        case .scaleX: L10n.string("Scale X")
        case .scaleY: L10n.string("Scale Y")
        case .rotation: L10n.string("Rotation")
        case .opacity: L10n.string("Opacity")
        case .anchorX: L10n.string("Anchor X")
        case .anchorY: L10n.string("Anchor Y")
        case .cornerRadius: L10n.string("Corner Radius")
        case .blur: L10n.string("Blur")
        case .fill: L10n.string("Fill")
        case .stroke: L10n.string("Stroke")
        case .strokeWidth: L10n.string("Stroke Width")
        case .reveal: L10n.string("Reveal")
        case .text: L10n.string("Text")
        case .fontSize: L10n.string("Font Size")
        case .fontFamily: L10n.string("Font Family")
        case .fontWeight: L10n.string("Font Weight")
        case .letterSpacing: L10n.string("Letter Spacing")
        case .textAlign: L10n.string("Text Alignment")
        case .path: L10n.string("Path")
        case .image: L10n.string("Image")
        case .mask: L10n.string("Mask")
        case .textProgress: L10n.string("Text Progress")
        case .pathProgress: L10n.string("Path Progress")
        }
    }
}

extension MotionRecipe.Kind {
    @MainActor var title: String {
        switch self {
        case .slideUp: L10n.string("Slide Up and Fade")
        case .slideLeft: L10n.string("Slide Left and Fade")
        case .pop: L10n.string("Pop")
        case .fadeIn: L10n.string("Fade In")
        case .fadeOut: L10n.string("Fade Out")
        case .float: L10n.string("Float")
        case .pulse: L10n.string("Pulse")
        case .spin: L10n.string("Spin")
        case .typewriter: L10n.string("Typewriter")
        case .textStagger: L10n.string("Stagger Characters")
        }
    }
}

extension MotionEasing.Kind {
    @MainActor var title: String {
        switch self {
        case .linear: L10n.string("Linear")
        case .hold: L10n.string("Hold")
        case .easeIn: L10n.string("Ease In")
        case .easeOut: L10n.string("Ease Out")
        case .easeInOut: L10n.string("Ease In-Out")
        case .bezier: L10n.string("Custom Bezier")
        case .spring: L10n.string("Spring")
        }
    }
}

extension MotionAlignment {
    @MainActor var title: String {
        switch self {
        case .left: L10n.string("Align Left")
        case .center: L10n.string("Align Center")
        case .right: L10n.string("Align Right")
        case .top: L10n.string("Align Top")
        case .middle: L10n.string("Align Middle")
        case .bottom: L10n.string("Align Bottom")
        }
    }
}

extension MotionComponentTemplate {
    @MainActor var title: String {
        switch self {
        case .card: L10n.string("Card")
        case .title: L10n.string("Title")
        }
    }

}
