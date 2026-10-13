import SwiftUI
import UIKit

/// Draws the latest camera frame rotated by the scope's roll angle.
///
/// Two framings:
///  - rectangle: the whole frame, fit-centred (for a fixed, unrotated picture);
///  - circle: the disc inscribed in the frame, filling the view's short side. A disc looks
///    the same at every angle, so when auto-rotation keeps the picture upright as the scope
///    turns, nothing appears to move but the scene; and every pixel inside it is real image
///    at any angle, with no corners sweeping in and out.
final class CameraUIView: UIView {
    /// Clips to the disc (or to the view); holds the picture.
    private let clip = CALayer()
    private let picture = CALayer()
    private var imageSize = CGSize.zero
    private var angleDegrees: CGFloat = 0

    /// Show the inscribed disc instead of the whole rectangle.
    var circular = false {
        didSet { if circular != oldValue { layoutPicture() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .black
        isOpaque = true
        clip.masksToBounds = true
        picture.contentsGravity = .resize
        picture.magnificationFilter = .linear
        picture.minificationFilter = .linear
        clip.addSublayer(picture)
        layer.addSublayer(clip)
    }

    func setFrame(_ image: CGImage, angleDegrees: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
        imageSize = CGSize(width: image.width, height: image.height)
        self.angleDegrees = CGFloat(angleDegrees)
        layoutPicture()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = nil
        CATransaction.commit()
        imageSize = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPicture()
    }

    private func layoutPicture() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let vw = bounds.width
        let vh = bounds.height
        if circular {
            // A layer corner radius gives an anti-aliased edge.
            let d = min(vw, vh)
            clip.frame = CGRect(x: (vw - d) / 2, y: (vh - d) / 2, width: d, height: d)
            clip.cornerRadius = d / 2
        } else {
            clip.frame = bounds
            clip.cornerRadius = 0
        }
        let bw = imageSize.width
        let bh = imageSize.height
        guard vw > 0, vh > 0, bw > 0, bh > 0 else { return }
        let scale = circular ? min(vw, vh) / min(bw, bh) : min(vw / bw, vh / bh)
        picture.bounds = CGRect(x: 0, y: 0, width: bw * scale, height: bh * scale)
        picture.position = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        // Positive angles turn clockwise on screen, as on Android.
        picture.setAffineTransform(CGAffineTransform(rotationAngle: angleDegrees * .pi / 180))
    }
}

/// SwiftUI host for [CameraUIView]; the viewer model draws into it directly, so frames do
/// not go through SwiftUI's diffing.
struct CameraView: UIViewRepresentable {
    let model: ViewerModel
    let circular: Bool

    func makeUIView(context: Context) -> CameraUIView {
        let view = CameraUIView()
        model.attach(view)
        return view
    }

    func updateUIView(_ view: CameraUIView, context: Context) {
        view.circular = circular
    }
}
