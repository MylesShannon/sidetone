import AVFoundation
import AppServices
import AudioCore
import AudioDevices
import CoreAudio
import Foundation

Report.suite("RingBuffer") {
	let ring = RingBuffer(capacityFrames: 256, channels: 2)
	Report.check(ring.capacityFrames == 256, "capacity is already a power of two")
	Report.check(ring.availableFrames == 0, "starts empty")

	var input: [Float] = []
	for frame in 0 ..< 100 {
		input.append(Float(frame))
		input.append(Float(frame) + 0.5)
	}
	let written = input.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 100) }
	Report.check(written == 100, "writes every frame when there is room")
	Report.check(ring.availableFrames == 100, "available matches what was written")

	Report.close(ring.sample(frameOffset: 0, channel: 0), 0, tolerance: 0.0001, "first sample")
	Report.close(ring.sample(frameOffset: 10, channel: 1), 10.5, tolerance: 0.0001, "offset sample, second channel")

	var output = [Float](repeating: 0, count: 200)
	let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 100) }
	Report.check(read == 100, "reads back everything")
	Report.check(output[0] == 0 && output[1] == 0.5 && output[198] == 99, "round trip preserves interleaving")
	Report.check(ring.availableFrames == 0, "reading consumes")
}

Report.suite("RingBuffer wraparound and overrun") {
	let ring = RingBuffer(capacityFrames: 256, channels: 1)
	var block = [Float](repeating: 1, count: 200)
	var scratch = [Float](repeating: 0, count: 200)

	for round in 0 ..< 8 {
		for index in block.indices { block[index] = Float(round * 200 + index) }
		block.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, frames: 200) }
		scratch.withUnsafeMutableBufferPointer { _ = ring.read(into: $0.baseAddress!, frames: 200) }
		Report.check(scratch[0] == Float(round * 200), "round \(round) survives wraparound")
	}
	Report.check(ring.overruns == 0, "no overruns when the reader keeps up")

	let small = RingBuffer(capacityFrames: 256, channels: 1)
	var big = [Float](repeating: 1, count: 300)
	let accepted = big.withUnsafeMutableBufferPointer { small.write($0.baseAddress!, frames: 300) }
	Report.check(accepted == 256, "writes only what fits")
	Report.check(small.overruns == 44, "counts the dropped frames")

	small.keepNewest(10)
	Report.check(small.availableFrames == 10, "keepNewest drops the backlog")
}

Report.suite("Catmull-Rom interpolation") {
	Report.close(catmullRom(0, 1, 2, 3, 0), 1, tolerance: 0.0001, "t=0 lands on p1")
	Report.close(catmullRom(0, 1, 2, 3, 1), 2, tolerance: 0.0001, "t=1 lands on p2")
	Report.close(catmullRom(0, 1, 2, 3, 0.5), 1.5, tolerance: 0.0001, "a linear ramp stays linear")
	Report.close(catmullRom(1, 1, 1, 1, 0.37), 1, tolerance: 0.0001, "a constant stays constant")
}

Report.suite("DriftController") {
	var controller = DriftController(targetFrames: 1000)
	Report.close(controller.update(fillFrames: 1000), 1, tolerance: 0.0001, "on target means no correction")

	controller.reset()
	let tooFull = controller.update(fillFrames: 1500)
	Report.check(tooFull > 1, "reads faster when the buffer is filling")

	controller.reset()
	let tooEmpty = controller.update(fillFrames: 500)
	Report.check(tooEmpty < 1, "reads slower when the buffer is draining")

	controller.reset()
	var extreme: Double = 1
	for _ in 0 ..< 10000 {
		extreme = controller.update(fillFrames: 100_000)
	}
	Report.check(extreme <= 1.005 + 1e-9, "correction stays inside the clamp")

	// A steady clock offset should be absorbed: hold the fill slightly high and the
	// controller should settle on a stable correction rather than running away.
	controller.reset()
	var previous: Double = 0
	var settled = false
	for step in 0 ..< 5000 {
		let correction = controller.update(fillFrames: 1050)
		if step > 100, abs(correction - previous) < 1e-9 { settled = true }
		previous = correction
	}
	Report.check(settled, "settles on a steady correction for a constant offset")
}

Report.suite("PlaybackPuller priming") {
	let frames = 128
	let ring = RingBuffer(capacityFrames: 2048, channels: 1)
	let puller = PlaybackPuller(
		ring: ring, inputSampleRate: 48000, outputSampleRate: 48000, targetFillFrames: 192
	)

	func capture(_ count: Int, value: Float) {
		let block = [Float](repeating: value, count: count)
		_ = block.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: count) }
	}

	func render() -> [Float] {
		var output = [Float](repeating: 999, count: frames)
		output.withUnsafeMutableBufferPointer { pointer in
			var list = AudioBufferList(
				mNumberBuffers: 1,
				mBuffers: AudioBuffer(
					mNumberChannels: 1,
					mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
					mData: UnsafeMutableRawPointer(pointer.baseAddress)
				)
			)
			withUnsafeMutablePointer(to: &list) {
				puller.render(into: UnsafeMutableAudioBufferListPointer($0), frames: frames)
			}
		}
		return output
	}

	// Playback always starts before capture, so the first callbacks see an empty
	// ring. That is the engine starting up, not a dropout.
	var output = render()
	Report.check(output.allSatisfy { $0 == 0 }, "silent before any audio has been captured")
	Report.check(puller.underruns == 0, "an empty ring at startup is not counted as a dropout")

	capture(100, value: 0.5)
	output = render()
	Report.check(output.allSatisfy { $0 == 0 }, "still silent below the target fill")
	Report.check(puller.underruns == 0, "waiting for the cushion is not counted as a dropout")

	capture(200, value: 0.5)
	output = render()
	Report.check(output.contains { $0 != 0 }, "plays once the ring reaches the target fill")
	Report.check(puller.underruns == 0, "priming finishes without a dropout")

	// Real starvation after playback has begun still has to be reported, or the
	// dropout counter stops being worth reading.
	ring.advanceRead(frames: ring.availableFrames)
	_ = render()
	Report.check(puller.underruns == 1, "starvation after priming is a dropout")
}

