import Foundation

/// Builds the UI snapshot on a timer, off both audio threads.
///
/// Metering and the FFT run here rather than in the capture callback so a slow
/// frame can never turn into a dropout.
public final class AnalysisRunner: @unchecked Sendable {
	private let analysisRing: RingBuffer
	private let processor: CaptureProcessor
	private let puller: PlaybackPuller
	private let snapshotBox: SnapshotBox
	private let spectrum: SpectrumAnalyzer
	private let meter = LevelMeter()
	private let sampleRate: Double

	private let windowFrames: Int
	private let scratch: UnsafeMutablePointer<Float>
	private var ballistics = MeterBallistics()
	private var lastClipCount = 0
	private var clipHoldTicks = 0

	/// Roughly a second at the analysis tick rate, long enough to notice a clip.
	private let clipHoldDuration = 60

	public init(
		analysisRing: RingBuffer,
		processor: CaptureProcessor,
		puller: PlaybackPuller,
		snapshotBox: SnapshotBox,
		spectrum: SpectrumAnalyzer,
		sampleRate: Double
	) {
		self.analysisRing = analysisRing
		self.processor = processor
		self.puller = puller
		self.snapshotBox = snapshotBox
		self.spectrum = spectrum
		self.sampleRate = sampleRate
		windowFrames = spectrum.fftSize
		scratch = .allocate(capacity: windowFrames)
		scratch.initialize(repeating: 0, count: windowFrames)
	}

	deinit {
		scratch.deinitialize(count: windowFrames)
		scratch.deallocate()
	}

	public func tick() {
		var snapshot = AudioSnapshot()

		analysisRing.keepNewest(windowFrames)
		let read = analysisRing.read(into: scratch, frames: windowFrames)

		if read > 0 {
			let reading = meter.analyze(scratch, count: read)
			ballistics.update(reading.peak)
			snapshot.rms = reading.rms
			snapshot.bands = spectrum.process(scratch, count: read, sampleRate: sampleRate)
		} else {
			ballistics.update(0)
			snapshot.bands = spectrum.process(scratch, count: 0, sampleRate: sampleRate)
		}

		snapshot.peak = ballistics.level

		let clips = processor.clipCount.load(ordering: .relaxed)
		if clips > lastClipCount {
			lastClipCount = clips
			clipHoldTicks = clipHoldDuration
		} else if clipHoldTicks > 0 {
			clipHoldTicks -= 1
		}
		snapshot.clipping = clipHoldTicks > 0

		snapshot.limiterReductionDecibels = Double(processor.limiterReduction.value)
		snapshot.underruns = puller.underruns
		snapshot.overruns = processor.playbackRing.overruns
		snapshot.bufferFillFrames = puller.currentFillFrames

		snapshotBox.write(snapshot)
	}
}
