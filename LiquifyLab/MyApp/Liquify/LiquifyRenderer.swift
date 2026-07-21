import MetalKit
import UIKit

/// A single, pressure adjusted displacement sample in normalized image space.
///
/// Keep this memory layout synchronized with `BrushStamp` in
/// `LiquifyShaders.metal`; instances are copied directly into an `MTLBuffer`
struct LiquifyBrushStamp {
    var location: SIMD2<Float>
    var delta: SIMD2<Float>
    var radius: Float
    var strength: Float
    var timelineTime: Float
}

/// Chooses the smallest read/write representation supported by the active GPU.
/// Tier 2 packs XY into one half-float texture; tier 1 uses two baseline R32 textures
private enum DisplacementStorage {
    case tier1(x: MTLTexture, y: MTLTexture)
    case tier2(MTLTexture)

    var textures: [MTLTexture] {
        switch self {
        case let .tier1(x, y): [x, y]
        case let .tier2(texture): [texture]
        }
    }

    var primaryTexture: MTLTexture { textures[0] }

    var byteCount: Int {
        switch self {
        case let .tier1(x, y):
            (x.width * x.height * 4) + (y.width * y.height * 4)
        case let .tier2(texture):
            texture.width * texture.height * 8
        }
    }
}

/// Retains only the most recent states so snapshot based undo cant grow unbounded
private struct HistoryStack<State> {
    private let capacity: Int
    private var states: [State] = []

    var isEmpty: Bool { states.isEmpty }

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func append(_ state: State) {
        states.append(state)
        if states.count > capacity {
            states.removeFirst(states.count - capacity)
        }
    }

    mutating func popLast() -> State? {
        states.popLast()
    }

    mutating func removeAll() {
        states.removeAll(keepingCapacity: true)
    }
}

final class LiquifyRenderer: NSObject, MTKViewDelegate {
    /// Full snapshots make resets and timeline branches easy to undo in one step. Since
    /// committed strokes don't change, Swift's copy-on-write arrays share their stamp storage
    private typealias EditState = [[LiquifyBrushStamp]]

    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let brushPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader
    private let displacementStorage: DisplacementStorage

    private var sourceTexture: MTLTexture?
    private var committedStrokes: [[LiquifyBrushStamp]] = []
    private var undoStates = HistoryStack<EditState>(
        capacity: LiquifyConfiguration.History.maximumUndoDepth
    )
    private var redoStates = HistoryStack<EditState>(
        capacity: LiquifyConfiguration.History.maximumUndoDepth
    )
    private var activeStroke: [LiquifyBrushStamp] = []
    private var pendingStrokeBaseState: EditState?
    private var pendingStrokePlaybackTime: Float = 0
    private var pendingStrokeTrimmedFuture = false
    private var playbackStampIndex = 0
    private var playbackTime: Float = 0

    var comparisonMix: Float = 1
    var onHistoryChanged: (() -> Void)?

    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    var hasEdits: Bool { !committedStrokes.isEmpty || !activeStroke.isEmpty }

    private var allTimelineStamps: [LiquifyBrushStamp] { committedStrokes.flatMap { $0 } }
    private var recordedDuration: Float { committedStrokes.last?.last?.timelineTime ?? 0 }
    var timelineDuration: Float { max(LiquifyConfiguration.Timeline.minimumDuration, recordedDuration) }
    var normalizedStrokeSegments: [ClosedRange<Float>] {
        let duration = timelineDuration
        return committedStrokes.compactMap { stroke in
            guard let first = stroke.first, let last = stroke.last else { return nil }
            return (first.timelineTime / duration)...(last.timelineTime / duration)
        }
    }

    var estimatedTextureMemoryMegabytes: Double {
        let sourceBytes = (sourceTexture?.width ?? 0) * (sourceTexture?.height ?? 0) * 4
        return Double(sourceBytes + displacementStorage.byteCount) / 1_048_576
    }

    // MARK: - GPU setup