Report.suite("Decibels") {
	Report.close(Decibels.toLinear(0), 1, tolerance: 0.0001, "0 dB is unity")
	Report.close(Decibels.toLinear(-6), 0.5012, tolerance: 0.001, "-6 dB halves amplitude")
	Report.close(Decibels.toLinear(6), 1.9953, tolerance: 0.001, "+6 dB doubles amplitude")
	Report.check(Decibels.toLinear(Decibels.floor) == 0, "the floor is true silence")
	Report.close(Decibels.fromLinear(1.0), 0, tolerance: 0.0001, "unity is 0 dB")
	Report.check(Decibels.format(Decibels.floor) == "-inf dB", "the floor formats as -inf")
	Report.check(Decibels.format(3) == "+3.0 dB", "positive gain keeps its sign")
}

Report.suite("LatencyProfile") {
	Report.check(LatencyProfile.low.bufferFrames(inputTransport: .usb, outputTransport: .usb) == 64, "low is 64 frames")
	Report.check(
		LatencyProfile.medium.bufferFrames(inputTransport: .usb, outputTransport: .usb) == 256,
		"medium is 256 frames"
	)
	Report.check(
		LatencyProfile.high.bufferFrames(inputTransport: .usb, outputTransport: .usb) == 512,
		"high is 512 frames"
	)
	Report.check(
		LatencyProfile.auto.bufferFrames(inputTransport: .builtIn, outputTransport: .bluetooth) == 512,
		"automatic gives Bluetooth room"
	)
	Report.check(
		LatencyProfile.auto.bufferFrames(inputTransport: .builtIn, outputTransport: .builtIn) == 64,
		"automatic starts at the tightest tier on wired hardware"
	)
	Report.check(
		LatencyProfile.auto.bufferFrames(inputTransport: .usb, outputTransport: .displayPort) == 64,
		"USB into DisplayPort counts as wired"
	)
	Report.check(
		LatencyProfile.auto.bufferFrames(inputTransport: .usb, outputTransport: .unknown) == 256,
		"an unidentified device gets room rather than the tightest tier"
	)
	Report.check(
		LatencyProfile.auto.bufferFrames(inputTransport: .usb, outputTransport: .usb, stepUps: 2) == 256,
		"automatic can still be stepped up from the tightest tier"
	)
	Report.check(
		LatencyProfile.low.bufferFrames(inputTransport: .usb, outputTransport: .usb, stepUps: 2) == 256,
		"stepping up moves one tier at a time"
	)
	Report.check(
		LatencyProfile.high.bufferFrames(inputTransport: .usb, outputTransport: .usb, stepUps: 99) == 1024,
		"stepping up stops at the largest tier"
	)
}

Report.suite("InputChannelMode") {
	Report.check(InputChannelMode.default(availableChannels: 1) == .mono(0), "a mono device monitors channel one")
	Report.check(
		InputChannelMode.default(availableChannels: 4) == .stereo(left: 0, right: 1),
		"a multi-channel device defaults to the first pair"
	)
	Report.check(
		InputChannelMode.stereo(left: 4, right: 5).resolved(availableChannels: 1) == .mono(0),
		"a remembered pair falls back when the device shrinks"
	)
	Report.check(
		InputChannelMode.mono(7).resolved(availableChannels: 2) == .mono(1),
		"an out of range channel clamps"
	)
	Report.check(InputChannelMode.stereo(left: 0, right: 1).channelCount == 2, "stereo counts two channels")
}

Report.suite("LevelMeter") {
	let meter = LevelMeter()
	let sampleRate = 48000.0
	let sine = (0 ..< 4800).map { Float(sin(2 * Double.pi * 1000 * Double($0) / sampleRate)) }
	let reading = meter.analyze(sine)
	Report.close(reading.peak, 1, tolerance: 0.01, "a full scale sine peaks at one")
	Report.close(reading.rms, 0.707, tolerance: 0.01, "its RMS is about 0.707")
	Report.check(reading.clipped, "touching full scale counts as clipping")

	let headroom = sine.map { $0 * 0.9 }
	let safe = meter.analyze(headroom)
	Report.close(safe.peak, 0.9, tolerance: 0.01, "a signal with headroom reads its own peak")
	Report.check(!safe.clipped, "and is not flagged as clipping")

	let hot = sine.map { $0 * 1.5 }
	Report.check(meter.analyze(hot).clipped, "anything past full scale is clipping")
	Report.check(meter.analyze([]).peak == 0, "an empty block reads silent")
}

Report.suite("MeterBallistics") {
	var ballistics = MeterBallistics(holdFrames: 3, fallPerFrame: 0.1)
	ballistics.update(1)
	Report.close(ballistics.level, 1, tolerance: 0.0001, "rise is instant")
	ballistics.update(0)
	Report.close(ballistics.level, 0.9, tolerance: 0.0001, "fall is gradual")
	Report.close(ballistics.peakHold, 1, tolerance: 0.0001, "the peak marker holds")
	for _ in 0 ..< 10 { ballistics.update(0) }
	Report.check(ballistics.peakHold < 1, "the peak marker eventually releases")
}

Report.suite("GainStage") {
	var gain = GainStage()
	gain.prepare(sampleRate: 48000, startingAt: 1)
	var block = [Float](repeating: 1, count: 4800)
	block.withUnsafeMutableBufferPointer {
		gain.process($0.baseAddress!, frames: 4800, channels: 1, target: 0.5)
	}
	Report.close(block[0], 1, tolerance: 0.01, "the ramp starts where it was")
	Report.close(block[4799], 0.5, tolerance: 0.01, "and reaches the target")
	Report.check(block[100] > block[1000], "moving monotonically, so no click")
}

