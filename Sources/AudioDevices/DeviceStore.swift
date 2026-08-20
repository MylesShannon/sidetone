import CoreAudio
import Foundation
import Observation

/// Observable list of audio devices that tracks hardware coming and going.
///
/// `start()` installs HAL listeners and `stop()` removes every one of them, so a
/// quit leaves no callbacks registered against the process.
@MainActor
@Observable
public final class DeviceStore {
	public private(set) var devices: [AudioDevice] = []
	public private(set) var defaultInputUID: String?
	public private(set) var defaultOutputUID: String?

	public var inputs: [AudioDevice] { devices.filter(\.canInput) }
	public var outputs: [AudioDevice] { devices.filter(\.canOutput) }

	/// Called after every refresh, which is how the app notices hardware arriving
	/// or disappearing.
	@ObservationIgnored public var onChange: (() -> Void)?

	private let source: DeviceSource
	private let queue = DispatchQueue(label: "com.mshannon.sidetone.devices")
	private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

	public init(source: DeviceSource = SystemDeviceSource()) {
		self.source = source
		refresh()
	}

	public func device(uid: String?) -> AudioDevice? {
		guard let uid else { return nil }
		return devices.first { $0.uid == uid }
	}

	/// Asked afresh rather than served from the cached UID above.
	///
	/// A cached answer outlives the device it names. The HAL occasionally fails this
	/// question for a moment, and whatever is recorded then, nil or a device on its way
	/// out, is never corrected: a cache that is merely wrong provokes no notification.
	/// The cached value stays as a fallback for the moments the question fails.
	public func defaultInput() -> AudioDevice? {
		resolveDefault(input: true, cached: defaultInputUID, candidates: inputs)
	}

	public func defaultOutput() -> AudioDevice? {
		resolveDefault(input: false, cached: defaultOutputUID, candidates: outputs)
	}

	/// The cached UID first, and the system only when that fails to name a device.
	///
	/// Asking the system every time is a round trip to coreaudiod, and this is read
	/// from a panel that redraws thirty times a second while monitoring: it cost more
	/// processor than the audio did. The cache can still be wrong, and nothing would
	/// correct it, so a miss is worth one live question before falling back.
	private func resolveDefault(
		input: Bool, cached: String?, candidates: [AudioDevice]
	) -> AudioDevice? {
		if let named = device(uid: cached) { return named }
		if let live = source.defaultDeviceUID(input: input), let named = device(uid: live) {
			return named
		}
		return fallback(candidates)
	}

	/// CoreAudio occasionally refuses to name a default device for the whole life of a
	/// process, answering nothing however often it is asked, while another process on
	/// the same Mac is told immediately. Following the system default is still better
	/// served by the built-in device than by refusing to start at all.
	private func fallback(_ candidates: [AudioDevice]) -> AudioDevice? {
		candidates.first { $0.transport == .builtIn } ?? candidates.first
	}

	/// Reports a change only when there is one. Starting to monitor a default device
	/// makes the HAL build its own private aggregate around it, and that posts a
	/// device list change the moment monitoring starts. Those aggregates are filtered
	/// out, so the list is identical, and passing the news on restarts monitoring for
	/// nothing: it stops and starts again a second after being switched on.
	public func refresh() {
		let updated = source.allDevices()
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

		// The HAL sometimes answers the device list and then fails the default device
		// question in the same breath, and a nil recorded here would stick: a cache
		// that is merely wrong provokes no notification to correct it. Keeping the last
		// answer is safe, because a device that has actually gone stops resolving
		// anyway.
		let input = source.defaultDeviceUID(input: true) ?? defaultInputUID
		let output = source.defaultDeviceUID(input: false) ?? defaultOutputUID

		let moved = updated != devices || input != defaultInputUID || output != defaultOutputUID
		devices = updated
		defaultInputUID = input
		defaultOutputUID = output

		guard moved else { return }
		onChange?()
	}

	public func start() {
		guard listeners.isEmpty else { return }
		for selector in [
			kAudioHardwarePropertyDevices,
			kAudioHardwarePropertyDefaultInputDevice,
			kAudioHardwarePropertyDefaultOutputDevice,
		] {
			observe(HAL.address(selector))
		}

		// The first refresh runs in `init`, early enough in a launch that the HAL
		// sometimes has no default device to report yet. Nothing would correct that
		// afterwards, because a cache that is merely wrong provokes no notification.
		refresh()
	}

	public func stop() {
		onChange = nil
		for (address, block) in listeners {
			var address = address
			AudioObjectRemovePropertyListenerBlock(
				AudioObjectID(kAudioObjectSystemObject), &address, queue, block
			)
		}
		listeners.removeAll()
	}

	private func observe(_ address: AudioObjectPropertyAddress) {
		let block: AudioObjectPropertyListenerBlock = { _, _ in
			Task { @MainActor [weak self] in self?.refresh() }
		}
		var mutable = address
		let status = AudioObjectAddPropertyListenerBlock(
			AudioObjectID(kAudioObjectSystemObject), &mutable, queue, block
		)
		guard status == noErr else { return }
		listeners.append((address, block))
	}
}
