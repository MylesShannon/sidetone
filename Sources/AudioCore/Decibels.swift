import Foundation

public enum Decibels {
	/// At or below this the signal is treated as silence rather than a tiny number.
	public static let floor: Double = -60

	public static func toLinear(_ db: Double) -> Double {
		db <= floor ? 0 : pow(10, db / 20)
	}

	public static func fromLinear(_ linear: Double) -> Double {
		linear <= 0 ? floor : max(floor, 20 * log10(linear))
	}

	public static func fromLinear(_ linear: Float) -> Double {
		fromLinear(Double(linear))
	}

	public static func format(_ db: Double) -> String {
		db <= floor ? "-inf dB" : String(format: "%+.1f dB", db)
	}
}
