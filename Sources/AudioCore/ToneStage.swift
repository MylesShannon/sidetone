import Foundation

/// Low cut, bass and treble, in that order, for one or two channels.
///
/// Runs on the capture thread, so it allocates nothing and holds no locks. New
/// coefficients are worked out here rather than handed in, but only when a control
/// has actually moved: the arithmetic is a handful of trigonometric calls, bounded and
/// rare, which is cheaper than the machinery it would take to pass a struct across
/// threads safely.
public struct ToneStage: Sendable {
	/// Where the low cut sits by default. Below this is rumble, handling noise and the
	/// thump of a console fan, none of which belongs in headphones.
	public static let defaultCutFrequency: Double = 80
	/// Far enough down to be inaudible at one end, far enough up to thin out a voice
	/// at the other.
	public static let cutRange: ClosedRange<Double> = 20 ... 200
	/// High enough to cover what people mean by bass. A shelf down at 120 Hz is a
	/// textbook bass control and nearly inaudible in practice: most of its lift lands
	/// below where headphones and laptop speakers give up.
	public static let bassFrequency: Double = 250
	public static let trebleFrequency: Double = 6000
	/// How far the shelves reach, in either direction.
	public static let range: Double = 12

	private struct Channel {
		var cut = Biquad()
		var bass = Biquad()
		var treble = Biquad()

		mutating func run(_ sample: Float) -> Float {
			treble.process(bass.process(cut.process(sample)))
		}

		mutating func reset() {
			cut.reset()
			bass.reset()
			treble.reset()
		}
	}

	private var left = Channel()
	private var right = Channel()

	private var sampleRate: Double = 48000
	private var lowCut = false
	private var cutHertz = ToneStage.defaultCutFrequency
	private var bass: Double = 0
	private var treble: Double = 0

	public init() {}

	public mutating func prepare(sampleRate: Double) {
		self.sampleRate = max(1, sampleRate)
		left.reset()
		right.reset()
		recompute()
	}

	/// True when every control sits at neutral, which lets the caller skip the stage
	/// altogether rather than running samples through three bypassed sections.
	public var isFlat: Bool {
		!lowCut && bass == 0 && treble == 0
	}

	public mutating func process(
		_ buffer: UnsafeMutablePointer<Float>,
		frames: Int,
		channels: Int,
		lowCut: Bool,
		cutHertz: Double,
		bassDecibels: Double,
		trebleDecibels: Double
	) {
		if lowCut != self.lowCut
			|| cutHertz != self.cutHertz
			|| bassDecibels != bass
			|| trebleDecibels != treble {
			self.lowCut = lowCut
			self.cutHertz = cutHertz
			bass = bassDecibels
			treble = trebleDecibels
			recompute()
		}

		guard !isFlat else { return }

		for frame in 0 ..< frames {
			for channel in 0 ..< channels {
				let index = frame * channels + channel
				// Only ever one or two channels arrive, since a monitored input is
				// either a single channel or a pair.
				buffer[index] = channel == 0
					? left.run(buffer[index])
					: right.run(buffer[index])
			}
		}
	}

	private mutating func recompute() {
		let cut = lowCut
			? Biquad.Coefficients.highPass(frequency: cutHertz, sampleRate: sampleRate)
			: .bypass
		let low = Biquad.Coefficients.lowShelf(
			frequency: Self.bassFrequency, decibels: bass, sampleRate: sampleRate
		)
		let high = Biquad.Coefficients.highShelf(
			frequency: Self.trebleFrequency, decibels: treble, sampleRate: sampleRate
		)

		left.cut.coefficients = cut
		left.bass.coefficients = low
		left.treble.coefficients = high
		right.cut.coefficients = cut
		right.bass.coefficients = low
		right.treble.coefficients = high
	}
}
