import UIKit

enum EditorPalette {
    static let background = UIColor(red: 0.018, green: 0.018, blue: 0.022, alpha: 1)
    static let chrome = UIColor(red: 0.045, green: 0.045, blue: 0.052, alpha: 0.96)
    static let lane = UIColor(red: 0.09, green: 0.09, blue: 0.105, alpha: 1)
    static let accent = UIColor(red: 0.96, green: 0.25, blue: 0.36, alpha: 1)
    static let accentMuted = UIColor(red: 0.96, green: 0.25, blue: 0.36, alpha: 0.18)
    static let ink = UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
    static let secondaryInk = UIColor(red: 0.34, green: 0.34, blue: 0.38, alpha: 1)
}

/// A lightweight, directly scrubbable timeline that renders recorded stroke ranges.
final class TimelineControl: UIControl {
    var progress: Float = 1 {
        didSet {
            progress = min(1, max(0, progress))
            setNeedsDisplay()
            accessibilityValue = "\(Int(progress * 100)) percent"
        }
    }
    var duration: Float = LiquifyConfiguration.Timeline.minimumDuration { didSet { setNeedsDisplay() } }
    var strokeSegments: [ClosedRange<Float>] = [] { didSet { setNeedsDisplay() } }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 66) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "Deformation timeline"
        accessibilityTraits = [.adjustable]
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("TimelineControl is created programmatically")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let horizontalInset: CGFloat = 12
        let rulerY = max(24, rect.midY - 24)
        let laneRect = CGRect(x: horizontalInset, y: rulerY + 12, width: rect.width - horizontalInset * 2, height: 32)

        let lanePath = UIBezierPath(roundedRect: laneRect, cornerRadius: 6)
        EditorPalette.lane.setFill()
        lanePath.fill()

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.17).cgColor)
        context.setLineWidth(1)
        for tick in 0...40 {
            let x = horizontalInset + laneRect.width * CGFloat(tick) / 40
            let isSecond = tick % 16 == 0
            let isQuarter = tick % 4 == 0
            let height: CGFloat = isSecond ? 10 : (isQuarter ? 6 : 3)
            context.move(to: CGPoint(x: x, y: rulerY - height / 2))
            context.addLine(to: CGPoint(x: x, y: rulerY + height / 2))
        }
        context.strokePath()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.34)
        ]
        let displayedDuration = max(LiquifyConfiguration.Timeline.minimumDuration, duration)
        let labels: [(Float, String)] = [
            (0, "0s"),
            (0.5, String(format: "%.1fs", displayedDuration / 2)),
            (1, String(format: "%.1fs", displayedDuration))
        ]
        for (position, label) in labels {
            let text = NSString(string: label)
            let textWidth = text.size(withAttributes: labelAttributes).width
            let x = horizontalInset + laneRect.width * CGFloat(position) - textWidth * CGFloat(position)
            text.draw(at: CGPoint(x: x, y: rulerY - 20), withAttributes: labelAttributes)
        }

        context.saveGState()
        lanePath.addClip()
        for (index, segment) in strokeSegments.enumerated() {
            let start = laneRect.minX + laneRect.width * CGFloat(segment.lowerBound)
            let rawWidth = laneRect.width * CGFloat(segment.upperBound - segment.lowerBound)
            let clipRect = CGRect(
                x: start,
                y: laneRect.minY + 3,
                width: max(LiquifyConfiguration.Timeline.minimumVisibleClipWidth, rawWidth),
                height: laneRect.height - 6
            )
            let clip = UIBezierPath(roundedRect: clipRect, cornerRadius: 4)
            let alpha = 0.5 + CGFloat(index % 3) * 0.14
            EditorPalette.accent.withAlphaComponent(alpha).setFill()
            clip.fill()
        }
        context.restoreGState()

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1)
        for frame in 1..<20 {
            let x = laneRect.minX + laneRect.width * CGFloat(frame) / 20
            context.move(to: CGPoint(x: x, y: laneRect.minY + 3))
            context.addLine(to: CGPoint(x: x, y: laneRect.maxY - 3))
        }
        context.strokePath()

        let playheadX = laneRect.minX + laneRect.width * CGFloat(progress)
        context.setStrokeColor(EditorPalette.accent.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: playheadX, y: rulerY - 10))
        context.addLine(to: CGPoint(x: playheadX, y: laneRect.maxY + 5))
        context.strokePath()

        context.setFillColor(EditorPalette.accent.cgColor)
        let marker = UIBezierPath()
        marker.move(to: CGPoint(x: playheadX - 5, y: rulerY - 12))
        marker.addLine(to: CGPoint(x: playheadX + 5, y: rulerY - 12))
        marker.addLine(to: CGPoint(x: playheadX, y: rulerY - 6))
        marker.close()
        marker.fill()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateProgress(with: touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateProgress(with: touch)
        return true
    }

    override func accessibilityIncrement() {
        progress += LiquifyConfiguration.Timeline.accessibilityScrubStep
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        progress -= LiquifyConfiguration.Timeline.accessibilityScrubStep
        sendActions(for: .valueChanged)
    }

    private func updateProgress(with touch: UITouch) {
        let track = bounds.insetBy(dx: 12, dy: 0)
        progress = Float((touch.location(in: self).x - track.minX) / max(1, track.width))
        sendActions(for: .valueChanged)
    }
}

final class ParameterControl: UIView {
    let slider = UISlider()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let formatter: (Float) -> String

    var onValueChanged: ((Float) -> Void)?

    init(title: String, range: ClosedRange<Float>, value: Float, formatter: @escaping (Float) -> String) {
        self.formatter = formatter
        super.init(frame: .zero)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = EditorPalette.ink

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = EditorPalette.secondaryInk
        valueLabel.textAlignment = .center
        valueLabel.backgroundColor = UIColor.black.withAlphaComponent(0.055)
        valueLabel.layer.cornerRadius = 10
        valueLabel.clipsToBounds = true
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        valueLabel.heightAnchor.constraint(equalToConstant: 21).isActive = true

        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.value = value
        slider.accessibilityLabel = title
        slider.minimumTrackTintColor = EditorPalette.accent
        slider.maximumTrackTintColor = UIColor.black.withAlphaComponent(0.12)
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        let labels = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        labels.axis = .horizontal
        labels.alignment = .center
        let stack = UIStackView(arrangedSubviews: [labels, slider])
        stack.axis = .vertical
        stack.spacing = 2
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateValueLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func valueChanged() {
        updateValueLabel()
        onValueChanged?(slider.value)
    }

    private func updateValueLabel() {
        let formattedValue = formatter(slider.value)
        valueLabel.text = formattedValue
        slider.accessibilityValue = formattedValue
    }
}
