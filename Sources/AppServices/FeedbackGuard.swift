import AudioDevices

/// Warns before routing an input that can hear the room into speakers in the same
/// room.
///
/// Two things have to be true. The output must be the internal speakers, which the
/// built-in transport type alone cannot tell you because the headphone jack is also
/// built-in: the output data source is what separates them. And the input must be
/// able to pick the speakers up, which a line input cannot.
public enum FeedbackGuard {
	public enum Risk: Equatable, Sendable {
		case microphoneIntoSpeakers
		case unknownInputIntoSpeakers

		public var message: String {
			switch self {
			case .microphoneIntoSpeakers:
				"Monitoring a microphone into the built-in speakers will feed back. Use headphones."
			case .unknownInputIntoSpeakers:
				"""
				Monitoring into the built-in speakers will feed back if this input can hear \
				them. Use headphones.
				"""
			}
		}
	}

	public static func risk(input: AudioDevice?, output: AudioDevice) -> Risk? {
		guard output.isInternalSpeaker else { return nil }
		switch input?.inputKind {
		case .line: return nil
		case .microphone: return .microphoneIntoSpeakers
		case .unknown, nil: return .unknownInputIntoSpeakers
		}
	}
}
