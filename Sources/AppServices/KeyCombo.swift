import Carbon.HIToolbox
import Foundation

/// A global shortcut, stored as Carbon key and modifier codes because that is what
/// `RegisterEventHotKey` speaks.
public struct KeyCombo: Codable, Hashable, Sendable {
	public var keyCode: UInt32
	public var modifiers: UInt32

	public init(keyCode: UInt32, modifiers: UInt32) {
		self.keyCode = keyCode
		self.modifiers = modifiers
	}

	public static let defaultToggle = KeyCombo(
		keyCode: UInt32(kVK_ANSI_M),
		modifiers: UInt32(cmdKey | optionKey)
	)

	public var displayString: String {
		var result = ""
		if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
		if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
		if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
		if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
		return result + Self.keyName(keyCode)
	}

	/// Converts AppKit's modifier flags, which is what a recorder view receives.
	public static func carbonModifiers(fromCocoa flags: UInt) -> UInt32 {
		var result: UInt32 = 0
		if flags & (1 << 18) != 0 { result |= UInt32(controlKey) }
		if flags & (1 << 19) != 0 { result |= UInt32(optionKey) }
		if flags & (1 << 17) != 0 { result |= UInt32(shiftKey) }
		if flags & (1 << 20) != 0 { result |= UInt32(cmdKey) }
		return result
	}

	static func keyName(_ keyCode: UInt32) -> String {
		if let named = namedKeys[Int(keyCode)] { return named }
		guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
		      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
		else { return "Key \(keyCode)" }

		let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
		return data.withUnsafeBytes { raw -> String in
			guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
				return "Key \(keyCode)"
			}
			var deadKeyState: UInt32 = 0
			var length = 0
			var characters = [UniChar](repeating: 0, count: 4)
			let status = UCKeyTranslate(
				layout,
				UInt16(keyCode),
				UInt16(kUCKeyActionDisplay),
				0,
				UInt32(LMGetKbdType()),
				OptionBits(kUCKeyTranslateNoDeadKeysBit),
				&deadKeyState,
				characters.count,
				&length,
				&characters
			)
			guard status == noErr, length > 0 else { return "Key \(keyCode)" }
			return String(utf16CodeUnits: characters, count: length).uppercased()
		}
	}

	private static let namedKeys: [Int: String] = [
		kVK_Space: "Space",
		kVK_Return: "Return",
		kVK_Escape: "Escape",
		kVK_Tab: "Tab",
		kVK_Delete: "Delete",
		kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
		kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
		kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
		kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
	]
}
