import AudioToolbox
import AudioDevices
import CoreAudio

public enum AudioUnitError: Error, CustomStringConvertible {
	case componentMissing
	case failed(step: String, status: OSStatus)

	public var description: String {
		switch self {
		case .componentMissing: "The system HAL audio unit is unavailable"
		case let .failed(step, status): "Input unit \(step) failed with status \(status)"
		}
	}

	public var status: OSStatus? {
		switch self {
		case .componentMissing: nil
		case let .failed(_, status): status
		}
	}
}

/// A HAL input unit wrapping one capture device.
///
/// `AVAudioEngine` is deliberately not used for capture: an engine always brings
/// up an output IO unit as well, which would open the default output device behind
/// the user's back and can force a Bluetooth headset into low quality headset mode.
/// A bare input unit opens the input device and nothing else.
public final class InputCaptureUnit: @unchecked Sendable {
	public typealias Handler = @Sendable (UnsafeMutableAudioBufferListPointer, Int) -> Void

	public let channels: Int
	public let sampleRate: Double

	private var unit: AudioUnit?
	private let maxFrames: UInt32
	private let handler: Handler
	private let bufferList: UnsafeMutableAudioBufferListPointer
	private var running = false

	public init(
		deviceID: AudioDeviceID,
		channels: Int,
		sampleRate: Double,
		maxFrames: UInt32,
		handler: @escaping Handler
	) throws {
		self.channels = max(1, channels)
		self.sampleRate = sampleRate
		self.maxFrames = maxFrames
		self.handler = handler

		bufferList = AudioBufferList.allocate(maximumBuffers: self.channels)
		for index in 0 ..< self.channels {
			let bytes = Int(maxFrames) * MemoryLayout<Float>.size
			let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<Float>.alignment)
			memory.initializeMemory(as: Float.self, repeating: 0, count: Int(maxFrames))
			bufferList[index] = AudioBuffer(
				mNumberChannels: 1,
				mDataByteSize: UInt32(bytes),
				mData: memory
			)
		}

		try configure(deviceID: deviceID)
	}

	deinit {
		if let unit {
			AudioOutputUnitStop(unit)
			AudioUnitUninitialize(unit)
			AudioComponentInstanceDispose(unit)
		}
		for buffer in bufferList {
			buffer.mData?.deallocate()
		}
		free(bufferList.unsafeMutablePointer)
	}

	public func start() throws {
		guard let unit, !running else { return }
		let status = AudioOutputUnitStart(unit)
		guard status == noErr else { throw AudioUnitError.failed(step: "start", status: status) }
		running = true
	}

	public func stop() {
		guard let unit, running else { return }
		AudioOutputUnitStop(unit)
		running = false
	}

	private func configure(deviceID: AudioDeviceID) throws {
		var description = AudioComponentDescription(
			componentType: kAudioUnitType_Output,
			componentSubType: kAudioUnitSubType_HALOutput,
			componentManufacturer: kAudioUnitManufacturer_Apple,
			componentFlags: 0,
			componentFlagsMask: 0
		)
		guard let component = AudioComponentFindNext(nil, &description) else {
			throw AudioUnitError.componentMissing
		}

		var instance: AudioUnit?
		try check(AudioComponentInstanceNew(component, &instance), "create")
		guard let unit = instance else { throw AudioUnitError.componentMissing }
		self.unit = unit

		var enable: UInt32 = 1
		try check(AudioUnitSetProperty(
			unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
			&enable, UInt32(MemoryLayout<UInt32>.size)
		), "enable input")

		var disable: UInt32 = 0
		try check(AudioUnitSetProperty(
			unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
			&disable, UInt32(MemoryLayout<UInt32>.size)
		), "disable output")

		var device = deviceID
		try check(AudioUnitSetProperty(
			unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
			&device, UInt32(MemoryLayout<AudioDeviceID>.size)
		), "select device")

		var frames = maxFrames
		try check(AudioUnitSetProperty(
			unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
			&frames, UInt32(MemoryLayout<UInt32>.size)
		), "set maximum frames")

		var format = AudioStreamBasicDescription(
			mSampleRate: sampleRate,
			mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
			mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
			mFramesPerPacket: 1,
			mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
			mChannelsPerFrame: UInt32(channels),
			mBitsPerChannel: 32,
			mReserved: 0
		)
		try check(AudioUnitSetProperty(
			unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
			&format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		), "set stream format")

		var callback = AURenderCallbackStruct(
			inputProc: inputCallback,
			inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
		)
		try check(AudioUnitSetProperty(
			unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
			&callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
		), "set input callback")

		try check(AudioUnitInitialize(unit), "initialize")
	}

	fileprivate func deliver(
		_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
		_ timeStamp: UnsafePointer<AudioTimeStamp>,
		_ bus: UInt32,
		_ frameCount: UInt32
	) -> OSStatus {
		guard let unit else { return noErr }

		// The buffers hold maxFrames, and the byte sizes below are what tell
		// AudioUnitRender how much room it has. A slice larger than the maximum this
		// unit was configured with should be impossible, so refuse it rather than
		// describe the buffers as bigger than they are.
		guard frameCount <= maxFrames else { return kAudio_ParamError }

		let bytes = UInt32(frameCount) * UInt32(MemoryLayout<Float>.size)
		for index in 0 ..< bufferList.count {
			bufferList[index].mDataByteSize = bytes
		}

		let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, bufferList.unsafeMutablePointer)
		guard status == noErr else { return status }

		handler(bufferList, Int(frameCount))
		return noErr
	}

	private func check(_ status: OSStatus, _ step: String) throws {
		guard status == noErr else { throw AudioUnitError.failed(step: step, status: status) }
	}
}

private let inputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frameCount, _ in
	let unit = Unmanaged<InputCaptureUnit>.fromOpaque(refCon).takeUnretainedValue()
	return unit.deliver(flags, timeStamp, bus, frameCount)
}
