/// Which channels of a multi-channel input get monitored.
///
/// A two-input interface with a microphone in the first jack should monitor
/// channel one only, centred, not a hard-left signal.
public enum InputChannelMode: Codable, Hashable, Sendable {
	case mono(Int)
	case stereo(left: Int, right: Int)

	public var channelCount: Int {
		switch self {
		case .mono: 1
		case .stereo: 2
		}
	}

	public var indices: [Int] {
		switch self {
		case let .mono(channel): [channel]
		case let .stereo(left, right): [left, right]
		}
	}

	public var displayName: String {
		switch self {
		case let .mono(channel): "Channel \(channel + 1)"
		case let .stereo(left, right): "Channels \(left + 1) and \(right + 1)"
		}
	}

	/// Clamps to what the device actually offers, falling back to mono when a
	/// remembered stereo pair no longer exists.
	public func resolved(availableChannels: Int) -> InputChannelMode {
		let last = max(0, availableChannels - 1)
		switch self {
		case let .mono(channel):
			return .mono(min(channel, last))
		case let .stereo(left, right):
			guard availableChannels >= 2 else { return .mono(0) }
			return .stereo(left: min(left, last), right: min(right, last))
		}
	}

	public static func `default`(availableChannels: Int) -> InputChannelMode {
		availableChannels >= 2 ? .stereo(left: 0, right: 1) : .mono(0)
	}
}
