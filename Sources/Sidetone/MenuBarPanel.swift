import AppKit

/// The panel SwiftUI drops from the menu bar icon.
@MainActor
enum MenuBarPanel {
	/// Closes the panel the way clicking the icon does.
	///
	/// Hiding the window works too, but leaves SwiftUI believing the panel is still up
	/// and the icon drawn as pressed. Going through the icon's own action keeps
	/// SwiftUI's idea of the world and the highlight in step.
	static func dismiss() {
		guard isOpen else { return }
		guard let icon else {
			// Nothing to click, so hide the panel outright. A stuck highlight is better
			// than a panel that will not go away.
			panels.forEach { $0.orderOut(nil) }
			return
		}
		icon.performClick(nil)
	}

	/// Told apart by level rather than class: the panel sits at the pop-up menu level,
	/// the status item's own window lower down at the status bar level, and the
	/// Settings window lower still. The class names for both are private to AppKit and
	/// SwiftUI.
	private static var panels: [NSWindow] {
		NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }
	}

	private static var isOpen: Bool {
		!panels.isEmpty
	}

	/// The status item's button is buried inside its window rather than being the
	/// content view, so it has to be dug out.
	private static var icon: NSButton? {
		NSApp.windows
			.filter { $0.level == .statusBar }
			.compactMap { button(in: $0.contentView) }
			.first
	}

	private static func button(in view: NSView?) -> NSButton? {
		guard let view else { return nil }
		if let button = view as? NSButton { return button }
		for subview in view.subviews {
			if let found = button(in: subview) { return found }
		}
		return nil
	}
}
