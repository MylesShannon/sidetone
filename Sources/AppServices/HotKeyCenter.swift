import Carbon.HIToolbox
import Foundation

/// Global shortcuts via Carbon's `RegisterEventHotKey`.
///
/// Carbon is old but it is the only shortcut API that needs no Accessibility
/// permission, and it reports key release as well as key press, which is what
/// push-to-mute requires.
@MainActor
public final class HotKeyCenter {
	public static let shared = HotKeyCenter()

	private struct Registration {
		let ref: EventHotKeyRef
		let onPress: () -> Void
		let onRelease: (() -> Void)?
	}

	private var registrations: [UInt32: Registration] = [:]
	private var eventHandler: EventHandlerRef?
	private var nextID: UInt32 = 1

	private init() {}

	@discardableResult
	public func register(
		_ combo: KeyCombo,
		onPress: @escaping () -> Void,
		onRelease: (() -> Void)? = nil
	) -> UInt32? {
		installHandlerIfNeeded()

		let id = nextID
		nextID += 1
		var ref: EventHotKeyRef?
		let status = RegisterEventHotKey(
			combo.keyCode,
			combo.modifiers,
			EventHotKeyID(signature: Self.signature, id: id),
			GetApplicationEventTarget(),
			0,
			&ref
		)
		guard status == noErr, let ref else { return nil }

		registrations[id] = Registration(ref: ref, onPress: onPress, onRelease: onRelease)
		return id
	}

	public func unregister(_ id: UInt32) {
		guard let registration = registrations.removeValue(forKey: id) else { return }
		UnregisterEventHotKey(registration.ref)
	}

	/// Part of clean quit: leaves no shortcuts registered against a dead process.
	public func unregisterAll() {
		for id in registrations.keys {
			unregister(id)
		}
		if let eventHandler {
			RemoveEventHandler(eventHandler)
			self.eventHandler = nil
		}
	}

	fileprivate func handle(id: UInt32, pressed: Bool) {
		guard let registration = registrations[id] else { return }
		if pressed {
			registration.onPress()
		} else {
			registration.onRelease?()
		}
	}

	private func installHandlerIfNeeded() {
		guard eventHandler == nil else { return }
		var types = [
			EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
			EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
		]
		InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, types.count, &types, nil, &eventHandler)
	}

	private static let signature: OSType = 0x5354_4F4E // 'STON'
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
	guard let event else { return noErr }
	var hotKeyID = EventHotKeyID()
	let status = GetEventParameter(
		event,
		EventParamName(kEventParamDirectObject),
		EventParamType(typeEventHotKeyID),
		nil,
		MemoryLayout<EventHotKeyID>.size,
		nil,
		&hotKeyID
	)
	guard status == noErr else { return status }

	let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
	MainActor.assumeIsolated {
		HotKeyCenter.shared.handle(id: hotKeyID.id, pressed: pressed)
	}
	return noErr
}