    init?(metalView: MTKView) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "canvasVertex") else {
            return nil
        }

        let fragmentFunctionName: String
        let brushFunctionName: String
        let clearFunctionName: String

        switch device.readWriteTextureSupport {
        case .tier2:
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: LiquifyConfiguration.DisplacementField.resolution,
                height: LiquifyConfiguration.DisplacementField.resolution,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "Tier 2 packed displacement field"
            displacementStorage = .tier2(texture)
            fragmentFunctionName = "liquifyFragmentTier2"
            brushFunctionName = "applyLiquifyBrushTier2"
            clearFunctionName = "clearDisplacementTier2"

        case .tier1:
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: LiquifyConfiguration.DisplacementField.resolution,
                height: LiquifyConfiguration.DisplacementField.resolution,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let xTexture = device.makeTexture(descriptor: descriptor),
                  let yTexture = device.makeTexture(descriptor: descriptor) else { return nil }
            xTexture.label = "Tier 1 horizontal displacement"
            yTexture.label = "Tier 1 vertical displacement"
            displacementStorage = .tier1(x: xTexture, y: yTexture)
            fragmentFunctionName = "liquifyFragmentTier1"
            brushFunctionName = "applyLiquifyBrushTier1"
            clearFunctionName = "clearDisplacementTier1"

        default:
            assertionFailure("Liquify Lab requires Metal read-write texture support")
            return nil
        }

        guard let fragmentFunction = library.makeFunction(name: fragmentFunctionName),
              let brushFunction = library.makeFunction(name: brushFunctionName),
              let clearFunction = library.makeFunction(name: clearFunctionName) else {
            return nil
        }

        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.label = "Liquify canvas"
        renderDescriptor.vertexFunction = vertexFunction
        renderDescriptor.fragmentFunction = fragmentFunction
        renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
            brushPipeline = try device.makeComputePipelineState(function: brushFunction)
            clearPipeline = try device.makeComputePipelineState(function: clearFunction)
        } catch {
            assertionFailure("Unable to create Metal pipelines: \(error)")
            return nil
        }

        commandQueue = queue
        textureLoader = MTKTextureLoader(device: device)
        super.init()

        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.clearColor = MTLClearColorMake(0.035, 0.039, 0.047, 1)
        metalView.preferredFramesPerSecond = 120
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.delegate = self

        clearDisplacement()
    }

    // MARK: - Source image and coordinates

    func setSourceImage(_ image: UIImage) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalizedImage = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        guard let cgImage = normalizedImage.cgImage else { return }
        do {
            sourceTexture = try textureLoader.newTexture(
                cgImage: cgImage,
                options: [.SRGB: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
            )
            discardAllEdits()
        } catch {
            assertionFailure("Unable to load source texture: \(error)")
        }
    }

    func imageContentRect(in viewSize: CGSize) -> CGRect {
        guard let sourceTexture, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let imageAspect = CGFloat(sourceTexture.width) / CGFloat(sourceTexture.height)
        let viewAspect = viewSize.width / viewSize.height

        if viewAspect > imageAspect {
            let width = viewSize.height * imageAspect
            return CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: viewSize.height)
        } else {
            let height = viewSize.width / imageAspect
            return CGRect(x: 0, y: (viewSize.height - height) / 2, width: viewSize.width, height: height)
        }
    }

    func imagePoint(for point: CGPoint, in viewSize: CGSize) -> SIMD2<Float>? {
        let rect = imageContentRect(in: viewSize)
        let hitSlop = LiquifyConfiguration.Input.imageEdgeHitSlop
        guard rect.width > 0, rect.height > 0, rect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) else { return nil }
        return SIMD2(
            Float((point.x - rect.minX) / rect.width),
            Float((point.y - rect.minY) / rect.height)
        )
    }

    func normalizedRadius(for pointRadius: CGFloat, in viewSize: CGSize) -> Float {
        let rect = imageContentRect(in: viewSize)
        return Float(pointRadius / max(1, min(rect.width, rect.height)))
    }

    // MARK: - History and timeline

    /// Starts a history transaction and returns the new stroke's timeline origin.
    /// Editing before the end trims future stamps; cancelling restores the previous timeline
    func beginStroke() -> Float {
        let stampsBeforeEditing = allTimelineStamps
        let selectedTime = playbackTime
        let isAtTimelineEnd =
            playbackStampIndex == stampsBeforeEditing.count &&
            selectedTime >= timelineDuration - LiquifyConfiguration.Timeline.endComparisonTolerance

        pendingStrokeBaseState = committedStrokes
        pendingStrokePlaybackTime = selectedTime
        pendingStrokeTrimmedFuture = playbackStampIndex < stampsBeforeEditing.count

        if pendingStrokeTrimmedFuture {
            committedStrokes = committedStrokes.compactMap { stroke in
                let retained = stroke.prefix { $0.timelineTime <= selectedTime }
                return retained.isEmpty ? nil : Array(retained)
            }
            playbackStampIndex = allTimelineStamps.count
        }

        comparisonMix = 1
        activeStroke.removeAll(keepingCapacity: true)

        if isAtTimelineEnd {
            return committedStrokes.isEmpty
                ? 0
                : recordedDuration + LiquifyConfiguration.Timeline.interStrokeGap
        }
        return selectedTime
    }

    func append(stamps: [LiquifyBrushStamp]) {
        guard !stamps.isEmpty else { return }
        activeStroke.append(contentsOf: stamps)
        encode(stamps: stamps)
    }

    func endStroke() {
        guard !activeStroke.isEmpty else {
            if pendingStrokeTrimmedFuture {
                restorePendingStrokeBaseState()
            } else {
                clearPendingStrokeState()
            }
            return
        }

        undoStates.append(pendingStrokeBaseState ?? committedStrokes)
        committedStrokes.append(activeStroke)
        activeStroke.removeAll(keepingCapacity: true)
        redoStates.removeAll()
        clearPendingStrokeState()
        playbackStampIndex = allTimelineStamps.count
        playbackTime = timelineDuration
        onHistoryChanged?()
    }

    func cancelStroke() {
        guard pendingStrokeBaseState != nil || !activeStroke.isEmpty else { return }
        restorePendingStrokeBaseState()
    }

    func undo() {
        guard let previousState = undoStates.popLast() else { return }
        redoStates.append(committedStrokes)
        committedStrokes = previousState
        activeStroke.removeAll()
        clearPendingStrokeState()
        rebuildDisplacement()
        onHistoryChanged?()
    }

    func redo() {
        guard let nextState = redoStates.popLast() else { return }
        undoStates.append(committedStrokes)
        committedStrokes = nextState
        activeStroke.removeAll()
        clearPendingStrokeState()
        rebuildDisplacement()
        onHistoryChanged?()
    }

    func reset() {
        guard hasEdits else { return }
        undoStates.append(pendingStrokeBaseState ?? committedStrokes)
        redoStates.removeAll()
        committedStrokes.removeAll()
        activeStroke.removeAll()
        clearPendingStrokeState()
        playbackStampIndex = 0
        playbackTime = 0
        comparisonMix = 1
        clearDisplacement()
        onHistoryChanged?()
    }

    /// Reconstructs the displacement field at a normalized playhead position.
    /// Forward playback encodes only newly reached stamps; backward scrubbing clears and replays
    func seekTimeline(to progress: Float) {
        let clampedProgress = min(1, max(0, progress))
        let targetTime = clampedProgress * timelineDuration
        let stamps = allTimelineStamps

        if targetTime < playbackTime || playbackStampIndex > stamps.count {
            clearDisplacement()
            playbackStampIndex = 0
        }

        let startIndex = playbackStampIndex
        var endIndex = startIndex
        while clampedProgress > 0, endIndex < stamps.count, stamps[endIndex].timelineTime <= targetTime {
            endIndex += 1
        }
        if endIndex > startIndex {
            encode(stamps: Array(stamps[startIndex..<endIndex]))
        }
        playbackStampIndex = endIndex
        playbackTime = targetTime
    }

    func setOriginalPreviewVisible(_ visible: Bool) {
        comparisonMix = visible ? 0 : 1
    }

    private func discardAllEdits() {
        committedStrokes.removeAll()
        undoStates.removeAll()
        redoStates.removeAll()
        activeStroke.removeAll()
        clearPendingStrokeState()
        playbackStampIndex = 0
        playbackTime = 0
        comparisonMix = 1
        clearDisplacement()
        onHistoryChanged?()
    }

    private func restorePendingStrokeBaseState() {
        let selectedTime = pendingStrokePlaybackTime
        if let baseState = pendingStrokeBaseState {
            committedStrokes = baseState
        }
        activeStroke.removeAll()
        clearPendingStrokeState()
        rebuildDisplacement(upTo: selectedTime)
    }

    private func clearPendingStrokeState() {
        pendingStrokeBaseState = nil
        pendingStrokePlaybackTime = 0
        pendingStrokeTrimmedFuture = false
    }

    // MARK: - GPU encoding

    private func clearDisplacement() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodeClear(on: commandBuffer)
        commandBuffer.commit()
    }

    private func rebuildDisplacement() {
        rebuildDisplacement(upTo: timelineDuration)
    }

    private func rebuildDisplacement(upTo targetTime: Float) {
        let stamps = allTimelineStamps
        var endIndex = 0
        while targetTime > 0,
              endIndex < stamps.count,
              stamps[endIndex].timelineTime <= targetTime {
            endIndex += 1
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodeClear(on: commandBuffer)
        if endIndex > 0 {
            encode(stamps: Array(stamps[..<endIndex]), on: commandBuffer)
        }
        commandBuffer.commit()
        playbackStampIndex = endIndex
        playbackTime = min(max(0, targetTime), timelineDuration)
        comparisonMix = 1
    }

    private func encode(stamps: [LiquifyBrushStamp]) {
        guard !stamps.isEmpty, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encode(stamps: stamps, on: commandBuffer)
        commandBuffer.commit()
    }

    private func encodeClear(on commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Clear displacement"
        encoder.setComputePipelineState(clearPipeline)
        bindDisplacementTextures(to: encoder)
        dispatch(texture: displacementStorage.primaryTexture, pipeline: clearPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func encode(stamps: [LiquifyBrushStamp], on commandBuffer: MTLCommandBuffer) {
        guard !stamps.isEmpty else { return }
        let bufferLength = stamps.count * MemoryLayout<LiquifyBrushStamp>.stride
        guard let stampBuffer = commandQueue.device.makeBuffer(length: bufferLength, options: .storageModeShared) else { return }
        stamps.withUnsafeBufferPointer { pointer in
            guard let source = pointer.baseAddress else { return }
            stampBuffer.contents().copyMemory(from: UnsafeRawPointer(source), byteCount: bufferLength)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var stampCount = UInt32(stamps.count)
        encoder.label = "Apply Pencil stroke batch"
        encoder.setComputePipelineState(brushPipeline)
        bindDisplacementTextures(to: encoder)
        encoder.setBuffer(stampBuffer, offset: 0, index: 0)
        encoder.setBytes(&stampCount, length: MemoryLayout<UInt32>.stride, index: 1)
        dispatch(texture: displacementStorage.primaryTexture, pipeline: brushPipeline, encoder: encoder)
        encoder.endEncoding()
    }

    private func bindDisplacementTextures(to encoder: MTLComputeCommandEncoder) {
        for (index, texture) in displacementStorage.textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
    }

    private func dispatch(texture: MTLTexture, pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + width - 1) / width,
            height: (texture.height + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let sourceTexture,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let imageAspect = Float(sourceTexture.width) / Float(sourceTexture.height)
        let viewAspect = Float(max(1, view.drawableSize.width)) / Float(max(1, view.drawableSize.height))
        var aspectScale = viewAspect > imageAspect
            ? SIMD2<Float>(imageAspect / viewAspect, 1)
            : SIMD2<Float>(1, viewAspect / imageAspect)
        var progress = comparisonMix

        encoder.label = "Render liquified image"
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        for (index, texture) in displacementStorage.textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index + 1)
        }
        encoder.setFragmentBytes(&progress, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
