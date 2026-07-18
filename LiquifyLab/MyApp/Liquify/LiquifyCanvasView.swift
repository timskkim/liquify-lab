import MetalKit
import UIKit

final class LiquifyCanvasView: MTKView {
    private(set) var liquifyRenderer: LiquifyRenderer?
    private let brushCursor = CAShapeLayer()
    private var lastViewPoint: CGPoint?
    private var lastImagePoint: SIMD2<Float>?
    private var strokeTouchStartTimestamp: TimeInterval = 0
    private var strokeTimelineStart: Float = 0
    private var lastTimelineTime: Float = 0

    var brushDiameter: CGFloat = LiquifyConfiguration.Brush.diameter {
        didSet { updateCursor(at: brushCursor.position) }
    }
    var brushStrength: Float = LiquifyConfiguration.Brush.strength

    var canUndo: Bool { liquifyRenderer?.canUndo ?? false }
    var canRedo: Bool { liquifyRenderer?.canRedo ?? false }
    var timelineDuration: Float { liquifyRenderer?.timelineDuration ?? LiquifyConfiguration.Timeline.minimumDuration }
    var timelineSegments: [ClosedRange<Float>] { liquifyRenderer?.normalizedStrokeSegments ?? [] }
    var textureMemoryMegabytes: Double { liquifyRenderer?.estimatedTextureMemoryMegabytes ?? 0 }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Liquify canvas"
        accessibilityHint = "Drag with Apple Pencil or one finger to push the image"
        accessibilityTraits = [.image, .allowsDirectInteraction]
        clipsToBounds = true
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        brushCursor.fillColor = EditorPalette.accent.withAlphaComponent(0.08).cgColor
        brushCursor.strokeColor = EditorPalette.accent.withAlphaComponent(0.9).cgColor
        brushCursor.lineWidth = 1.5
        brushCursor.shadowColor = UIColor.black.cgColor
        brushCursor.shadowOpacity = 0.45
        brushCursor.shadowRadius = 3
        brushCursor.isHidden = true
        layer.addSublayer(brushCursor)

        liquifyRenderer = LiquifyRenderer(metalView: self)
        if liquifyRenderer == nil {
            showUnsupportedDeviceMessage()
        }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    private func showUnsupportedDeviceMessage() {
        isUserInteractionEnabled = false
        backgroundColor = EditorPalette.chrome

        let label = UILabel()
        label.text = "Liquify Lab requires an iPad with Metal read-write texture support."
        label.textColor = UIColor.white.withAlphaComponent(0.72)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.72)
        ])
    }

    // MARK: - Editor API

    func setSourceImage(_ image: UIImage) {
        liquifyRenderer?.setSourceImage(image)
    }

    func undo() { liquifyRenderer?.undo() }
    func redo() { liquifyRenderer?.redo() }
    func reset() { liquifyRenderer?.reset() }

    func setPlaybackProgress(_ progress: Float) {
        liquifyRenderer?.seekTimeline(to: progress)
    }

    func setOriginalPreviewVisible(_ visible: Bool) {
        liquifyRenderer?.setOriginalPreviewVisible(visible)
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            brushCursor.isHidden = false
            updateCursor(at: point)
        default:
            brushCursor.isHidden = true
        }
    }

    private func updateCursor(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        brushCursor.position = point
        let rect = CGRect(x: -brushDiameter / 2, y: -brushDiameter / 2, width: brushDiameter, height: brushDiameter)
        brushCursor.path = UIBezierPath(ovalIn: rect).cgPath
        CATransaction.commit()
    }

    // MARK: - Pencil and touch input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let renderer = liquifyRenderer, let touch = touches.first else { return }
        let viewPoint = touch.location(in: self)
        guard let imagePoint = renderer.imagePoint(for: viewPoint, in: bounds.size) else { return }

        brushCursor.isHidden = false
        updateCursor(at: viewPoint)
        strokeTimelineStart = renderer.beginStroke()
        strokeTouchStartTimestamp = touch.timestamp
        lastTimelineTime = strokeTimelineStart
        lastViewPoint = viewPoint
        lastImagePoint = imagePoint
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            append(sample: sample)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            append(sample: touch)
        }
        liquifyRenderer?.endStroke()
        lastViewPoint = nil
        lastImagePoint = nil
        brushCursor.isHidden = true
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        liquifyRenderer?.cancelStroke()
        lastViewPoint = nil
        lastImagePoint = nil
        brushCursor.isHidden = true
    }

    /// Converts coalesced UIKit samples into evenly spaced GPU stamps while
    /// preserving pressure and the original gesture timing for timeline replay.
    private func append(sample touch: UITouch) {
        let viewPoint = touch.location(in: self)
        guard let renderer = liquifyRenderer,
              let previousViewPoint = lastViewPoint,
              let previousImagePoint = lastImagePoint,
              let imagePoint = renderer.imagePoint(for: viewPoint, in: bounds.size) else { return }

        updateCursor(at: viewPoint)

        let distance = hypot(viewPoint.x - previousViewPoint.x, viewPoint.y - previousViewPoint.y)
        guard distance > LiquifyConfiguration.Input.minimumMovement else { return }

        let spacing = max(
            LiquifyConfiguration.Input.minimumSampleSpacing,
            brushDiameter * LiquifyConfiguration.Input.sampleSpacingRatio
        )
        let sampleCount = max(1, Int(ceil(distance / spacing)))
        let pressure: Float
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            pressure = Float(min(1, max(
                LiquifyConfiguration.Input.minimumPencilPressure,
                touch.force / touch.maximumPossibleForce
            )))
        } else {
            pressure = LiquifyConfiguration.Input.fingerPressure
        }

        let movement = imagePoint - previousImagePoint
        let radius = renderer.normalizedRadius(for: brushDiameter / 2, in: bounds.size)
        let step = movement / Float(sampleCount)
        let sampledTime = strokeTimelineStart + Float(max(0, touch.timestamp - strokeTouchStartTimestamp))
        let currentTimelineTime = max(lastTimelineTime, sampledTime)
        let timelineStep = (currentTimelineTime - lastTimelineTime) / Float(sampleCount)
        var stamps: [LiquifyBrushStamp] = []
        stamps.reserveCapacity(sampleCount)

        for index in 1...sampleCount {
            let fraction = Float(index) / Float(sampleCount)
            let location = previousImagePoint + movement * fraction
            stamps.append(
                LiquifyBrushStamp(
                    location: location,
                    delta: step,
                    radius: radius,
                    strength: brushStrength * pressure,
                    timelineTime: lastTimelineTime + timelineStep * Float(index)
                )
            )
        }

        renderer.append(stamps: stamps)
        lastViewPoint = viewPoint
        lastImagePoint = imagePoint
        lastTimelineTime = currentTimelineTime
    }
}
