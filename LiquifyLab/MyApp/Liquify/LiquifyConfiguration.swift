import CoreGraphics

/// Centralized interaction and rendering constants.
///
/// These values are deliberately kept together because they define the feel and
/// performance envelope of the prototype. Keeping them out of view/controller
/// code makes profiling experiments easy to review and prevents default values
/// from drifting between UI and rendering layers
enum LiquifyConfiguration {
    enum DisplacementField {
        /// A fixed, image independent field keeps GPU memory and history rebuilds bounded
        static let resolution = 320
    }

    enum Timeline {
        static let minimumDuration: Float = 0.5
        static let interStrokeGap: Float = 0.12
        static let accessibilityScrubStep: Float = 0.05
        static let minimumVisibleClipWidth: CGFloat = 8
        /// Absorbs floating point rounding when comparing the playhead with the timeline end
        static let endComparisonTolerance: Float = 0.0001
    }

    enum Brush {
        static let diameter: CGFloat = 112
        static let strength: Float = 0.62
    }

    enum Input {
        static let minimumMovement: CGFloat = 0.25
        static let minimumSampleSpacing: CGFloat = 2
        static let sampleSpacingRatio: CGFloat = 0.055
        /// A comfortable full strength force that avoids requiring maximum physical pressure
        static let pencilForceNormalizationCap: CGFloat = 1.7
        static let fingerPressure: Float = 0.72
        static let imageEdgeHitSlop: CGFloat = 2
        /// Keeps diagnostic values legible without reducing the rate used for rendering
        static let metricsDisplayInterval: CFTimeInterval = 1.0 / 15.0
        static var metricsDisplayRate: Int {
            Int((1.0 / metricsDisplayInterval).rounded())
        }
    }

    enum History {
        /// Bounds retained snapshots while preserving a practical undo depth for the prototype
        static let maximumUndoDepth = 50
    }

    enum Interface {
        static let compactMetricsWidth: CGFloat = 900
        static let performanceUpdateInterval: CFTimeInterval = 0.5
    }
}
