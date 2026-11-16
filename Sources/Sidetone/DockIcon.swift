import AppKit

/// Sidetone has a Dock icon while one of its windows is open, and none once the last one closes.
@MainActor
enum DockIcon {
	private static var windows = Set<String>()

	static func show(for window: String) {
		windows.insert(window)
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
	}

	static func hide(for window: String) {
		windows.remove(window)
		if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
	}
}
