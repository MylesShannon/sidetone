import AudioCore
import AudioDevices
import Foundation

/// A named device pair and gain, switchable from the menu bar.
public struct Preset: Codable, Identifiable, Equatable, Sendable {
	public var id: UUID
	public var name: String
	public var input: DeviceRef?
	public var output: DeviceRef?
	public var channelMode: InputChannelMode?
	public var gainDecibels: Double
	public var latency: LatencyProfile

	public init(
		id: UUID = UUID(),
		name: String,
		input: DeviceRef?,
		output: DeviceRef?,
		channelMode: InputChannelMode?,
		gainDecibels: Double,
		latency: LatencyProfile
	) {
		self.id = id
		self.name = name
		self.input = input
		self.output = output
		self.channelMode = channelMode
		self.gainDecibels = gainDecibels
		self.latency = latency
	}
}
