import MetalKit
import PhotosUI
import UIKit

/// A gesture recognizer that observes touch down without cancelling the underlying interaction
private final class TouchDownGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .recognized
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

final class LiquifyEditorViewController: UIViewController, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate {
    private enum ButtonMaterialStyle {
        case glass
        case clearGlass
    }

    private let canvas = LiquifyCanvasView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    private let timeline = TimelineControl()
    private let inputMetricsView = InputMetricsView()
    private let performanceLabel = UILabel()
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let originalButton = UIButton(type: .system)
    private let inspectorButton = UIButton(type: .system)
    private let inspector = UIVisualEffectView()
    private lazy var inspectorDismissRecognizer: UIGestureRecognizer = {
        let recognizer = TouchDownGestureRecognizer(
            target: self,
            action: #selector(dismissInspectorIfNeeded)
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private var displayLink: CADisplayLink?
    private var playbackStart: CFTimeInterval?
    private var playbackOriginProgress: Float = 0
    private var isPlaying = false
    private var isInspectorVisible = false
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var lastMetricsTimestamp: CFTimeInterval = 0
    private var sampledFrameTimes: [CFTimeInterval] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = EditorPalette.background
        configureInterface()
        configureActions()

        canvas.onInputMetricsChanged = { [weak self] metrics in
            self?.inputMetricsView.update(with: metrics)
        }
        canvas.onInputMetricsEnded = { [weak self] in
            self?.inputMetricsView.reset()
        }
        canvas.setSourceImage(DemoImageFactory.makeImage())
        canvas.liquifyRenderer?.onHistoryChanged = { [weak self] in
            self?.updateHistoryButtons()
            self?.updateTimelineMetadata()
        }
        updateHistoryButtons()
        updateTimelineMetadata()

        let displayLink = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    deinit {
        displayLink?.invalidate()
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        performanceLabel.isHidden = view.bounds.width < LiquifyConfiguration.Interface.compactMetricsWidth
    }

    // MARK: - Interface

    private func configureInterface() {
        let topBar = makeTopBar()
        let timelinePanel = makeTimelinePanel()
        let controlsDeck = UIView()
        controlsDeck.backgroundColor = EditorPalette.background
        controlsDeck.layer.cornerRadius = 22
        controlsDeck.layer.cornerCurve = .continuous
        controlsDeck.layer.borderWidth = 0.5
        controlsDeck.layer.borderColor = UIColor.white.withAlphaComponent(0.07).cgColor
        configureInspector()

        view.addSubview(canvas)
        view.addSubview(inputMetricsView)
        view.addSubview(controlsDeck)
        controlsDeck.addSubview(topBar)
        controlsDeck.addSubview(timelinePanel)
        controlsDeck.addSubview(inspector)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        inputMetricsView.translatesAutoresizingMaskIntoConstraints = false
        controlsDeck.translatesAutoresizingMaskIntoConstraints = false
        timelinePanel.translatesAutoresizingMaskIntoConstraints = false
        topBar.translatesAutoresizingMaskIntoConstraints = false
        inspector.translatesAutoresizingMaskIntoConstraints = false

        let inputMetricsWidth = inputMetricsView.widthAnchor.constraint(
            equalTo: canvas.widthAnchor,
            constant: -24
        )
        inputMetricsWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            canvas.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            canvas.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            canvas.bottomAnchor.constraint(equalTo: controlsDeck.topAnchor, constant: -6),

            inputMetricsView.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12),
            inputMetricsView.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            inputMetricsView.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 12),
            inputMetricsView.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -12),
            inputMetricsView.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            inputMetricsWidth,
            inputMetricsView.heightAnchor.constraint(equalToConstant: 82),

            controlsDeck.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            controlsDeck.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            controlsDeck.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controlsDeck.heightAnchor.constraint(equalToConstant: 286),

