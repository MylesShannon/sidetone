import Foundation

/// Catches runaway levels before they reach your ears.
///
/// This is not a mastering limiter. Its only job is to make a feedback squeal or a
/// mis-set gain unpleasant rather than harmful, so it stays out of the way until
/// the signal exceeds the ceiling.
public struct SafetyLimiter: Sendable {
	/// -1 dBFS, leaving room for the output device's own conversion.
	public static let ceiling: Float = 0.891

	private var envelope: Float = 1
	private var attack: Float = 0.2
	private var release: Float = 0.0005

	public init() {}

	public mutating func prepare(sampleRate: Double) {
		let rate = Float(max(1, sampleRate))
		attack = 1 - exp(-1 / (0.001 * rate))
		release = 1 - exp(-1 / (0.150 * rate))
		envelope = 1
	}

	public mutating func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
		for frame in 0 ..< frames {
			var peak: Float = 0
			for channel in 0 ..< channels {
				peak = max(peak, abs(buffer[frame * channels + channel]))
			}

			let wanted = peak > Self.ceiling ? Self.ceiling / peak : 1
			let coefficient = wanted < envelope ? attack : release
			envelope += (wanted - envelope) * coefficient

			for channel in 0 ..< channels {
				buffer[frame * channels + channel] *= envelope
			}
		}
	}

	/// How much the limiter is pulling down right now, in dB. Zero means inactive.
	public var reductionDecibels: Double {
		envelope >= 1 ? 0 : Decibels.fromLinear(envelope)
	}
}