Report.suite("SafetyLimiter") {
	var limiter = SafetyLimiter()
	limiter.prepare(sampleRate: 48000)
	var block = [Float](repeating: 2, count: 4800)
	block.withUnsafeMutableBufferPointer {
		limiter.process($0.baseAddress!, frames: 4800, channels: 1)
	}
	Report.check(block[4799] <= SafetyLimiter.ceiling + 0.001, "a hot signal ends up under the ceiling")
	Report.check(limiter.reductionDecibels < 0, "and the limiter reports the reduction")

	var quiet = SafetyLimiter()
	quiet.prepare(sampleRate: 48000)
	var soft = [Float](repeating: 0.2, count: 480)
	soft.withUnsafeMutableBufferPointer {
		quiet.process($0.baseAddress!, frames: 480, channels: 1)
	}
	Report.close(soft[479], 0.2, tolerance: 0.0001, "a quiet signal passes through untouched")
	Report.check(quiet.reductionDecibels == 0, "with no reported reduction")
}

Report.suite("SpectrumAnalyzer") {
	let analyzer = SpectrumAnalyzer(bandCount: 24, fftSize: 1024)
	let sampleRate = 48000.0
	let tone = (0 ..< 1024).map { Float(sin(2 * Double.pi * 1000 * Double($0) / sampleRate)) }

	var bands: [Float] = []
	for _ in 0 ..< 20 {
		bands = tone.withUnsafeBufferPointer {
			analyzer.process($0.baseAddress!, count: 1024, sampleRate: sampleRate)
		}
	}
	Report.check(bands.count == 24, "produces one value per band")
	let loudest = bands.firstIndex(of: bands.max() ?? 0) ?? -1
	Report.check((11 ... 14).contains(loudest), "a 1 kHz tone lights the 1 kHz band (got band \(loudest))")
	Report.check(bands.allSatisfy { $0 >= 0 && $0 <= 1 }, "levels stay normalized")

	analyzer.reset()
	let silence = [Float](repeating: 0, count: 1024)
	var quiet: [Float] = []
	for _ in 0 ..< 40 {
		quiet = silence.withUnsafeBufferPointer {
			analyzer.process($0.baseAddress!, count: 1024, sampleRate: sampleRate)
		}
	}
	Report.check(quiet.allSatisfy { $0 < 0.02 }, "silence falls to the floor")
}