            topBar.topAnchor.constraint(equalTo: controlsDeck.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: controlsDeck.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: controlsDeck.trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(equalToConstant: 46),

            timelinePanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            timelinePanel.leadingAnchor.constraint(equalTo: controlsDeck.leadingAnchor, constant: 8),
            timelinePanel.trailingAnchor.constraint(equalTo: controlsDeck.trailingAnchor, constant: -8),
            timelinePanel.bottomAnchor.constraint(equalTo: controlsDeck.bottomAnchor, constant: -8),

            inspector.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            inspector.centerXAnchor.constraint(equalTo: inspectorButton.centerXAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 280),
            inspector.heightAnchor.constraint(equalToConstant: 164),
            inspector.leadingAnchor.constraint(greaterThanOrEqualTo: controlsDeck.leadingAnchor, constant: 8),
            inspector.trailingAnchor.constraint(lessThanOrEqualTo: controlsDeck.trailingAnchor, constant: -8)
        ])
    }

    private func makeTopBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = EditorPalette.chrome
        bar.layer.cornerRadius = 15
        bar.layer.cornerCurve = .continuous
        bar.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        bar.clipsToBounds = true

        let mark = UIView()
        mark.backgroundColor = EditorPalette.accent
        mark.layer.cornerRadius = 5
        mark.widthAnchor.constraint(equalToConstant: 10).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let title = UILabel()
        title.text = "Liquify"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = UIColor.white.withAlphaComponent(0.88)

        let mode = UILabel()
        mode.text = "PUSH"
        mode.font = .systemFont(ofSize: 9, weight: .bold)
        mode.textColor = EditorPalette.accent
        mode.backgroundColor = EditorPalette.accentMuted
        mode.textAlignment = .center
        mode.layer.cornerRadius = 8
        mode.clipsToBounds = true
        mode.widthAnchor.constraint(equalToConstant: 48).isActive = true
        mode.heightAnchor.constraint(equalToConstant: 22).isActive = true

        configureChromeButton(inspectorButton, symbol: "slider.horizontal.3", accessibilityLabel: "Show Push settings")
        configureChromeButton(undoButton, symbol: "arrow.uturn.backward", accessibilityLabel: "Undo")
        configureChromeButton(redoButton, symbol: "arrow.uturn.forward", accessibilityLabel: "Redo")
        configureChromeButton(resetButton, symbol: "arrow.counterclockwise", accessibilityLabel: "Reset")

        let importButton = UIButton(type: .system)
        var importConfiguration = makeButtonConfiguration(style: .glass)
        importConfiguration.image = UIImage(systemName: "plus")
        importConfiguration.cornerStyle = .capsule
        importConfiguration.baseForegroundColor = .white
        importButton.configuration = importConfiguration
        importButton.accessibilityLabel = "Import image"
        importButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        importButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        importButton.addAction(UIAction { [weak self] _ in self?.presentImagePicker() }, for: .touchUpInside)

        let spacer = UIView()
        let stack = UIStackView(arrangedSubviews: [mark, title, mode, spacer, inspectorButton, undoButton, redoButton, resetButton, importButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7
        bar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6)
        ])
        return bar
    }

    private func makeTimelinePanel() -> UIView {
        let panel = UIView()
        panel.backgroundColor = EditorPalette.chrome
        panel.layer.cornerRadius = 15
        panel.layer.cornerCurve = .continuous
        panel.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        panel.clipsToBounds = true

        var playConfiguration = UIButton.Configuration.plain()
        playConfiguration.image = UIImage(systemName: "play.fill")
        playConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        playConfiguration.baseForegroundColor = UIColor.white.withAlphaComponent(0.9)
        playButton.configuration = playConfiguration
        playButton.accessibilityLabel = "Play deformation"
        playButton.layer.cornerRadius = 17
        playButton.layer.cornerCurve = .continuous
        playButton.layer.borderWidth = 0

        var originalConfiguration = makeButtonConfiguration(style: .clearGlass)
        originalConfiguration.title = "Original"
        originalConfiguration.image = UIImage(systemName: "eye")
        originalConfiguration.imagePadding = 5
        originalConfiguration.baseForegroundColor = UIColor.white.withAlphaComponent(0.65)
        originalConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        originalButton.configuration = originalConfiguration
        originalButton.accessibilityLabel = "Compare with original"
        originalButton.accessibilityHint = "Press and hold to temporarily hide the deformation"

        performanceLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        performanceLabel.textColor = UIColor.white.withAlphaComponent(0.32)
        performanceLabel.textAlignment = .right
        performanceLabel.text = "120 fps  ·  8.3 ms  ·  -- MB"
        performanceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rightControls = UIStackView(arrangedSubviews: [originalButton, performanceLabel])
        rightControls.axis = .horizontal
        rightControls.alignment = .center
        rightControls.spacing = 10

        let header = UIView()
        header.addSubview(playButton)
        header.addSubview(rightControls)
        [playButton, rightControls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 48),
            playButton.heightAnchor.constraint(equalToConstant: 34),
            rightControls.leadingAnchor.constraint(greaterThanOrEqualTo: playButton.trailingAnchor, constant: 14),
            rightControls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rightControls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        let stack = UIStackView(arrangedSubviews: [header, timeline])
        stack.axis = .vertical
        stack.spacing = 0
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -7),
            header.heightAnchor.constraint(equalToConstant: 38)
        ])
        return panel
    }

    private func configureInspector() {
        inspector.effect = makeVisualEffect(fallback: .systemMaterialLight)
        inspector.overrideUserInterfaceStyle = .light
        inspector.layer.cornerRadius = 22
        inspector.layer.cornerCurve = .continuous
        inspector.clipsToBounds = true
        inspector.layer.borderWidth = 0.5
        inspector.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        inspector.layer.shadowColor = UIColor.black.cgColor
        inspector.layer.shadowOpacity = 0.32
        inspector.layer.shadowRadius = 22
        inspector.layer.shadowOffset = CGSize(width: 0, height: 10)
        inspector.clipsToBounds = false
        inspector.contentView.layer.cornerRadius = 22
        inspector.contentView.layer.cornerCurve = .continuous
        inspector.contentView.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: "point.topleft.down.curvedto.point.bottomright.up"))
        icon.tintColor = EditorPalette.accent
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = UILabel()
        title.text = "Push"
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = EditorPalette.ink

        let pressure = UILabel()
        pressure.text = "PENCIL PRESSURE"
        pressure.font = .systemFont(ofSize: 8, weight: .bold)
        pressure.textColor = EditorPalette.accent

        let titleStack = UIStackView(arrangedSubviews: [icon, title, UIView(), pressure])
        titleStack.axis = .horizontal
        titleStack.alignment = .center
        titleStack.spacing = 7

        let sizeControl = ParameterControl(
            title: "Radius",
            range: 48...220,
            value: Float(LiquifyConfiguration.Brush.diameter)
        ) { "\(Int($0)) pt" }
        sizeControl.onValueChanged = { [weak self] value in self?.canvas.brushDiameter = CGFloat(value) }

        let strengthControl = ParameterControl(
            title: "Strength",
            range: 0.15...1,
            value: LiquifyConfiguration.Brush.strength
        ) { "\(Int($0 * 100))%" }
        strengthControl.onValueChanged = { [weak self] value in self?.canvas.brushStrength = value }

        let stack = UIStackView(arrangedSubviews: [titleStack, sizeControl, strengthControl])
        stack.axis = .vertical
        stack.spacing = 7
        inspector.contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: inspector.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: inspector.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: inspector.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: inspector.contentView.bottomAnchor, constant: -12),
            titleStack.heightAnchor.constraint(equalToConstant: 24)
        ])
        inspector.alpha = 0
        inspector.isUserInteractionEnabled = false
        inspector.transform = CGAffineTransform(scaleX: 0.92, y: 0.92).translatedBy(x: 0, y: -8)
    }

    // MARK: - Actions

    private func configureActions() {
        view.addGestureRecognizer(inspectorDismissRecognizer)

        inspectorButton.addAction(UIAction { [weak self] _ in self?.toggleInspector() }, for: .touchUpInside)
        undoButton.addAction(UIAction { [weak self] _ in
            self?.stopPlayback(resetToEnd: false)
            self?.canvas.undo()
        }, for: .touchUpInside)
        redoButton.addAction(UIAction { [weak self] _ in
            self?.stopPlayback(resetToEnd: false)
            self?.canvas.redo()
        }, for: .touchUpInside)
        resetButton.addAction(UIAction { [weak self] _ in
            self?.stopPlayback(resetToEnd: true)
            self?.canvas.reset()
        }, for: .touchUpInside)

        playButton.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .touchUpInside)
        timeline.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.stopPlayback(resetToEnd: false)
            self.canvas.setPlaybackProgress(self.timeline.progress)
        }, for: .valueChanged)

        originalButton.addTarget(self, action: #selector(showOriginal), for: [.touchDown, .touchDragEnter])
        originalButton.addTarget(self, action: #selector(restoreDeformation), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    // MARK: - Materials

    private func makeVisualEffect(fallback: UIBlurEffect.Style) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect()
        }
        return UIBlurEffect(style: fallback)
    }

    private func makeButtonConfiguration(style: ButtonMaterialStyle) -> UIButton.Configuration {
        if #available(iOS 26.0, *) {
            switch style {
            case .glass: return .glass()
            case .clearGlass: return .clearGlass()
            }
        }

        switch style {
        case .clearGlass: return .plain()
        case .glass: return .gray()
        }
    }

    private func configureChromeButton(_ button: UIButton, symbol: String, accessibilityLabel: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        configuration.baseForegroundColor = UIColor.white.withAlphaComponent(0.72)
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    // MARK: - Editor state and playback

    private func toggleInspector() {
        setInspectorVisible(!isInspectorVisible)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === inspectorDismissRecognizer, isInspectorVisible else { return false }
        let location = touch.location(in: view)
        let inspectorFrame = inspector.convert(inspector.bounds, to: view)
        let buttonFrame = inspectorButton.convert(inspectorButton.bounds, to: view)
        return !inspectorFrame.contains(location) && !buttonFrame.contains(location)
    }

    @objc private func dismissInspectorIfNeeded() {
        setInspectorVisible(false)
    }

    private func setInspectorVisible(_ visible: Bool) {
        guard visible != isInspectorVisible else { return }
        isInspectorVisible = visible
        inspector.isUserInteractionEnabled = visible
        inspectorButton.isSelected = visible
        inspectorButton.accessibilityLabel = visible ? "Hide Push settings" : "Show Push settings"
        inspectorButton.configuration?.baseForegroundColor = visible ? EditorPalette.accent : UIColor.white.withAlphaComponent(0.72)
        if visible {
            inspector.transform = CGAffineTransform(scaleX: 0.92, y: 0.92).translatedBy(x: 0, y: -8)
        }
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.4,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.inspector.alpha = visible ? 1 : 0
            self.inspector.transform = visible
                ? .identity
                : CGAffineTransform(scaleX: 0.92, y: 0.92).translatedBy(x: 0, y: -8)
        }
    }

    private func updateHistoryButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        resetButton.isEnabled = canvas.hasEdits
    }

    private func updateTimelineMetadata() {
        timeline.duration = canvas.timelineDuration
        timeline.strokeSegments = canvas.timelineSegments
        timeline.progress = 1
        canvas.setPlaybackProgress(1)
    }

    @objc private func showOriginal() {
        canvas.setOriginalPreviewVisible(true)
    }

    @objc private func restoreDeformation() {
        canvas.setOriginalPreviewVisible(false)
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback(resetToEnd: false)
        } else {
            let startProgress: Float = timeline.progress >= 1 ? 0 : timeline.progress
            isPlaying = true
            playbackOriginProgress = startProgress
            timeline.progress = startProgress
            canvas.setPlaybackProgress(startProgress)
            playbackStart = nil
            playButton.configuration?.image = UIImage(systemName: "pause.fill")
            playButton.accessibilityLabel = "Pause deformation"
        }
    }

    private func stopPlayback(resetToEnd: Bool) {
        isPlaying = false
        playbackStart = nil
        playButton.configuration?.image = UIImage(systemName: "play.fill")
        playButton.accessibilityLabel = "Play deformation"
        if resetToEnd {
            timeline.progress = 1
            canvas.setPlaybackProgress(1)
        }
    }

    // MARK: - Performance metrics

    @objc private func frameTick(_ link: CADisplayLink) {
        if lastFrameTimestamp > 0 {
            sampledFrameTimes.append(link.timestamp - lastFrameTimestamp)
        }
        lastFrameTimestamp = link.timestamp

        if isPlaying {
            if playbackStart == nil { playbackStart = link.timestamp }
            let elapsed = link.timestamp - (playbackStart ?? link.timestamp)
            let progress = playbackOriginProgress +
                Float(elapsed) / max(LiquifyConfiguration.Timeline.minimumDuration, canvas.timelineDuration)
            if progress >= 1 {
                timeline.progress = 1
                canvas.setPlaybackProgress(1)
                stopPlayback(resetToEnd: false)
            } else {
                timeline.progress = progress
                canvas.setPlaybackProgress(progress)
            }
        }

        if link.timestamp - lastMetricsTimestamp >= LiquifyConfiguration.Interface.performanceUpdateInterval,
           !sampledFrameTimes.isEmpty {
            let average = sampledFrameTimes.reduce(0, +) / Double(sampledFrameTimes.count)
            let fps = Int((1 / average).rounded())
            performanceLabel.text = "\(fps) fps  ·  \(String(format: "%.1f", average * 1000)) ms  ·  \(String(format: "%.1f", canvas.textureMemoryMegabytes)) MB"
            sampledFrameTimes.removeAll(keepingCapacity: true)
            lastMetricsTimestamp = link.timestamp
        }
    }

    // MARK: - Image import

    private func presentImagePicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                self?.stopPlayback(resetToEnd: true)
                self?.canvas.setSourceImage(image)
            }
        }
    }
}
