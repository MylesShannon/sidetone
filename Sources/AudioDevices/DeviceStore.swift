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

	public func defaultInput() -> AudioDevice? { device(uid: defaultInputUID) }
	public func defaultOutput() -> AudioDevice? { device(uid: defaultOutputUID) }

	/// Reports a change only when there is one. Starting to monitor a default device
	/// makes the HAL build its own private aggregate around it, and that posts a
	/// device list change the moment monitoring starts. Those aggregates are filtered
	/// out, so the list is identical, and passing the news on restarts monitoring for
	/// nothing: it stops and starts again a second after being switched on.
	public func refresh() {
		let updated = source.allDevices()
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		let input = source.defaultDeviceUID(input: true)
		let output = source.defaultDeviceUID(input: false)

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