Report.suite("Settings persistence") {
	let defaults = UserDefaults(suiteName: "com.mshannon.sidetone.verify")!
	defaults.removePersistentDomain(forName: "com.mshannon.sidetone.verify")

	let settings = Settings(defaults: defaults)
	settings.data.gainDecibels = 4.5
	settings.data.latency = .low
	settings.data.input = DeviceRef(uid: "uid-mic", name: "Some Microphone")
	settings.data.presets = [
		Preset(
			name: "Podcast",
			input: DeviceRef(uid: "uid-mic", name: "Some Microphone"),
			output: DeviceRef(uid: "uid-cans", name: "Some Headphones"),
			channelMode: .mono(0),
			gainDecibels: 3,
			latency: .low
		),
	]

	let reloaded = Settings(defaults: defaults)
	Report.close(reloaded.data.gainDecibels, 4.5, tolerance: 0.0001, "gain survives a relaunch")
	Report.check(reloaded.data.latency == .low, "the latency profile survives")
	Report.check(reloaded.data.input?.uid == "uid-mic", "the remembered input survives")
	Report.check(reloaded.data.presets.first?.name == "Podcast", "presets survive")
	Report.check(reloaded.data.safetyLimiter, "untouched settings keep their defaults")

	// An older or partial file must not wipe the settings that it predates.
	defaults.set(Data(#"{"gainDecibels": -2}"#.utf8), forKey: "settings")
	let upgraded = Settings(defaults: defaults)
	Report.close(upgraded.data.gainDecibels, -2, tolerance: 0.0001, "a partial file still decodes")
	Report.check(upgraded.data.latency == .auto, "and missing keys fall back to defaults")
	Report.check(upgraded.data.safetyLimiter, "including the safety limiter")

	defaults.removePersistentDomain(forName: "com.mshannon.sidetone.verify")
}

Report.suite("FeedbackGuard") {
	let speakers = AudioDevice(
		id: 1, uid: "builtin-out", name: "MacBook Pro Speakers", transport: .builtIn,
		inputChannels: 0, outputChannels: 2, sampleRate: 48000,
		outputDataSource: DataSourceCode.internalSpeaker
	)
	let headphones = AudioDevice(
		id: 2, uid: "builtin-out", name: "Headphones", transport: .builtIn,
		inputChannels: 0, outputChannels: 2, sampleRate: 48000,
		outputDataSource: DataSourceCode.headphones
	)
	let interface = AudioDevice(
		id: 3, uid: "usb-out", name: "Scarlett 2i2", transport: .usb,
		inputChannels: 2, outputChannels: 2, sampleRate: 48000
	)
	let microphone = AudioDevice(
		id: 4, uid: "mic", name: "MacBook Pro Microphone", transport: .builtIn,
		inputChannels: 1, outputChannels: 0, sampleRate: 48000, inputKind: .microphone
	)
	let lineIn = AudioDevice(
		id: 5, uid: "line", name: "Cubilux CB5 Line In", transport: .usb,
		inputChannels: 2, outputChannels: 0, sampleRate: 48000, inputKind: .line
	)
	let mystery = AudioDevice(
		id: 6, uid: "mystery", name: "Something", transport: .usb,
		inputChannels: 1, outputChannels: 0, sampleRate: 48000
	)

	Report.check(
		FeedbackGuard.risk(input: microphone, output: speakers) == .microphoneIntoSpeakers,
		"a microphone into the speakers is flagged"
	)
	Report.check(
		FeedbackGuard.risk(input: lineIn, output: speakers) == nil,
		"a line input cannot hear the speakers, so it is not flagged"
	)
	Report.check(
		FeedbackGuard.risk(input: mystery, output: speakers) == .unknownInputIntoSpeakers,
		"an input that does not say what it is gets the cautious warning"
	)
	Report.check(
		FeedbackGuard.risk(input: microphone, output: headphones) == nil,
		"the headphone jack is not flagged"
	)
	Report.check(
		FeedbackGuard.risk(input: microphone, output: interface) == nil,
		"an interface is not flagged"
	)

	Report.check(InputKind(terminalType: kAudioStreamTerminalTypeLine) == .line, "reads a line terminal")
	Report.check(InputKind(terminalType: 0x0201) == .microphone, "reads the USB microphone terminal")
	Report.check(InputKind(terminalType: nil) == .unknown, "a silent device is unknown")
}

Report.suite("Private aggregates") {
	// Opening the default device gets a process its own CADefaultDeviceAggregate,
	// which reports isHidden 0 and sticks around for the life of the process. The
	// composition dictionary is the only thing that marks it as plumbing.
	Report.check(
		HAL.isPrivate(composition: [kAudioAggregateDeviceIsPrivateKey: 1]),
		"a private aggregate is recognised"
	)
	Report.check(
		!HAL.isPrivate(composition: [kAudioAggregateDeviceIsPrivateKey: 0]),
		"an aggregate someone built on purpose is not"
	)
	Report.check(!HAL.isPrivate(composition: [:]), "neither is one that says nothing")
	Report.check(
		!HAL.isPrivate(composition: [kAudioAggregateDeviceNameKey: "Studio"]),
		"nor one with only a name"
	)
}

Report.suite("Device resolution") {
	let mic = AudioDevice(
		id: 11, uid: "usb-mic", name: "Yeti", transport: .usb,
		inputChannels: 2, outputChannels: 0, sampleRate: 48000
	)
	let cans = AudioDevice(
		id: 12, uid: "bt-cans", name: "AirPods Max", transport: .bluetooth,
		inputChannels: 1, outputChannels: 2, sampleRate: 48000
	)
	let source = StubDeviceSource(devices: [mic, cans], defaultInputUID: "usb-mic", defaultOutputUID: "bt-cans")

	Report.check(source.allDevices().count == 2, "the stub lists its devices")
	Report.check(DeviceRef(uid: "bt-cans", name: "AirPods Max").resolve(in: source.allDevices())?.id == 12,
	             "a remembered device resolves by UID")
	Report.check(DeviceRef(uid: "gone", name: "Unplugged").resolve(in: source.allDevices()) == nil,
	             "a missing device resolves to nothing")
	// The numeric device ID changes across replug; the UID is what must be trusted.
	let replugged = AudioDevice(
		id: 99, uid: "usb-mic", name: "Yeti", transport: .usb,
		inputChannels: 2, outputChannels: 0, sampleRate: 48000
	)
	Report.check(DeviceRef(uid: "usb-mic", name: "Yeti").resolve(in: [replugged, cans])?.id == 99,
	             "the same UID resolves after a replug with a new ID")
	Report.check(cans.canInput && cans.canOutput, "a headset counts as both directions")
	Report.check(!mic.canOutput, "a microphone is input only")
}

Report.suite("Device change reporting") {
	// The bug: switching monitoring on makes the HAL create its private aggregate for
	// the device in use, which posts a device list change. The aggregate is filtered
	// out, so nothing in the list moved, but the app restarted anyway and monitoring
	// visibly stopped and started again.
	final class ShiftingSource: DeviceSource, @unchecked Sendable {
		var devices: [AudioDevice]
		var defaultInput: String?

		init(devices: [AudioDevice], defaultInput: String?) {
			self.devices = devices
			self.defaultInput = defaultInput
		}

		func allDevices() -> [AudioDevice] { devices }
		func defaultDeviceUID(input: Bool) -> String? { input ? defaultInput : nil }
	}

	let mic = AudioDevice(
		id: 11, uid: "usb-mic", name: "Yeti", transport: .usb,
		inputChannels: 2, outputChannels: 0, sampleRate: 48000
	)
	let source = ShiftingSource(devices: [mic], defaultInput: "usb-mic")
	let store = DeviceStore(source: source)

	var changes = 0
	store.onChange = { changes += 1 }

	store.refresh()
	store.refresh()
	Report.check(changes == 0, "an unchanged device list is not a change")

	source.devices = []
	store.refresh()
	Report.check(changes == 1, "a device disappearing is a change")

	source.devices = [mic]
	store.refresh()
	Report.check(changes == 2, "and it coming back is another")

	let second = AudioDevice(
		id: 12, uid: "built-in", name: "MacBook Pro Microphone", transport: .builtIn,
		inputChannels: 2, outputChannels: 0, sampleRate: 48000
	)
	source.devices = [mic, second]
	source.defaultInput = "built-in"
	store.refresh()
	Report.check(changes == 3, "so is the default input moving")
	Report.check(store.defaultInputUID == "built-in", "and the new default is the one kept")

	store.refresh()
	Report.check(changes == 3, "but settling there is not")

	// The HAL sometimes fails this one question while answering everything else. A nil
	// recorded here would stick, because a wrong cache provokes no notification, and
	// following the system default would resolve to nothing for the rest of the run.
	source.defaultInput = nil
	store.refresh()
	Report.check(store.defaultInputUID == "built-in", "a failed lookup keeps the last good answer")
	Report.check(changes == 3, "and reports no change, because nothing was learned")

	// Resolution asks the system rather than trusting that record, or a default that
	// moved while the question was failing would point at the wrong device for good.
	// Resolution reads the cached UID first. Asking the system every time is a round
	// trip to coreaudiod, and this is read from a panel redrawing thirty times a
	// second, where it cost more processor than the audio did.
	source.defaultInput = "usb-mic"
	Report.check(
		store.defaultInput()?.uid == "built-in",
		"a cached default that still names a device is used as it stands"
	)
	store.refresh()
	Report.check(
		store.defaultInput()?.uid == "usb-mic",
		"and a refresh moves it, which is what the listener brings"
	)

	source.defaultInput = nil
	Report.check(
		store.defaultInput()?.uid == "usb-mic",
		"a failing lookup leaves the last good answer standing"
	)



	// CoreAudio sometimes names no default at all for a whole process. Refusing to
	// start is worse than picking the built-in device, which is what the machine would
	// have fallen back to anyway.
	source.defaultInput = "unplugged-thing"
	store.refresh()
	Report.check(
		store.defaultInput()?.uid == "built-in",
		"a default naming something absent falls back to the built-in device"
	)

	source.devices = [mic]
	store.refresh()
	Report.check(
		store.defaultInput()?.uid == "usb-mic",
		"and to whatever is there when nothing is built in"
	)
}

Report.suite("Snapshot boxes") {
	let box = SnapshotBox()
	Report.check(box.read() == .silent, "starts silent")

	var snapshot = AudioSnapshot()
	snapshot.peak = 0.5
	snapshot.underruns = 3
	snapshot.bands = [0.1, 0.2]
	box.write(snapshot)
	Report.check(box.read().peak == 0.5, "reads back what was written")
	Report.check(box.read().underruns == 3, "counters survive the trip")
	Report.check(box.read().bands == [0.1, 0.2], "so do the bands")

	box.clear()
	Report.check(box.read() == .silent, "clearing goes back to silent")

	// Atomic has no Float conformance, so this stores the bit pattern. Round
	// tripping awkward values is the whole point.
	let atomic = AtomicFloat(1)
	Report.check(atomic.value == 1, "holds its initial value")
	atomic.value = -0.375
	Report.close(atomic.value, -0.375, tolerance: 0, "a negative fraction survives exactly")
	atomic.value = 0
	Report.check(atomic.value == 0, "and zero")
}

Report.suite("CaptureProcessor") {
	let frames = 64

	func buffers(_ channels: [[Float]]) -> UnsafeMutableAudioBufferListPointer {
		let list = AudioBufferList.allocate(maximumBuffers: channels.count)
		for (index, samples) in channels.enumerated() {
			let storage = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
			storage.initialize(repeating: 0, count: samples.count)
			for (offset, sample) in samples.enumerated() { storage[offset] = sample }
			list[index] = AudioBuffer(
				mNumberChannels: 1,
				mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
				mData: UnsafeMutableRawPointer(storage)
			)
		}
		return list
	}

	// Monitoring channel two of a two-channel device must take channel two, which is
	// the case a stereo-only implementation gets wrong.
	let playback = RingBuffer(capacityFrames: 1024, channels: 1)
	let analysis = RingBuffer(capacityFrames: 1024, channels: 1)
	let processor = CaptureProcessor(
		playbackRing: playback, analysisRing: analysis, channelIndices: [1],
		maxFrames: frames, sampleRate: 48000, initialGain: 1
	)
	processor.limiterEnabled.store(false, ordering: .relaxed)
	processor.process(buffers([Array(repeating: 0.25, count: frames), Array(repeating: -0.5, count: frames)]),
	                  frames: frames)

	Report.check(playback.availableFrames == frames, "every frame reaches the playback ring")
	Report.close(playback.sample(frameOffset: 0, channel: 0), -0.5, tolerance: 0.0001,
	             "the selected channel is the one that is monitored")
	Report.check(analysis.availableFrames == frames, "metering gets its own copy")

	// Gain is applied without a ramp when it already starts at the target.
	let loudPlayback = RingBuffer(capacityFrames: 1024, channels: 1)
	let loudProcessor = CaptureProcessor(
		playbackRing: loudPlayback, analysisRing: RingBuffer(capacityFrames: 1024, channels: 1),
		channelIndices: [0], maxFrames: frames, sampleRate: 48000, initialGain: 2
	)
	loudProcessor.limiterEnabled.store(false, ordering: .relaxed)
	loudProcessor.process(buffers([Array(repeating: 0.25, count: frames)]), frames: frames)
	Report.close(loudPlayback.sample(frameOffset: 0, channel: 0), 0.5, tolerance: 0.0001, "gain multiplies")

	// A stereo pair averages down to one channel for the analysis ring.
	let stereoAnalysis = RingBuffer(capacityFrames: 1024, channels: 1)
	let stereo = CaptureProcessor(
		playbackRing: RingBuffer(capacityFrames: 1024, channels: 2), analysisRing: stereoAnalysis,
		channelIndices: [0, 1], maxFrames: frames, sampleRate: 48000, initialGain: 1
	)
	stereo.limiterEnabled.store(false, ordering: .relaxed)
	stereo.process(buffers([Array(repeating: 1.0, count: frames), Array(repeating: 0.0, count: frames)]),
	               frames: frames)
	Report.close(stereoAnalysis.sample(frameOffset: 0, channel: 0), 0.5, tolerance: 0.0001,
	             "the analysis copy is the average of the monitored channels")

	// Full scale counts as a clip, and the limiter reports doing work.
	let hot = CaptureProcessor(
		playbackRing: RingBuffer(capacityFrames: 1024, channels: 1),
		analysisRing: RingBuffer(capacityFrames: 1024, channels: 1),
		channelIndices: [0], maxFrames: frames, sampleRate: 48000, initialGain: 4
	)
	Report.check(hot.clipCount.load(ordering: .relaxed) == 0, "nothing has clipped yet")
	for _ in 0 ..< 8 {
		hot.process(buffers([Array(repeating: 1.0, count: frames)]), frames: frames)
	}
	Report.check(hot.clipCount.load(ordering: .relaxed) > 0, "a hot signal is counted as clipping")
	// Reduction is reported as negative dB, matching SafetyLimiter.
	Report.check(hot.limiterReduction.value < 0, "and the limiter reports pulling it down")

	// Asking for more frames than the processor was built for must not run off the
	// end of its scratch buffer.
	let clamped = RingBuffer(capacityFrames: 1024, channels: 1)
	let small = CaptureProcessor(
		playbackRing: clamped, analysisRing: RingBuffer(capacityFrames: 1024, channels: 1),
		channelIndices: [0], maxFrames: 16, sampleRate: 48000, initialGain: 1
	)
	small.process(buffers([Array(repeating: 0.5, count: frames)]), frames: frames)
	Report.check(clamped.availableFrames == 16, "a too-large request is clamped to the maximum")
}

Report.suite("AnalysisRunner") {
	let analysis = RingBuffer(capacityFrames: 4096, channels: 1)
	let playback = RingBuffer(capacityFrames: 4096, channels: 1)
	let processor = CaptureProcessor(
		playbackRing: playback, analysisRing: analysis, channelIndices: [0],
		maxFrames: 512, sampleRate: 48000, initialGain: 1
	)
	let puller = PlaybackPuller(
		ring: playback, inputSampleRate: 48000, outputSampleRate: 48000, targetFillFrames: 192
	)
	let box = SnapshotBox()
	let spectrum = SpectrumAnalyzer()
	let runner = AnalysisRunner(
		analysisRing: analysis, processor: processor, puller: puller,
		snapshotBox: box, spectrum: spectrum, sampleRate: 48000
	)

	// Nothing captured: the snapshot still has to be well formed, because the UI
	// draws it every frame whether audio is flowing or not.
	runner.tick()
	Report.check(box.read().peak == 0, "silence reads as no level")
	Report.check(!box.read().bands.isEmpty, "the spectrum still has bands to draw")

	let tone = (0 ..< 1024).map { sin(Float($0) * 0.1) * 0.5 }
	_ = tone.withUnsafeBufferPointer { analysis.write($0.baseAddress!, frames: tone.count) }
	runner.tick()
	Report.check(box.read().peak > 0.4, "a tone shows up as level")
	Report.check(box.read().rms > 0.2, "and as RMS")
	Report.check(box.read().bands.contains { $0 > 0 }, "and lights up the spectrum")

	// A clip has to stay visible long enough to notice, rather than vanishing on
	// the next tick.
	processor.clipCount.wrappingAdd(1, ordering: .relaxed)
	runner.tick()
	Report.check(box.read().clipping, "a clip is reported")
	runner.tick()
	Report.check(box.read().clipping, "and held past the tick it happened on")

	Report.check(box.read().underruns == puller.underruns, "dropouts come from the puller")
	Report.check(box.read().overruns == playback.overruns, "overruns come from the ring")
}

Report.suite("Configuration change filtering") {
	let stereo48 = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
	let stereo44 = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
	let mono48 = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)

	// The bug: starting on the built-in speakers posts a configuration change with
	// the format unchanged, and restarting for it posts another.
	var filter = ConfigurationChangeFilter(baseline: stereo48)
	Report.check(!filter.shouldRestart(for: stereo48), "an unchanged format is not a restart")
	Report.check(!filter.shouldRestart(for: stereo48), "and it stays not a restart, however often it arrives")

	Report.check(filter.shouldRestart(for: stereo44), "a new sample rate is a restart")
	// The anti-loop property: having restarted once, the same format must not ask
	// for another restart, or the engine cycles.
	Report.check(!filter.shouldRestart(for: stereo44), "the same change does not ask twice")

	Report.check(filter.shouldRestart(for: mono48), "a new channel count is a restart")
	Report.check(!filter.shouldRestart(for: mono48), "and that one settles too")

	var unstarted = ConfigurationChangeFilter(baseline: nil)
	Report.check(!unstarted.shouldRestart(for: stereo48), "with no baseline there is nothing to compare")

	var running = ConfigurationChangeFilter(baseline: stereo48)
	Report.check(!running.shouldRestart(for: nil), "a missing current format is not a restart")
}

Report.suite("Failure messages") {
	// CoreAudio reports 'stop' when a device will not start, which means nothing to
	// anyone reading a panel. The message must not guess at a cause it cannot know,
	// only report the refusal and what to do about it.
	let dead = MonitorError.outputUnavailable(
		device: "LG ULTRAGEAR+", status: OSStatus(kAudioHardwareNotRunningError)
	)
	Report.check(dead.description.contains("LG ULTRAGEAR+"), "names the device that failed")
	Report.check(!dead.description.contains("1937010544"), "does not show the raw numeric code")
	Report.check(dead.description.lowercased().contains("no app"), "says the failure is not app specific")
	Report.check(dead.description.lowercased().contains("restart"), "offers a way out")

	let taken = MonitorError.outputUnavailable(device: "Scarlett", status: OSStatus(kAudioDevicePermissionsError))
	Report.check(taken.description.lowercased().contains("another app"), "explains exclusive use")

	let gone = MonitorError.inputUnavailable(device: "Yeti", status: OSStatus(kAudioHardwareBadDeviceError))
	Report.check(gone.description.contains("Yeti"), "names a missing input")

	// Status codes are developer vocabulary. An unrecognized one reads as a plain
	// sentence rather than leaking either its characters or its number.
	let odd = MonitorError.outputUnavailable(device: "Thing", status: OSStatus(bitPattern: 0x7A7A_7A7A))
	Report.check(!odd.description.contains("zzzz"), "an unrecognized code is not shown as characters")

	let noCode = MonitorError.outputUnavailable(device: "Thing", status: nil)
	Report.check(!noCode.description.contains("?"), "an unknown status shows no code rather than '????'")
	Report.check(noCode.description.hasSuffix("start."), "reads as a sentence without a code")

	let audioUnit = MonitorError.inputUnavailable(device: "Cubilux CB5 Line In", status: -10851)
	Report.check(!audioUnit.description.contains("-10851"), "an unrecognized code is not shown as a number")
	Report.check(audioUnit.description.hasSuffix("would not start."), "an AudioUnit failure still reads plainly")

	let engineError = NSError(domain: "com.apple.coreaudio.avfaudio", code: 1_937_010_544)
	Report.check(
		MonitorError.status(from: engineError) == OSStatus(kAudioHardwareNotRunningError),
		"reads the status out of an AVAudioEngine error"
	)
	Report.check(MonitorError.status(from: CocoaError(.fileNoSuchFile)) == nil, "ignores unrelated errors")
}

Report.suite("KeyCombo") {
	let combo = KeyCombo.defaultToggle
	Report.check(combo.displayString.contains("⌘"), "the default shortcut shows its command key")
	Report.check(combo.displayString.contains("⌥"), "and its option key")

	let encoded = try JSONEncoder().encode(combo)
	let decoded = try JSONDecoder().decode(KeyCombo.self, from: encoded)
	Report.check(decoded == combo, "shortcuts round trip through JSON")
}

Report.suite("Tone controls") {
	let rate = 48000.0

	/// Runs a sine through the stage and reports what came out, in dB relative to what
	/// went in. Measured over the second half so the filter's own settling is past.
	func response(
		_ hertz: Double,
		lowCut: Bool = false,
		cutHertz: Double = ToneStage.defaultCutFrequency,
		bass: Double = 0,
		treble: Double = 0
	) -> Double {
		var stage = ToneStage()
		stage.prepare(sampleRate: rate)

		let frames = 24000
		let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
		defer { buffer.deallocate() }
		for frame in 0 ..< frames {
			buffer[frame] = Float(sin(2 * .pi * hertz * Double(frame) / rate))
		}

		stage.process(
			buffer, frames: frames, channels: 1,
			lowCut: lowCut, cutHertz: cutHertz, bassDecibels: bass, trebleDecibels: treble
		)

		let from = frames / 2
		var sum = 0.0
		for frame in from ..< frames {
			sum += Double(buffer[frame]) * Double(buffer[frame])
		}
		let rms = (sum / Double(frames - from)).squareRoot()
		// A full scale sine has an RMS of one over root two.
		return Decibels.fromLinear(rms * 2.0.squareRoot())
	}

	Report.close(response(1000), 0, tolerance: 0.1, "flat settings leave the signal alone")

	// Rumble, console fans and handling noise all live below the cut.
	Report.check(response(30, lowCut: true) < -14, "the low cut takes out a 30 Hz rumble")
	Report.check(response(30, lowCut: true) > -22, "and does it with a gentle slope, not a brick wall")
	Report.check(response(1000, lowCut: true) > -0.2, "while leaving the voice range untouched")

	// Where the cut sits is adjustable, so the tone has to follow it.
	Report.check(response(150, lowCut: true, cutHertz: 20) > -0.5, "a cut down at 20 Hz leaves 150 Hz alone")
	Report.check(response(150, lowCut: true, cutHertz: 200) < -6, "and one up at 200 Hz does not")
	Report.check(
		response(60, lowCut: true, cutHertz: 200) < response(60, lowCut: true, cutHertz: 40),
		"moving the corner up takes more out of the bottom"
	)

	Report.close(response(40, bass: 6), 6, tolerance: 1.5, "bass lift reaches its setting low down")
	// The shelf has to reach the part of the range people call bass, not just the part
	// their speakers cannot reproduce.
	Report.check(response(120, bass: 12) > 10, "and still has most of its lift at 120 Hz")
	Report.close(response(5000, bass: 6), 0, tolerance: 0.5, "and does not touch the top end")
	Report.close(response(40, bass: -12), -12, tolerance: 1.5, "bass cut works the same way")

	Report.close(response(12000, treble: 6), 6, tolerance: 1.5, "treble lift reaches its setting up high")
	Report.close(response(200, treble: 6), 0, tolerance: 0.5, "and does not touch the bottom end")

	// A shelf above Nyquist has to be clamped, or the coefficients come out as
	// nonsense and the filter screams instead of shelving.
	var narrow = ToneStage()
	narrow.prepare(sampleRate: 8000)
	let sample = UnsafeMutablePointer<Float>.allocate(capacity: 64)
	defer { sample.deallocate() }
	for frame in 0 ..< 64 { sample[frame] = 0.5 }
	narrow.process(
		sample, frames: 64, channels: 1,
		lowCut: true, cutHertz: 80, bassDecibels: 6, trebleDecibels: 12
	)
	Report.check((0 ..< 64).allSatisfy { sample[$0].isFinite }, "a corner above Nyquist stays finite")

	var flat = ToneStage()
	flat.prepare(sampleRate: rate)
	Report.check(flat.isFlat, "a stage with nothing set knows it can be skipped")
	flat.process(
		sample, frames: 8, channels: 1,
		lowCut: false, cutHertz: 80, bassDecibels: 3, trebleDecibels: 0
	)
	Report.check(!flat.isFlat, "and knows when it cannot")
}

Report.suite("Presets") {
	let preset = Preset(
		name: "Console",
		input: DeviceRef(uid: "line-in", name: "Cubilux"),
		output: DeviceRef(uid: "cans", name: "AirPods Max"),
		channelMode: .stereo(left: 0, right: 1),
		gainDecibels: 13.5,
		latency: .auto,
		lowCut: true,
		lowCutHertz: 120,
		bassDecibels: -3,
		trebleDecibels: 4.5
	)

	let encoded = try JSONEncoder().encode(preset)
	Report.check(try JSONDecoder().decode(Preset.self, from: encoded) == preset, "a preset round trips with its tone")

	// A preset saved by the first release has none of the tone keys. Losing someone's
	// presets to a decoding error is the one outcome that is not allowed.
	let old = Data(#"{"id":"6E1B1E8C-0000-4000-8000-00000000ABCD","name":"Old","gainDecibels":6,"latency":"auto"}"#.utf8)
	let migrated = try JSONDecoder().decode(Preset.self, from: old)
	Report.check(migrated.name == "Old", "a preset from before tone still loads")
	Report.check(migrated.gainDecibels == 6, "keeping what it did store")
	Report.check(!migrated.lowCut, "and comes back with the low cut off")
	Report.check(migrated.bassDecibels == 0 && migrated.trebleDecibels == 0, "and its tone flat")
	Report.close(
		migrated.lowCutHertz, ToneStage.defaultCutFrequency, tolerance: 0.001,
		"and its cut at the default frequency"
	)
}

Report.suite("Settings migration") {
	// A settings file written by 1.0.0 has none of the tone or auto-start keys, and
	// one missing key would otherwise throw away every setting in the file.
	let old = Data(#"{"gainDecibels":6,"muted":false,"latency":"low","safetyLimiter":true}"#.utf8)
	let migrated = try JSONDecoder().decode(SettingsData.self, from: old)
	Report.check(migrated.gainDecibels == 6, "what it did store is kept")
	Report.check(migrated.latency == .low, "including the latency profile")
	Report.check(!migrated.lowCut, "the low cut comes back off")
	Report.check(migrated.bassDecibels == 0 && migrated.trebleDecibels == 0, "and the tone flat")
	Report.close(
		migrated.lowCutHertz, ToneStage.defaultCutFrequency, tolerance: 0.001,
		"with the cut at its default frequency"
	)
	Report.check(!migrated.startWhenDevicesAppear, "and starting on plug-in switched off")

	var current = SettingsData()
	current.lowCut = true
	current.lowCutHertz = 120
	current.bassDecibels = -4.5
	current.trebleDecibels = 3
	current.startWhenDevicesAppear = true
	let round = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(current))
	Report.check(round == current, "and everything new survives a round trip")
}

Report.suite("Transport types") {
	Report.check(TransportType(rawValue: kAudioDeviceTransportTypeUSB) == .usb, "USB is recognised")
	Report.check(
		TransportType(rawValue: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth,
		"low energy Bluetooth counts as Bluetooth"
	)
	Report.check(
		TransportType(rawValue: kAudioDeviceTransportTypeContinuityCaptureWireless) == .network,
		"an iPhone over Continuity counts as a network device"
	)
	Report.check(TransportType(rawValue: 0) == .unknown, "and anything unfamiliar is simply unknown")

	// This is what decides how much headroom the automatic profile leaves, so a device
	// landing in the wrong group means dropouts or needless latency.
	Report.check(TransportType.bluetooth.needsExtraBuffering, "Bluetooth needs headroom")
	Report.check(TransportType.airPlay.needsExtraBuffering, "so does AirPlay")
	Report.check(TransportType.aggregate.needsExtraBuffering, "and an aggregate, whose clock is a fiction")
	Report.check(!TransportType.usb.needsExtraBuffering, "while USB does not")
	Report.check(!TransportType.builtIn.needsExtraBuffering, "nor the built-in device")
	Report.check(TransportType.airPlay.isWireless, "AirPlay is wireless")
	Report.check(!TransportType.thunderbolt.isWireless, "Thunderbolt is not")
}

Report.suite("Device latency") {
	let latency = DeviceLatency(
		deviceFrames: 100, safetyOffsetFrames: 33, streamFrames: 7, bufferFrames: 64, sampleRate: 48000
	)
	Report.check(latency.totalFrames == 204, "every stage counts towards the total")
	Report.close(latency.milliseconds, 4.25, tolerance: 0.001, "and frames convert by the sample rate")

	let halved = DeviceLatency(
		deviceFrames: 100, safetyOffsetFrames: 33, streamFrames: 7, bufferFrames: 64, sampleRate: 96000
	)
	Report.check(halved.milliseconds < latency.milliseconds, "the same frames take less time at a higher rate")

	let broken = DeviceLatency(
		deviceFrames: 100, safetyOffsetFrames: 0, streamFrames: 0, bufferFrames: 0, sampleRate: 0
	)
	Report.check(broken.milliseconds == 0, "a device reporting no sample rate does not divide by zero")
}

Report.suite("Auto start") {
	var rule = AutoStartRule()
	Report.check(
		!rule.shouldStart(enabled: true, present: false, running: false),
		"there is nothing to start without the devices"
	)
	Report.check(
		rule.shouldStart(enabled: true, present: true, running: false),
		"the devices arriving starts monitoring"
	)
	Report.check(
		!rule.shouldStart(enabled: true, present: true, running: true),
		"sitting there plugged in does not start it again"
	)
	// The case that matters: switched off by hand, with the hardware still connected.
	Report.check(
		!rule.shouldStart(enabled: true, present: true, running: false),
		"switching off by hand is left alone"
	)

	_ = rule.shouldStart(enabled: true, present: false, running: false)
	Report.check(
		rule.shouldStart(enabled: true, present: true, running: false),
		"unplugging and plugging back in starts it again"
	)

	var disabled = AutoStartRule()
	Report.check(
		!disabled.shouldStart(enabled: false, present: true, running: false),
		"and none of it happens when the setting is off"
	)

	var already = AutoStartRule(devicesPresent: true)
	Report.check(
		!already.shouldStart(enabled: true, present: true, running: false),
		"hardware that was already there at launch is not an arrival"
	)
}

Report.finish()
