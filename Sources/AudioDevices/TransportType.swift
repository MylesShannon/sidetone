import CoreAudio

/// How a device is attached to the machine. Drives the automatic latency profile:
/// wireless and aggregate devices need more headroom than wired ones.
public enum TransportType: String, Sendable, Codable {
	case builtIn
	case usb
	case bluetooth
	case airPlay
	case aggregate
	case virtual
	case thunderbolt
	case fireWire
	case pci
	case hdmi
	case displayPort
	case network
	case unknown

	public init(rawValue code: UInt32) {
		switch code {
		case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
		case kAudioDeviceTransportTypeUSB: self = .usb
		case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
		case kAudioDeviceTransportTypeAirPlay: self = .airPlay
		case kAudioDeviceTransportTypeAggregate: self = .aggregate
		case kAudioDeviceTransportTypeVirtual: self = .virtual
		case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
		case kAudioDeviceTransportTypeFireWire: self = .fireWire
		case kAudioDeviceTransportTypePCI: self = .pci
		case kAudioDeviceTransportTypeHDMI: self = .hdmi
		case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
		case kAudioDeviceTransportTypeAVB, kAudioDeviceTransportTypeContinuityCaptureWired,
		     kAudioDeviceTransportTypeContinuityCaptureWireless:
			self = .network
		default: self = .unknown
		}
	}

	public var isWireless: Bool {
		self == .bluetooth || self == .airPlay
	}

	/// Devices whose clock we cannot trust to stay close to the nominal rate.
	public var needsExtraBuffering: Bool {
		isWireless || self == .aggregate || self == .virtual || self == .network
	}

	public var displayName: String {
		switch self {
		case .builtIn: "Built-in"
		case .usb: "USB"
		case .bluetooth: "Bluetooth"
		case .airPlay: "AirPlay"
		case .aggregate: "Aggregate"
		case .virtual: "Virtual"
		case .thunderbolt: "Thunderbolt"
		case .fireWire: "FireWire"
		case .pci: "PCI"
		case .hdmi: "HDMI"
		case .displayPort: "DisplayPort"
		case .network: "Network"
		case .unknown: "Other"
		}
	}
}
