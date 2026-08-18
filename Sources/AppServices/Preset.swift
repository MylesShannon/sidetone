import AudioCore
import AudioDevices
import Foundation

/// A named device pair with the gain and tone that went with it, switchable from the
/// menu bar.
public struct Preset: Codable, Identifiable, Equatable, Sendable {
	public var id: UUID
	public var name: String
	public var input: DeviceRef?
	public var output: DeviceRef?
	public var channelMode: InputChannelMode?
	public var gainDecibels: Double
	public var latency: LatencyProfile
	public var lowCut: Bool
	public var lowCutHertz: Double
	public var bassDecibels: Double
	public var trebleDecibels: Double

	public init(
		id: UUID = UUID(),
		name: String,
		input: DeviceRef?,
		output: DeviceRef?,
		channelMode: InputChannelMode?,
		gainDecibels: Double,
		latency: LatencyProfile,
		lowCut: Bool = false,
		lowCutHertz: Double = ToneStage.defaultCutFrequency,
		bassDecibels: Double = 0,
		trebleDecibels: Double = 0
	) {
		self.id = id
		self.name = name
		self.input = input
		self.output = output
		self.channelMode = channelMode
		self.gainDecibels = gainDecibels
		self.latency = latency
		self.lowCut = lowCut
		self.lowCutHertz = lowCutHertz
		self.bassDecibels = bassDecibels
		self.trebleDecibels = trebleDecibels
	}

	/// Tone arrived after the first release, so a preset saved before it has none of
	/// these keys. Every one of them is optional on the way in, or the whole settings
	/// file fails to decode and someone loses the presets they had.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		name = try container.decode(String.self, forKey: .name)
		input = try container.decodeIfPresent(DeviceRef.self, forKey: .input)
		output = try container.decodeIfPresent(DeviceRef.self, forKey: .output)
		channelMode = try container.decodeIfPresent(InputChannelMode.self, forKey: .channelMode)
		gainDecibels = try container.decode(Double.self, forKey: .gainDecibels)
		latency = try container.decode(LatencyProfile.self, forKey: .latency)
		lowCut = try container.decodeIfPresent(Bool.self, forKey: .lowCut) ?? false
		lowCutHertz = try container.decodeIfPresent(Double.self, forKey: .lowCutHertz)
			?? ToneStage.defaultCutFrequency
		bassDecibels = try container.decodeIfPresent(Double.self, forKey: .bassDecibels) ?? 0
		trebleDecibels = try container.decodeIfPresent(Double.self, forKey: .trebleDecibels) ?? 0
	}
}
