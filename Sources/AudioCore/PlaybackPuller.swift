import CoreAudio
import Synchronization

/// Fills the output render callback from the ring buffer, resampling as it goes.
///
/// The resampling ratio is the nominal rate ratio between the two devices times a
/// correction from the drift controller, which is what lets a 44.1 kHz output
/// follow a 48 kHz input indefinitely without the buffer emptying or overflowing.
public final class PlaybackPuller: @unchecked Sendable {
	private let ring: RingBuffer
	private let baseRatio: Double
	private let targetFillFrames: Double
	private var drift: DriftController
	/// Read position in frames from the ring's read index. Held at or above 1 so
	/// the interpolator always has a sample behind it.
	private var position: Double = 1
	/// Playback is started before capture, and opening an input device takes long
	/// enough to matter, so the first callbacks run against an empty ring. Staying
	/// silent until the ring reaches its target keeps that startup gap out of the
	/// dropout count and gives playback its intended cushion from the first frame.
	private var primed = false

	private let underrunCount = Atomic<Int>(0)
	private let fillFrames = Atomic<Int>(0)

	public init(ring: RingBuffer, inputSampleRate: Double, outputSampleRate: Double, targetFillFrames: Double) {
		self.ring = ring
		self.targetFillFrames = targetFillFrames
		baseRatio = inputSampleRate / max(1, outputSampleRate)
		drift = DriftController(targetFrames: targetFillFrames)
	}

	public var underruns: Int { underrunCount.load(ordering: .relaxed) }
	public var currentFillFrames: Int { fillFrames.load(ordering: .relaxed) }

	public func render(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
		let available = ring.availableFrames
		fillFrames.store(available, ordering: .relaxed)

		if !primed {
			// The drift controller is left alone until there is a real fill level to
			// steer, so it does not wind up against an empty ring.
			guard Double(available) >= targetFillFrames else {
				silence(buffers, frames: frames)
				return
			}
			primed = true
		}

		let ratio = baseRatio * drift.update(fillFrames: Double(available))
		let needed = Int(position + Double(frames) * ratio) + 3

		guard available >= needed else {
			underrunCount.wrappingAdd(1, ordering: .relaxed)
			silence(buffers, frames: frames)
			return
		}

		var endPosition = position
		for (index, buffer) in buffers.enumerated() {
			guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
			let sourceChannel = min(index, ring.channels - 1)
			var cursor = position

			for frame in 0 ..< frames {
				let base = Int(cursor)
				let t = Float(cursor - Double(base))
				let p0 = ring.sample(frameOffset: base - 1, channel: sourceChannel)
				let p1 = ring.sample(frameOffset: base, channel: sourceChannel)
				let p2 = ring.sample(frameOffset: base + 1, channel: sourceChannel)
				let p3 = ring.sample(frameOffset: base + 2, channel: sourceChannel)
				data[frame] = catmullRom(p0, p1, p2, p3, t)
				cursor += ratio
			}
			endPosition = cursor
		}

		position = endPosition
		let consumed = Int(position) - 1
		if consumed > 0 {
			ring.advanceRead(frames: consumed)
			position -= Double(consumed)
		}
	}

	public func reset() {
		position = 1
		primed = false
		drift.reset()
		underrunCount.store(0, ordering: .relaxed)
	}

	@inline(__always)
	private func silence(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
		for buffer in buffers {
			if let data = buffer.mData {
				data.initializeMemory(as: Float.self, repeating: 0, count: frames)
			}
		}
	}
}

/// Catmull-Rom interpolation. Cheap enough for the render thread and clean enough
/// that resampling does not add audible grit the way linear interpolation does.
@inline(__always)
public func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
	let a = 2 * p1
	let b = p2 - p0
	let c = 2 * p0 - 5 * p1 + 4 * p2 - p3
	let d = -p0 + 3 * p1 - 3 * p2 + p3
	return 0.5 * (a + b * t + c * t * t + d * t * t * t)
}
