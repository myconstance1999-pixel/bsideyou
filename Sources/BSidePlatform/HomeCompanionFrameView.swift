// BSidePlatform — ordinary in-window pixels; no player or media clock in the UI process.
import AppKit

open class HomeCompanionFrameView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        layer?.cornerRadius = 16
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    open override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public func display(_ image: CGImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}
