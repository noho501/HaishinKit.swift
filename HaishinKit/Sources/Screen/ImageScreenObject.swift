import CoreImage

/// An object that manages offscreen rendering a cgImage source.
public final class ImageScreenObject: ScreenObject {
    /// Specifies the image.
    public var cgImage: CGImage? {
        didSet {
            guard cgImage != oldValue else {
                return
            }
            invalidateLayout()
        }
    }

    override public func makeImage(_ renderer: some ScreenRenderer) -> CGImage? {
        let intersection = bounds.intersection(renderer.bounds)

        guard bounds != intersection else {
            return cgImage
        }

        // Handling when the drawing area is exceeded.
        let x: CGFloat
        switch horizontalAlignment {
        case .left:
            x = bounds.origin.x
        case .center:
            x = bounds.origin.x / 2
        case .right:
            x = 0.0
        }

        let y: CGFloat
        switch verticalAlignment {
        case .top:
            y = 0.0
        case .middle:
            y = abs(bounds.origin.y) / 2
        case .bottom:
            y = abs(bounds.origin.y)
        }

        return cgImage?.cropping(to: .init(origin: .init(x: x, y: y), size: intersection.size))
    }

    override public func makeImage(_ renderer: some ScreenRenderer) -> CIImage? {
        guard let image: CGImage = makeImage(renderer) else {
            return nil
        }
        return CIImage(cgImage: image)
    }

    override public func makeBounds(_ size: CGSize) -> CGRect {
        guard let cgImage else {
            return super.makeBounds(size)
        }
        return super.makeBounds(size == .zero ? cgImage.size : size)
    }
}
