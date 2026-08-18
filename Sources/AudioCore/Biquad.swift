import Foundation

/// One second-order section, carrying its own history for a single channel.
///
/// Coefficients come from the Audio EQ Cookbook, normalised so `a0` is one. State is
/// four scalars, so a section costs nothing to hold and nothing to run.
public struct Biquad: Sendable {
	public struct Coefficients: Sendable, Equatable {
		public var b0: Float
		public var b1: Float
		public var b2: Float
		public var a1: Float
		public var a2: Float

		/// Passes everything through untouched.
		public static let bypass = Coefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

		public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
			self.b0 = b0
			self.b1 = b1
			self.b2 = b2
			self.a1 = a1
			self.a2 = a2
		}

		/// Rolls off below `frequency` at twelve decibels an octave.
		public static func highPass(frequency: Double, sampleRate: Double) -> Coefficients {
			let omega = angularFrequency(frequency, sampleRate)
			let alpha = sin(omega) / (2 * 0.707)
			let cosine = cos(omega)
			let a0 = 1 + alpha
			return Coefficients(
				b0: Float((1 + cosine) / 2 / a0),
				b1: Float(-(1 + cosine) / a0),
				b2: Float((1 + cosine) / 2 / a0),
				a1: Float(-2 * cosine / a0),
				a2: Float((1 - alpha) / a0)
			)
		}

		/// Lifts or drops everything below `frequency`, levelling off at `decibels`.
		public static func lowShelf(frequency: Double, decibels: Double, sampleRate: Double) -> Coefficients {
			shelf(frequency: frequency, decibels: decibels, sampleRate: sampleRate, low: true)
		}

		/// Lifts or drops everything above `frequency`, levelling off at `decibels`.
		public static func highShelf(frequency: Double, decibels: Double, sampleRate: Double) -> Coefficients {
			shelf(frequency: frequency, decibels: decibels, sampleRate: sampleRate, low: false)
		}

		private static func shelf(
			frequency: Double, decibels: Double, sampleRate: Double, low: Bool
		) -> Coefficients {
			guard decibels != 0 else { return bypass }
			let amplitude = pow(10, decibels / 40)
			let omega = angularFrequency(frequency, sampleRate)
			let cosine = cos(omega)
			// Shelf slope of one, which reaches the set gain without overshooting on
			// the way there.
			let alpha = sin(omega) / 2 * sqrt(2)
			let beta = 2 * sqrt(amplitude) * alpha
			let plus = amplitude + 1
			let minus = amplitude - 1
			let sign: Double = low ? 1 : -1

			let a0 = plus + sign * minus * cosine + beta
			return Coefficients(
				b0: Float(amplitude * (plus - sign * minus * cosine + beta) / a0),
				b1: Float(sign * 2 * amplitude * (minus - sign * plus * cosine) / a0),
				b2: Float(amplitude * (plus - sign * minus * cosine - beta) / a0),
				a1: Float(sign * -2 * (minus + sign * plus * cosine) / a0),
				a2: Float((plus + sign * minus * cosine - beta) / a0)
			)
		}

		/// Clamped below Nyquist, because a corner at or above it produces
		/// coefficients that make the filter blow up rather than merely sound wrong.
		private static func angularFrequency(_ frequency: Double, _ sampleRate: Double) -> Double {
			let rate = max(1, sampleRate)
			let bounded = min(max(frequency, 1), rate * 0.45)
			return 2 * .pi * bounded / rate
		}
	}

	public var coefficients: Coefficients = .bypass

	private var x1: Float = 0
	private var x2: Float = 0
	private var y1: Float = 0
	private var y2: Float = 0

	public init() {}

	public mutating func reset() {
		x1 = 0
		x2 = 0
		y1 = 0
		y2 = 0
	}

	public mutating func process(_ sample: Float) -> Float {
		let output = coefficients.b0 * sample
			+ coefficients.b1 * x1
			+ coefficients.b2 * x2
			- coefficients.a1 * y1
			- coefficients.a2 * y2

		x2 = x1
		x1 = sample
		y2 = y1
		y1 = output
		return output
	}
}
