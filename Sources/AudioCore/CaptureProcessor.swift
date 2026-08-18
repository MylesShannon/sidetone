import CoreAudio
import Synchronization

/// The capture-thread half of the signal path: pick the monitored channels, apply
/// gain, optionally limit, then hand the result to the playback ring and to a
/// separate ring for metering.
///
/// Everything here runs on a real-time thread. No allocation, no locks, no logging.
public final class CaptureProcessor: @unchecked Sendable {
	public let playbackRing: RingBuffer
	public let analysisRing: RingBuffer

	public let targetGain = AtomicFloat(1)
	public let lowCut = Atomic<Bool>(false)
	public let lowCutHertz = AtomicFloat(Float(ToneStage.defaultCutFrequency))
	public let bassDecibels = AtomicFloat(0)
	public let trebleDecibels = AtomicFloat(0)
	public let limiterEnabled = Atomic<Bool>(true)
	public let limiterReduction = AtomicFloat(0)
	public let clipCount = Atomic<Int>(0)

	private let channelIndices: [Int]
	private let maxFrames: Int
	private let scratch: UnsafeMutablePointer<Float>
	private let mono: UnsafeMutablePointer<Float>
	private var gain = GainStage()
	private var tone = ToneStage()
	private var limiter = SafetyLimiter()
	private let meter = LevelMeter()

	public init(
		playbackRing: RingBuffer,
		analysisRing: RingBuffer,
		channelIndices: [Int],
		maxFrames: Int,
		sampleRate: Double,
		initialGain: Float
	) {
		self.playbackRing = playbackRing
		self.analysisRing = analysisRing
		self.channelIndices = channelIndices
		self.maxFrames = maxFrames
		scratch = .allocate(capacity: maxFrames * max(1, channelIndices.count))
		scratch.initialize(repeating: 0, count: maxFrames * max(1, channelIndices.count))
		mono = .allocate(capacity: maxFrames)
		mono.initialize(repeating: 0, count: maxFrames)

		targetGain.value = initialGain
		gain.prepare(sampleRate: sampleRate, startingAt: initialGain)
		tone.prepare(sampleRate: sampleRate)
		limiter.prepare(sampleRate: sampleRate)
	}

	deinit {
		scratch.deinitialize(count: maxFrames * max(1, channelIndices.count))
		scratch.deallocate()
		mono.deinitialize(count: maxFrames)
		mono.deallocate()
	}

	/// `buffers` holds non-interleaved float channels straight from the input unit.
	public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
		let frames = min(frames, maxFrames)
		guard frames > 0, !buffers.isEmpty else { return }
		let channels = channelIndices.count

		for (slot, channel) in channelIndices.enumerated() {
			let source = buffers[min(channel, buffers.count - 1)]
			guard let data = source.mData?.assumingMemoryBound(to: Float.self) else { continue }
			for frame in 0 ..< frames {
				scratch[frame * channels + slot] = data[frame]
			}
		}

		gain.process(scratch, frames: frames, channels: channels, target: targetGain.value)

		// Before the limiter, so a treble lift cannot push the signal past the ceiling.
		tone.process(
			scratch,
			frames: frames,
			channels: channels,
			lowCut: lowCut.load(ordering: .relaxed),
			cutHertz: Double(lowCutHertz.value),
			bassDecibels: Double(bassDecibels.value),
			trebleDecibels: Double(trebleDecibels.value)
		)

		if limiterEnabled.load(ordering: .relaxed) {
			limiter.process(scratch, frames: frames, channels: channels)
			limiterReduction.value = Float(limiter.reductionDecibels)
		} else {
			limiterReduction.value = 0
		}

		let reading = meter.analyze(scratch, count: frames * channels)
		if reading.clipped {
			clipCount.wrappingAdd(1, ordering: .relaxed)
		}

		playbackRing.write(scratch, frames: frames)

		let inverse = 1 / Float(channels)
		for frame in 0 ..< frames {
			var sum: Float = 0
			for channel in 0 ..< channels {
				sum += scratch[frame * channels + channel]
			}
			mono[frame] = sum * inverse
		}
		analysisRing.write(mono, frames: frames)
	}
}
