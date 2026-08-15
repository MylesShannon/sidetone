import CoreAudio

/// Reads and writes the hardware IO buffer size, which is the main lever on latency.
public enum BufferSize {
	public static func current(_ device: AudioDeviceID) -> UInt32? {
		try? HAL.value(device, HAL.address(kAudioDevicePropertyBufferFrameSize))
	}

	public static func range(_ device: AudioDeviceID) -> ClosedRange<UInt32> {
		guard let range: AudioValueRange = try? HAL.value(
			device, HAL.address(kAudioDevicePropertyBufferFrameSizeRange)
		) else { return 64 ... 4096 }
		let low = UInt32(max(1, range.mMinimum))
		let high = UInt32(max(range.mMinimum, range.mMaximum))
		return low ... max(low, high)
	}

	/// Clamps to what the device accepts and returns the value actually in effect.
	@discardableResult
	public static func set(_ frames: UInt32, on device: AudioDeviceID) -> UInt32? {
		let allowed = range(device)
		let clamped = min(max(frames, allowed.lowerBound), allowed.upperBound)
		try? HAL.setValue(clamped, on: device, HAL.address(kAudioDevicePropertyBufferFrameSize))
		return current(device)
	}
}
