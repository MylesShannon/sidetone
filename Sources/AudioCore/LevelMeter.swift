import Accelerate

/// Peak and RMS for a block of samples, plus clip detection.
public struct LevelMeter: Sendable {
	/// Digital full scale, with a hair of tolerance for conversion rounding.
	public static let clipThreshold: Float = 0.999

	public struct Reading: Sendable, Equatable {
		public var peak: Float
		public var rms: Float
		public var clipped: Bool
	}

	public init() {}

	public func analyze(_ samples: UnsafePointer<Float>, count: Int) -> Reading {
		guard count > 0 else { return Reading(peak: 0, rms: 0, clipped: false) }
		var peak: Float = 0
		var rms: Float = 0
		vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
		vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
		return Reading(peak: peak, rms: rms, clipped: peak >= Self.clipThreshold)
	}

	public func analyze(_ samples: [Float]) -> Reading {
		samples.withUnsafeBufferPointer { buffer in
			guard let base = buffer.baseAddress else {
				return Reading(peak: 0, rms: 0, clipped: false)
			}
			return analyze(base, count: buffer.count)
		}
	}
}

/// Smooths a meter for display: instant rise, gentle fall, and a peak marker that
/// hangs long enough to read.
public struct MeterBallistics: Sendable {
	public private(set) var level: Float = 0
	public private(set) var peakHold: Float = 0

	private var holdFramesRemaining: Int = 0
	private let holdFrames: Int
	private let fallPerFrame: Float

	public init(holdFrames: Int = 30, fallPerFrame: Float = 0.03) {
		self.holdFrames = holdFrames
		self.fallPerFrame = fallPerFrame
	}

	public mutating func update(_ value: Float) {
		level = value > level ? value : max(0, level - fallPerFrame)

		if value >= peakHold {
			peakHold = value
			holdFramesRemaining = holdFrames
		} else if holdFramesRemaining > 0 {
			holdFramesRemaining -= 1
		} else {
			peakHold = max(level, peakHold - fallPerFrame)
		}
	}

	public mutating func reset() {
		level = 0
		peakHold = 0
		holdFramesRemaining = 0
	}
}
