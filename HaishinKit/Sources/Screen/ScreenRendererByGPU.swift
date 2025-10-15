import Accelerate
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

final class ScreenRendererByGPU: ScreenRenderer {
    var bounds: CGRect = .init(origin: .zero, size: Screen.size)
    var synchronizationClock: CMClock?
    var presentationTimeStamp: CMTime = .zero

    lazy var context = {
        guard let deive = MTLCreateSystemDefaultDevice() else {
            return CIContext(options: nil)
        }
        return CIContext(mtlDevice: deive)
    }()

    var backgroundColor = CGColor(red: 0x00, green: 0x00, blue: 0x00, alpha: 0x00) {
        didSet {
            guard backgroundColor != oldValue else {
                return
            }
            backgroundCIColor = CIColor(cgColor: backgroundColor)
        }
    }

    private var canvas: CIImage = .init()
    private var images: [ScreenObject: CIImage] = [:]
    private var pixelBuffer: CVPixelBuffer?
    private var backgroundCIColor = CIColor()
    private var roundedRectangleFactory = RoundedRectangleFactory()

    func setTarget(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else {
            return
        }
        self.pixelBuffer = pixelBuffer
        canvas = CIImage(color: backgroundCIColor).cropped(to: bounds)
    }

    func layout(_ screenObject: ScreenObject) {
        guard let image: CIImage = screenObject.makeImage(self) else {
            return
        }
        if 0 < screenObject.cornerRadius {
            if let mask = roundedRectangleFactory.cornerRadius(screenObject.bounds.size, cornerRadius: screenObject.cornerRadius) {
                images[screenObject] = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    "inputMaskImage": mask
                ])
            } else {
                images[screenObject] = image
            }
        } else {
            images[screenObject] = image
        }
    }

    func draw(_ screenObject: ScreenObject) {
        guard let image = images[screenObject] else {
            return
        }
        let origin = screenObject.bounds.origin
        if origin.x == 0 && origin.y == 0 {
            canvas = image
                .composited(over: canvas)
        } else {
            canvas = image
                .transformed(by: .init(translationX: origin.x, y: bounds.height - origin.y - screenObject.bounds.height))
                .composited(over: canvas)
        }
    }

    func render() {
        if let pixelBuffer {
            context.render(canvas, to: pixelBuffer)
        }
    }
}
