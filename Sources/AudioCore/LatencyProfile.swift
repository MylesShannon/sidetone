import AudioDevices

/// A friendly latency choice, resolved to a hardware buffer size.
/// Declaration order is the order both menus show, so the automatic choice leads.
public enum LatencyProfile: String, CaseIterable, Codable, Sendable {
	case auto
	case low
	case medium
	case high

	/// Buffer sizes the profiles step through. Devices reject anything they cannot
	/// honour, so these are requests rather than guarantees.
	static let tiers: [UInt32] = [64, 128, 256, 512, 1024]

	public var displayName: String {
		switch self {
		case .low: "Low"
		case .medium: "Medium"
		case .high: "High"
		case .auto: "Automatic"
		}
	}

	public var detail: String {
		switch self {
		case .low: "Tightest monitoring, needs wired gear and a quiet machine"
		case .medium: "A good default"
		case .high: "Most forgiving, for busy machines or flaky interfaces"
		case .auto: "Starts as tight as your devices allow, and backs off if it cannot keep up"
		}
	}

	/// `stepUps` lets the engine back off one tier at a time after underruns
	/// without the user having to touch anything.
	public func bufferFrames(inputTransport: TransportType, outputTransport: TransportType, stepUps: Int = 0) -> UInt32 {
		let baseIndex: Int = switch self {
		case .low: 0
		case .medium: 2
		case .high: 3
		case .auto: Self.automaticIndex(inputTransport, outputTransport)
		}
		let index = min(baseIndex + max(0, stepUps), Self.tiers.count - 1)
		return Self.tiers[index]
	}

	/// Wired pairs start at the tightest tier and rely on the engine stepping up if
	/// the machine cannot sustain it. Devices whose clocks cannot be trusted, and
	/// devices we cannot identify, start with room instead.
	private static func automaticIndex(_ input: TransportType, _ output: TransportType) -> Int {
		if input.needsExtraBuffering || output.needsExtraBuffering { return 3 }
		if input == .unknown || output == .unknown { return 2 }
		return 0
	}
}
