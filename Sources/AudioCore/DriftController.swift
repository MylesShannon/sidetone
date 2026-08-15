/// Keeps the ring buffer near a target fill level when capture and playback run
/// off different clocks.
///
/// Two devices nominally at 48 kHz still drift by tens of parts per million, which
/// empties or floods a fixed buffer within minutes. The controller answers with a
/// small correction to the playback read rate: a proportional term for immediate
/// error and an integral term that absorbs the constant clock offset.
public struct DriftController: Sendable {
	/// Fill level, in frames, the controller steers toward.
	public var targetFrames: Double
	/// Largest rate change allowed, as a fraction. Half a percent is far below
	/// where pitch change becomes audible on speech.
	public let maxCorrection: Double

	private let proportionalGain: Double
	private let integralGain: Double
	private var integral: Double = 0

	public init(targetFrames: Double, maxCorrection: Double = 0.005) {
		self.targetFrames = targetFrames
		self.maxCorrection = maxCorrection
		proportionalGain = 2e-5
		integralGain = 2e-7
	}

	/// Returns the multiplier for the nominal read rate. Above 1 reads faster, to
	/// drain a buffer that is filling up.
	public mutating func update(fillFrames: Double) -> Double {
		let error = fillFrames - targetFrames
		integral = (integral + error * integralGain).clamped(to: -maxCorrection ... maxCorrection)
		let correction = (error * proportionalGain + integral)
			.clamped(to: -maxCorrection ... maxCorrection)
		return 1 + correction
	}

	public mutating func reset() {
		integral = 0
	}
}

public extension Double {
	func clamped(to range: ClosedRange<Double>) -> Double {
		min(max(self, range.lowerBound), range.upperBound)
	}
}

public extension Float {
	func clamped(to range: ClosedRange<Float>) -> Float {
		min(max(self, range.lowerBound), range.upperBound)
	}
}
