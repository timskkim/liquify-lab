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

/// A throttled diagnostic HUD showing how raw input becomes rendered brush strength
final class InputMetricsView: UIView {
    private let sourceLabel = UILabel()
    private let pressureValueLabel = UILabel()
    private let strengthValueLabel = UILabel()
    private let pressureBar = UIProgressView(progressViewStyle: .bar)
    private let strengthBar = UIProgressView(progressViewStyle: .bar)
    private var displayedBrushStrength = LiquifyConfiguration.Brush.strength

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        backgroundColor = EditorPalette.chrome.withAlphaComponent(0.92)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        sourceLabel.text = "INPUT MONITOR · WAITING FOR TOUCH"
        sourceLabel.font = .systemFont(ofSize: 9, weight: .bold)
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.5)

        let rateLabel = UILabel()
        rateLabel.text = "DISPLAY \(LiquifyConfiguration.Input.metricsDisplayRate) HZ"
        rateLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        rateLabel.textColor = UIColor.white.withAlphaComponent(0.28)

        [pressureValueLabel, strengthValueLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            $0.textColor = UIColor.white.withAlphaComponent(0.72)
            $0.textAlignment = .right
        }
        pressureValueLabel.text = String(
            format: "force 0.000 / cap %.3f = 0.000",
            LiquifyConfiguration.Input.pencilForceNormalizationCap
        )
        strengthValueLabel.text = String(
            format: "brush %.3f × pressure 0.000 = 0.000",
            displayedBrushStrength
        )

        configureBar(pressureBar, color: UIColor.white.withAlphaComponent(0.72))
        configureBar(strengthBar, color: EditorPalette.accent)

        let header = UIStackView(arrangedSubviews: [sourceLabel, UIView(), rateLabel])
        header.axis = .horizontal
        header.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            header,
            makeMetricRow(title: "PRESSURE", valueLabel: pressureValueLabel, bar: pressureBar),
            makeMetricRow(title: "FINAL STAMP STRENGTH", valueLabel: strengthValueLabel, bar: strengthBar)
        ])
        stack.axis = .vertical
        stack.spacing = 6
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Input pressure monitor"
        accessibilityValue = "Waiting for touch"
    }

    required init?(coder: NSCoder) {
        fatalError("InputMetricsView is created programmatically")
    }

    func update(with metrics: LiquifyInputMetrics) {
        switch metrics.source {
        case .pencil:
            sourceLabel.text = "APPLE PENCIL · RAW FORCE"
            pressureValueLabel.text = String(
                format: "force %.3f / cap %.3f = %.3f",
                metrics.rawForce,
                metrics.normalizationForceCap,
                metrics.normalizedPressure
            )
        case .finger:
            sourceLabel.text = "FINGER · FIXED FALLBACK"
            pressureValueLabel.text = String(
                format: "fixed pressure = %.3f",
                metrics.normalizedPressure
            )
        }

        displayedBrushStrength = metrics.brushStrength
        strengthValueLabel.text = String(
            format: "brush %.3f × pressure %.3f = %.3f",
            metrics.brushStrength,
            metrics.normalizedPressure,
            metrics.finalStampStrength
        )
        pressureBar.setProgress(metrics.normalizedPressure, animated: true)
        strengthBar.setProgress(metrics.finalStampStrength, animated: true)
        accessibilityValue = String(
            format: "Pressure %.3f, brush strength %.3f, final stamp strength %.3f",
            metrics.normalizedPressure,
            metrics.brushStrength,
            metrics.finalStampStrength
        )
    }

    func reset() {
        sourceLabel.text = "INPUT MONITOR · WAITING FOR TOUCH"
        pressureValueLabel.text = String(
            format: "force 0.000 / cap %.3f = 0.000",
            LiquifyConfiguration.Input.pencilForceNormalizationCap
        )
        strengthValueLabel.text = String(
            format: "brush %.3f × pressure 0.000 = 0.000",
            displayedBrushStrength
        )
        pressureBar.setProgress(0, animated: true)
        strengthBar.setProgress(0, animated: true)
        accessibilityValue = "Waiting for touch"
    }

    private func configureBar(_ bar: UIProgressView, color: UIColor) {
        bar.progress = 0
        bar.progressTintColor = color
        bar.trackTintColor = EditorPalette.lane
        bar.layer.cornerRadius = 2
        bar.clipsToBounds = true
        bar.transform = CGAffineTransform(scaleX: 1, y: 2)
    }

    private func makeMetricRow(title: String, valueLabel: UILabel, bar: UIProgressView) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 8, weight: .bold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.42)

        let labels = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        labels.axis = .horizontal
        labels.alignment = .center

        let row = UIStackView(arrangedSubviews: [labels, bar])
        row.axis = .vertical
        row.spacing = 3
        return row
    }
}

/// A lightweight, directly scrubbable timeline that renders recorded stroke ranges
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
