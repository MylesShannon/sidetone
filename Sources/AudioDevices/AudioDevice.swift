import CoreAudio

public enum DataSourceCode {
	public static let internalSpeaker: UInt32 = 0x6973_706B // 'ispk'
	public static let headphones: UInt32 = 0x6864_706E // 'hdpn'
}

/// What an input is physically listening to, which decides whether it can hear a
/// room at all. A line input cannot, so it cannot feed back through speakers.
public enum InputKind: Sendable {
	case microphone
	case line
	case unknown

	/// Built from the input stream's terminal type. Devices report this either as a
	/// four character code or as the raw USB audio terminal number, and plenty of
	/// them report nothing at all.
	public init(terminalType: UInt32?) {
		switch terminalType {
		case kAudioStreamTerminalTypeMicrophone,
		     kAudioStreamTerminalTypeHeadsetMicrophone,
		     kAudioStreamTerminalTypeReceiverMicrophone,
		     0x0201: // USB audio "microphone", which is what the built-in mic reports
			self = .microphone
		case kAudioStreamTerminalTypeLine:
			self = .line
		default:
			self = .unknown
		}
	}
}

public struct AudioDevice: Identifiable, Hashable, Sendable {
	public let id: AudioDeviceID
	/// Stable across replug and reboot, unlike `id`. This is what gets persisted.
	public let uid: String
	public let name: String
	public let transport: TransportType
	public let inputChannels: Int
	public let outputChannels: Int
	public let sampleRate: Double
	/// Four character data source code for the output, such as `ispk` for the
	/// internal speakers or `hdpn` for the headphone jack.
	public let outputDataSource: UInt32?
	/// What the input listens to, when the device says.
	public let inputKind: InputKind

	public init(
		id: AudioDeviceID,
		uid: String,
		name: String,
		transport: TransportType,
		inputChannels: Int,
		outputChannels: Int,
		sampleRate: Double,
		outputDataSource: UInt32? = nil,
		inputKind: InputKind = .unknown
	) {
		self.id = id
		self.uid = uid
		self.name = name
		self.transport = transport
		self.inputChannels = inputChannels
		self.outputChannels = outputChannels
		self.sampleRate = sampleRate
		self.outputDataSource = outputDataSource
		self.inputKind = inputKind
	}

	public var canInput: Bool { inputChannels > 0 }
	public var canOutput: Bool { outputChannels > 0 }

	/// True only for speakers built into the machine, not for the headphone jack,
	/// which shares the same built-in transport type.
	public var isInternalSpeaker: Bool {
		outputDataSource == DataSourceCode.internalSpeaker
	}

	public var ref: DeviceRef { DeviceRef(uid: uid, name: name) }
}

/// A persisted pointer to a device. Devices are remembered by UID and name so the
/// app can reconnect to the same hardware after a replug, or explain what is gone.
public struct DeviceRef: Codable, Hashable, Sendable {
	public let uid: String
	public let name: String

	public init(uid: String, name: String) {
		self.uid = uid
		self.name = name
	}

	public func resolve(in devices: [AudioDevice]) -> AudioDevice? {
		devices.first { $0.uid == uid }
	}
}
