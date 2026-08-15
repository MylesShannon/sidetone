import CoreAudio
import Foundation

/// Everything the app needs to learn about audio hardware. The protocol exists so
/// device handling can be verified without plugging anything in.
public protocol DeviceSource: Sendable {
	func allDevices() -> [AudioDevice]
	func defaultDeviceUID(input: Bool) -> String?
}

public struct SystemDeviceSource: DeviceSource {
	public init() {}

	public func allDevices() -> [AudioDevice] {
		let ids: [AudioDeviceID] = (try? HAL.array(
			AudioObjectID(kAudioObjectSystemObject),
			HAL.address(kAudioHardwarePropertyDevices)
		)) ?? []
		return ids.compactMap(Self.describe)
	}

	public func defaultDeviceUID(input: Bool) -> String? {
		let selector = input
			? kAudioHardwarePropertyDefaultInputDevice
			: kAudioHardwarePropertyDefaultOutputDevice
		guard let id: AudioDeviceID = try? HAL.value(
			AudioObjectID(kAudioObjectSystemObject), HAL.address(selector)
		) else { return nil }
		return try? HAL.string(id, HAL.address(kAudioDevicePropertyDeviceUID))
	}

	static func describe(_ id: AudioDeviceID) -> AudioDevice? {
		// Skip the aggregate CoreAudio makes for whoever opens the default device,
		// including the one it makes for us. Offering somebody our own plumbing as an
		// input is confusing at best.
		guard !HAL.isPrivateAggregate(id) else { return nil }
		guard let uid = try? HAL.string(id, HAL.address(kAudioDevicePropertyDeviceUID)) else { return nil }
		let name = (try? HAL.string(id, HAL.address(kAudioObjectPropertyName))) ?? uid
		let transportCode: UInt32 = (try? HAL.value(id, HAL.address(kAudioDevicePropertyTransportType))) ?? 0
		let sampleRate: Double = (try? HAL.value(id, HAL.address(kAudioDevicePropertyNominalSampleRate))) ?? 48000

		let inputs = HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput)
		let outputs = HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
		guard inputs > 0 || outputs > 0 else { return nil }

		let dataSource: UInt32? = outputs > 0
			? try? HAL.value(id, HAL.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput))
			: nil

		var inputTerminal: UInt32?
		if inputs > 0,
		   let streams: [AudioStreamID] = try? HAL.array(
		   	id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
		   ), let first = streams.first {
			inputTerminal = try? HAL.value(first, HAL.address(kAudioStreamPropertyTerminalType))
		}

		return AudioDevice(
			id: id,
			uid: uid,
			name: name,
			transport: TransportType(rawValue: transportCode),
			inputChannels: inputs,
			outputChannels: outputs,
			sampleRate: sampleRate,
			outputDataSource: dataSource,
			inputKind: InputKind(terminalType: inputTerminal)
		)
	}
}

/// Fixed device list for tests.
public struct StubDeviceSource: DeviceSource {
	public var devices: [AudioDevice]
	public var defaultInputUID: String?
	public var defaultOutputUID: String?

	public init(devices: [AudioDevice], defaultInputUID: String? = nil, defaultOutputUID: String? = nil) {
		self.devices = devices
		self.defaultInputUID = defaultInputUID
		self.defaultOutputUID = defaultOutputUID
	}

	public func allDevices() -> [AudioDevice] { devices }

	public func defaultDeviceUID(input: Bool) -> String? {
		input ? defaultInputUID : defaultOutputUID
	}
}
