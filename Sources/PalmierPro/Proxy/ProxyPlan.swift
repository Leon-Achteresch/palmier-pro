import AVFoundation

enum ProxyPlan {
    static let maxWidth: CGFloat = 960
    static let scale: CGFloat = 0.5
    static let minimumEdge: CGFloat = 16

    static func filename(assetId: String) -> String {
        "\(assetId).mov"
    }

    static func relativePath(assetId: String) -> String {
        "\(Project.proxyDirectoryName)/\(filename(assetId: assetId))"
    }

    static func url(assetId: String, projectURL: URL) -> URL {
        projectURL.appendingPathComponent(relativePath(assetId: assetId), isDirectory: false)
    }

    static func isEligible(type: ClipType) -> Bool {
        type == .video
    }

    static func targetSize(displaySize: CGSize) -> CGSize? {
        let width = abs(displaySize.width)
        let height = abs(displaySize.height)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let scaled = width * scale
        let factor = scaled > maxWidth ? maxWidth / width : scale
        let targetWidth = evenEdge(width * factor)
        let targetHeight = evenEdge(height * factor)
        return CGSize(width: targetWidth, height: targetHeight)
    }

    private static func evenEdge(_ value: CGFloat) -> CGFloat {
        max(minimumEdge, (value / 2).rounded() * 2)
    }
}
