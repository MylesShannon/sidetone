import Foundation

/// Applies gain with a short ramp so slider moves and mute do not click.
public struct GainStage: Sendable {
	private var current: Float = 0
	private var coefficient: Float = 0.001

	public init() {}

	public mutating func prepare(sampleRate: Double, startingAt linear: Float) {
		// ~10 ms one-pole ramp: fast enough to feel instant, slow enough to be silent.
		coefficient = Float(1 - exp(-1 / (0.010 * max(1, sampleRate))))
		current = linear
	}

	public mutating func process(
		_ buffer: UnsafeMutablePointer<Float>,
		frames: Int,
		channels: Int,
		target: Float
	) {
		for frame in 0 ..< frames {
			current += (target - current) * coefficient
			for channel in 0 ..< channels {
				buffer[frame * channels + channel] *= current
			}
		}
	}
}
