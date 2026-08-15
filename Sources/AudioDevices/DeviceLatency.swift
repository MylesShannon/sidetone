import CoreAudio

/// One direction's hardware latency, in frames, as reported by the driver.
///
/// This is an estimate of what the hardware adds, not a measured round trip. A real
/// measurement needs a loopback cable and a test tone.
public struct DeviceLatency: Sendable, Equatable {
	public let deviceFrames: UInt32
	public let safetyOffsetFrames: UInt32
	public let streamFrames: UInt32
	public let bufferFrames: UInt32
	public let sampleRate: Double

	public init(
		deviceFrames: UInt32,
		safetyOffsetFrames: UInt32,
		streamFrames: UInt32,
		bufferFrames: UInt32,
		sampleRate: Double
	) {
		self.deviceFrames = deviceFrames
		self.safetyOffsetFrames = safetyOffsetFrames
		self.streamFrames = streamFrames
		self.bufferFrames = bufferFrames
		self.sampleRate = sampleRate
	}

	public var totalFrames: UInt32 {
		deviceFrames + safetyOffsetFrames + streamFrames + bufferFrames
	}

	public var milliseconds: Double {
		guard sampleRate > 0 else { return 0 }
		return Double(totalFrames) / sampleRate * 1000
	}

	public static func measure(_ device: AudioDeviceID, input: Bool) -> DeviceLatency {
		let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
		let deviceFrames: UInt32 = (try? HAL.value(device, HAL.address(kAudioDevicePropertyLatency, scope: scope))) ?? 0
		let safety: UInt32 = (try? HAL.value(device, HAL.address(kAudioDevicePropertySafetyOffset, scope: scope))) ?? 0
		let sampleRate: Double = (try? HAL.value(device, HAL.address(kAudioDevicePropertyNominalSampleRate))) ?? 48000
		let buffer = BufferSize.current(device) ?? 0

		var streamFrames: UInt32 = 0
		if let streams: [AudioStreamID] = try? HAL.array(
			device, HAL.address(kAudioDevicePropertyStreams, scope: scope)
		), let first = streams.first {
			streamFrames = (try? HAL.value(first, HAL.address(kAudioStreamPropertyLatency))) ?? 0
		}

		return DeviceLatency(
			deviceFrames: deviceFrames,
			safetyOffsetFrames: safety,
			streamFrames: streamFrames,
			bufferFrames: buffer,
			sampleRate: sampleRate
		)
	}
}
