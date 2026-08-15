import AVFoundation

/// Decides whether an `AVAudioEngineConfigurationChange` is worth restarting for.
///
/// Starting the engine posts one of these on some devices, the built-in speakers
/// among them, with nothing about the format actually different. Restarting in
/// response posts another, and the engine ends up cycling: monitoring flickers on
/// and off until something interrupts it.
///
/// Reacting once adopts the new format as the baseline, so a change is only ever
/// acted on a single time.
public struct ConfigurationChangeFilter: Sendable {
	/// Only the rate and the channel count decide anything, so those are what gets
	/// kept. Holding the format object instead would drag `AVAudioFormat` into this
	/// type's stored state, and it is only `Sendable` in newer toolchains.
	private var baseline: (sampleRate: Double, channels: AVAudioChannelCount)?

	public init(baseline: AVAudioFormat?) {
		self.baseline = baseline.map { ($0.sampleRate, $0.channelCount) }
	}

	public mutating func shouldRestart(for current: AVAudioFormat?) -> Bool {
		guard let baseline, let current else { return false }
		guard baseline.sampleRate != current.sampleRate
			|| baseline.channels != current.channelCount
		else { return false }
		self.baseline = (current.sampleRate, current.channelCount)
		return true
	}
}
