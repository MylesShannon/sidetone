import AVFoundation
import AudioDevices
import Foundation
import Observation

public struct MonitorConfiguration: Sendable, Equatable {
	public var input: AudioDevice
	public var output: AudioDevice
	public var channelMode: InputChannelMode
	public var latency: LatencyProfile
	public var gainDecibels: Double
	public var muted: Bool
	public var safetyLimiter: Bool
	public var lowCut: Bool
	public var lowCutHertz: Double
	public var bassDecibels: Double
	public var trebleDecibels: Double

	public init(
		input: AudioDevice,
		output: AudioDevice,
		channelMode: InputChannelMode,
		latency: LatencyProfile,
		gainDecibels: Double,
		muted: Bool,
		safetyLimiter: Bool,
		lowCut: Bool = false,
		lowCutHertz: Double = ToneStage.defaultCutFrequency,
		bassDecibels: Double = 0,
		trebleDecibels: Double = 0
	) {
		self.input = input
		self.output = output
		self.channelMode = channelMode
		self.latency = latency
		self.gainDecibels = gainDecibels
		self.muted = muted
		self.safetyLimiter = safetyLimiter
		self.lowCut = lowCut
		self.lowCutHertz = lowCutHertz
		self.bassDecibels = bassDecibels
		self.trebleDecibels = trebleDecibels
	}
}

/// Owns the running signal path: a HAL input unit writing a ring buffer, and an
/// `AVAudioEngine` source node draining it through a drift-corrected resampler.
@MainActor
@Observable
public final class MonitorEngine {
	public enum State: Equatable, Sendable {
		case stopped
		case running
		case failed(String)
	}

	public private(set) var state: State = .stopped
	public private(set) var bufferFrames: UInt32 = 0
	public private(set) var estimatedLatencyMilliseconds: Double = 0

	/// Raised when the hardware changes underneath a running engine, for instance
	/// a device being unplugged. The owner decides whether to restart or stop.
	@ObservationIgnored public var onConfigurationChange: (() -> Void)?
	/// Raised when underruns keep happening at the current buffer size.
	@ObservationIgnored public var onLatencyStepUpNeeded: (() -> Void)?

	@ObservationIgnored private var captureUnit: InputCaptureUnit?
	@ObservationIgnored private var playback: AVAudioEngine?
	@ObservationIgnored private var sourceNode: AVAudioSourceNode?
	@ObservationIgnored private var processor: CaptureProcessor?
	@ObservationIgnored private var puller: PlaybackPuller?
	@ObservationIgnored private var analysisTimer: DispatchSourceTimer?
	@ObservationIgnored private var watchdog: Timer?
	@ObservationIgnored private var configurationObserver: NSObjectProtocol?
	@ObservationIgnored private var originalBufferSizes: [AudioDeviceID: UInt32] = [:]
	@ObservationIgnored private let snapshotBox = SnapshotBox()
	@ObservationIgnored private let analysisQueue = DispatchQueue(
		label: "com.mshannon.sidetone.analysis", qos: .userInitiated
	)
	@ObservationIgnored private var lastUnderrunCount = 0
	@ObservationIgnored private var watchdogHasBaseline = false
	@ObservationIgnored private var configurationFilter: ConfigurationChangeFilter?

	public init() {}

	public func snapshot() -> AudioSnapshot {
		snapshotBox.read()
	}

	public func apply(gainDecibels: Double, muted: Bool) {
		processor?.targetGain.value = muted ? 0 : Float(Decibels.toLinear(gainDecibels))
	}

	public func setSafetyLimiter(_ enabled: Bool) {
		processor?.limiterEnabled.store(enabled, ordering: .relaxed)
	}

	public func applyTone(lowCut: Bool, lowCutHertz: Double, bassDecibels: Double, trebleDecibels: Double) {
		processor?.lowCut.store(lowCut, ordering: .relaxed)
		processor?.lowCutHertz.value = Float(lowCutHertz)
		processor?.bassDecibels.value = Float(bassDecibels)
		processor?.trebleDecibels.value = Float(trebleDecibels)
	}

	public func start(_ configuration: MonitorConfiguration, stepUps: Int = 0) throws {
		stop()
		do {
			try performStart(configuration, stepUps: stepUps)
		} catch {
			abandonStart()
			throw error
		}
	}

