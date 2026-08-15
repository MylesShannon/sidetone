import AudioToolbox
import CoreAudio
import Foundation

/// Why monitoring could not start, in words a person can act on.
///
/// CoreAudio reports failures as four character codes wrapped in an `NSError`,
/// which produces panel text like "Error Domain=com.apple.coreaudio.avfaudio
/// Code=1937010544". That tells the user nothing, so every status this app can
/// realistically hit gets translated.
public enum MonitorError: Error, CustomStringConvertible {
	case unsupportedOutputFormat(device: String)
	case outputUnavailable(device: String, status: OSStatus?)
	case inputUnavailable(device: String, status: OSStatus?)

	public var description: String {
		switch self {
		case let .unsupportedOutputFormat(device):
			"\(device) uses an audio format Sidetone cannot render to."

		case let .outputUnavailable(device, status):
			switch status {
			case OSStatus(kAudioHardwareNotRunningError):
				"""
				\(device) refused to start. No app can play to it while it is in this \
				state. Choose another output, or restart to clear it.
				"""
			case OSStatus(kAudioDevicePermissionsError):
				"Another app has exclusive use of \(device)."
			case OSStatus(kAudioHardwareBadDeviceError):
				"\(device) is no longer available."
			default:
				"\(device) would not start."
			}

		case let .inputUnavailable(device, status):
			switch status {
			case OSStatus(kAudioHardwareNotRunningError):
				"\(device) is not providing audio. Choose a different input device."
			case OSStatus(kAudioDevicePermissionsError):
				"Another app has exclusive use of \(device)."
			case OSStatus(kAudioHardwareBadDeviceError):
				"\(device) is no longer available."
			default:
				"\(device) would not start."
			}
		}
	}

	/// Digs the CoreAudio status out of the `NSError` that `AVAudioEngine` throws.
	public static func status(from error: Error) -> OSStatus? {
		let error = error as NSError
		guard error.domain == NSOSStatusErrorDomain || error.domain == "com.apple.coreaudio.avfaudio" else {
			return nil
		}
		return OSStatus(truncatingIfNeeded: error.code)
	}
}
