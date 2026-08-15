import AudioCore
import AudioDevices
import Foundation
import Observation

/// Everything Sidetone remembers between launches.
///
/// Decoding is field by field so that adding a setting in a later version does not
/// throw away someone's existing configuration.
public struct SettingsData: Codable, Equatable, Sendable {
	public var input: DeviceRef?
	public var output: DeviceRef?
	public var channelMode: InputChannelMode?
	public var gainDecibels: Double = 0
	public var muted: Bool = false
	public var latency: LatencyProfile = .auto
	public var startMonitoringOnLaunch: Bool = false
	public var safetyLimiter: Bool = true
	public var feedbackGuard: Bool = true
	public var toggleHotKey: KeyCombo? = .defaultToggle
	public var pushToMuteHotKey: KeyCombo?
	public var presets: [Preset] = []
	public var checkForUpdates: Bool = true

	public init() {}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let defaults = SettingsData()
		input = try container.decodeIfPresent(DeviceRef.self, forKey: .input)
		output = try container.decodeIfPresent(DeviceRef.self, forKey: .output)
		channelMode = try container.decodeIfPresent(InputChannelMode.self, forKey: .channelMode)
		gainDecibels = try container.decodeIfPresent(Double.self, forKey: .gainDecibels) ?? defaults.gainDecibels
		muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? defaults.muted
		latency = try container.decodeIfPresent(LatencyProfile.self, forKey: .latency) ?? defaults.latency
		startMonitoringOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startMonitoringOnLaunch)
			?? defaults.startMonitoringOnLaunch
		safetyLimiter = try container.decodeIfPresent(Bool.self, forKey: .safetyLimiter) ?? defaults.safetyLimiter
		feedbackGuard = try container.decodeIfPresent(Bool.self, forKey: .feedbackGuard) ?? defaults.feedbackGuard
		toggleHotKey = try container.decodeIfPresent(KeyCombo.self, forKey: .toggleHotKey)
		pushToMuteHotKey = try container.decodeIfPresent(KeyCombo.self, forKey: .pushToMuteHotKey)
		presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? defaults.presets
		checkForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdates)
			?? defaults.checkForUpdates
	}
}

@MainActor
@Observable
public final class Settings {
	public var data: SettingsData {
		didSet {
			guard data != oldValue else { return }
			save()
		}
	}

	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let key = "settings"

	public init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		if let stored = defaults.data(forKey: key),
		   let decoded = try? JSONDecoder().decode(SettingsData.self, from: stored)
		{
			data = decoded
		} else {
			data = SettingsData()
		}
	}

	/// Writes immediately. A quit or crash never loses the last change.
	public func save() {
		guard let encoded = try? JSONEncoder().encode(data) else { return }
		defaults.set(encoded, forKey: key)
	}
}