	private func performStart(_ configuration: MonitorConfiguration, stepUps: Int) throws {
		let frames = configuration.latency.bufferFrames(
			inputTransport: configuration.input.transport,
			outputTransport: configuration.output.transport,
			stepUps: stepUps
		)
		applyBufferSize(frames, to: configuration.input.id)
		applyBufferSize(frames, to: configuration.output.id)
		bufferFrames = BufferSize.current(configuration.input.id) ?? frames

		let channelMode = configuration.channelMode.resolved(availableChannels: configuration.input.inputChannels)
		let inputSampleRate = configuration.input.sampleRate
		let maxFrames = max(Int(bufferFrames) * 2, 2048)

		let playbackRing = RingBuffer(
			capacityFrames: max(Int(bufferFrames) * 16, 8192),
			channels: channelMode.channelCount
		)
		let analysisRing = RingBuffer(capacityFrames: 8192, channels: 1)
		let targetFill = Double(bufferFrames) * 1.5

		let processor = CaptureProcessor(
			playbackRing: playbackRing,
			analysisRing: analysisRing,
			channelIndices: channelMode.indices,
			maxFrames: maxFrames,
			sampleRate: inputSampleRate,
			initialGain: configuration.muted ? 0 : Float(Decibels.toLinear(configuration.gainDecibels))
		)
		processor.limiterEnabled.store(configuration.safetyLimiter, ordering: .relaxed)
		processor.lowCut.store(configuration.lowCut, ordering: .relaxed)
		processor.lowCutHertz.value = Float(configuration.lowCutHertz)
		processor.bassDecibels.value = Float(configuration.bassDecibels)
		processor.trebleDecibels.value = Float(configuration.trebleDecibels)
		self.processor = processor

		let engine = AVAudioEngine()
		do {
			try engine.outputNode.auAudioUnit.setDeviceID(configuration.output.id)
		} catch {
			throw MonitorError.outputUnavailable(
				device: configuration.output.name,
				status: MonitorError.status(from: error)
			)
		}
		let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
		let outputChannels = max(1, min(2, hardwareFormat.channelCount))
		guard let renderFormat = AVAudioFormat(
			standardFormatWithSampleRate: hardwareFormat.sampleRate,
			channels: outputChannels
		) else {
			throw MonitorError.unsupportedOutputFormat(device: configuration.output.name)
		}

		let puller = PlaybackPuller(
			ring: playbackRing,
			inputSampleRate: inputSampleRate,
			outputSampleRate: hardwareFormat.sampleRate,
			targetFillFrames: targetFill
		)
		self.puller = puller

		// @Sendable is load bearing: without it the closure inherits this class's
		// main actor isolation, and Swift traps on an executor check every time
		// CoreAudio calls it from the render thread.
		let source = AVAudioSourceNode(format: renderFormat) { @Sendable _, _, frameCount, audioBufferList in
			puller.render(
				into: UnsafeMutableAudioBufferListPointer(audioBufferList),
				frames: Int(frameCount)
			)
			return noErr
		}
		engine.attach(source)
		engine.connect(source, to: engine.mainMixerNode, format: renderFormat)
		engine.prepare()

		// Playback starts first so that an output device which will not start never
		// causes the microphone to be opened.
		do {
			try engine.start()
		} catch {
			throw MonitorError.outputUnavailable(
				device: configuration.output.name,
				status: MonitorError.status(from: error)
			)
		}

		let unit: InputCaptureUnit
		do {
			unit = try InputCaptureUnit(
				deviceID: configuration.input.id,
				channels: configuration.input.inputChannels,
				sampleRate: inputSampleRate,
				maxFrames: UInt32(maxFrames)
			) { [processor] buffers, frames in
				processor.process(buffers, frames: frames)
			}
			try unit.start()
		} catch {
			engine.stop()
			throw MonitorError.inputUnavailable(
				device: configuration.input.name,
				status: (error as? AudioUnitError)?.status ?? MonitorError.status(from: error)
			)
		}

		playback = engine
		sourceNode = source
		captureUnit = unit

		observeConfigurationChanges(of: engine)
		startAnalysis(
			analysisRing: analysisRing,
			processor: processor,
			puller: puller,
			sampleRate: inputSampleRate
		)
		startWatchdog()

		estimatedLatencyMilliseconds = estimateLatency(
			configuration: configuration,
			targetFillFrames: targetFill,
			inputSampleRate: inputSampleRate
		)
		state = .running
	}

