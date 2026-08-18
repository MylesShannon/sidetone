/// Decides whether hardware arriving should start monitoring on its own.
///
/// Kept apart from the model so the awkward cases are settled here rather than
/// argued about in a state machine: it must fire when a device appears, not on every
/// refresh while it stays plugged in, and never when monitoring was switched off on
/// purpose while the device was already there.
public struct AutoStartRule: Sendable {
	private var wasPresent = false

	public init(devicesPresent: Bool = false) {
		wasPresent = devicesPresent
	}

	/// Call on every hardware change. `present` means both remembered devices are
	/// there; `running` means monitoring is already going.
	public mutating func shouldStart(enabled: Bool, present: Bool, running: Bool) -> Bool {
		let arrived = present && !wasPresent
		wasPresent = present
		return enabled && arrived && !running
	}
}
