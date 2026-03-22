import AppKit

struct RenderConfig {
    var fontSize: CGFloat = 14
    var bloomEnabled: Bool = true
    var crtEnabled: Bool = true
    var backgroundBlurEnabled: Bool = true
    var isFullscreen: Bool = false
    var shaderBundle: Bundle? = nil
    var scaleFactor: CGFloat? = nil

    static let screensaver = RenderConfig(
        fontSize: 14,
        bloomEnabled: true,
        crtEnabled: true,
        backgroundBlurEnabled: true,
        isFullscreen: true
    )
}