	/// Restores anything `start` changed before it threw, so a failed attempt
	/// leaves no device reconfigured and no callback installed.
	private func abandonStart() {
		processor = nil
		puller = nil
		restoreBufferSizes()
		bufferFrames = 0
	}

	/// Tears the signal path down completely. Safe to call when already stopped,
	/// and safe to call twice.
	public func stop() {
		analysisTimer?.cancel()
		analysisTimer = nil
		watchdog?.invalidate()
		watchdog = nil

		if let configurationObserver {
			NotificationCenter.default.removeObserver(configurationObserver)
			self.configurationObserver = nil
		}

		captureUnit?.stop()
		captureUnit = nil

		if let playback {
			playback.stop()
			if let sourceNode {
				playback.detach(sourceNode)
			}
			playback.reset()
		}
		playback = nil
		sourceNode = nil
		processor = nil
		puller = nil

		restoreBufferSizes()
		snapshotBox.clear()
		lastUnderrunCount = 0
		watchdogHasBaseline = false
		configurationFilter = nil
		estimatedLatencyMilliseconds = 0
		bufferFrames = 0

		if case .failed = state {} else {
			state = .stopped
		}
	}

	public func shutdown() {
		onConfigurationChange = nil
		onLatencyStepUpNeeded = nil
		state = .stopped
		stop()
	}

	public func fail(_ message: String) {
		stop()
		state = .failed(message)
	}

	private func startAnalysis(
		analysisRing: RingBuffer,
		processor: CaptureProcessor,
		puller: PlaybackPuller,
		sampleRate: Double
	) {
		let runner = AnalysisRunner(
			analysisRing: analysisRing,
			processor: processor,
			puller: puller,
			snapshotBox: snapshotBox,
			spectrum: SpectrumAnalyzer(),
			sampleRate: sampleRate
		)
		let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
		timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
		// @Sendable for the same reason as the render block: this handler runs on
		// the analysis queue, not the main actor.
		timer.setEventHandler { @Sendable in runner.tick() }
		timer.resume()
		analysisTimer = timer
	}

	/// Watches for sustained underruns and asks the owner to back off one latency
	/// tier, so a struggling device fixes itself instead of crackling.
	private func startWatchdog() {
		watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				let underruns = self.snapshotBox.read().underruns
				let delta = underruns - self.lastUnderrunCount
				self.lastUnderrunCount = underruns
				// The first interval only establishes a baseline. Backing off for a
				// burst as the devices settle would raise the buffer, restart, and
				// produce another burst, ratcheting latency up for no good reason.
				guard self.watchdogHasBaseline else {
					self.watchdogHasBaseline = true
					return
				}
				if delta > 4 {
					self.onLatencyStepUpNeeded?()
				}
			}
		}
	}

	private func observeConfigurationChanges(of engine: AVAudioEngine) {
		configurationFilter = ConfigurationChangeFilter(baseline: engine.outputNode.outputFormat(forBus: 0))
		configurationObserver = NotificationCenter.default.addObserver(
			forName: .AVAudioEngineConfigurationChange,
			object: engine,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, let playback = self.playback else { return }
				// Devices appearing or vanishing arrive separately through the HAL
				// listeners, so this only has to catch format changes.
				let current = playback.outputNode.outputFormat(forBus: 0)
				guard self.configurationFilter?.shouldRestart(for: current) == true else { return }
				self.onConfigurationChange?()
			}
		}
	}

	private func applyBufferSize(_ frames: UInt32, to device: AudioDeviceID) {
		if originalBufferSizes[device] == nil, let current = BufferSize.current(device) {
			originalBufferSizes[device] = current
		}
		BufferSize.set(frames, on: device)
	}

	private func restoreBufferSizes() {
		for (device, frames) in originalBufferSizes {
			BufferSize.set(frames, on: device)
		}
		originalBufferSizes.removeAll()
	}

	private func estimateLatency(
		configuration: MonitorConfiguration,
		targetFillFrames: Double,
		inputSampleRate: Double
	) -> Double {
		let input = DeviceLatency.measure(configuration.input.id, input: true)
		let output = DeviceLatency.measure(configuration.output.id, input: false)
		let ringMilliseconds = targetFillFrames / max(1, inputSampleRate) * 1000
		return input.milliseconds + output.milliseconds + ringMilliseconds
	}
}

