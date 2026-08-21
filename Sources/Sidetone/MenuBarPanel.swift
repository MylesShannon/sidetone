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

	/// Brings the window down to the height of the panel inside it, keeping the top edge
	/// where it is because the panel hangs from the menu bar.
	///
	/// Only ever downwards. The window grows for the meters by itself; the fault is that
	/// it keeps that height once they go, leaving a shadowed band of nothing above the
	/// panel. The height has to be measured by SwiftUI and passed in: the hosting view
	/// in this window answers `fittingSize` with zero, so anything that asks AppKit how
	/// tall the panel wants to be gets nothing and does nothing.
	static func shrink(toContentHeight height: CGFloat) {
		guard let window = panels.first else { return }
		let target = window
			.frameRect(forContentRect: CGRect(x: 0, y: 0, width: window.frame.width, height: height))
			.height
		guard target < window.frame.height - 0.5 else { return }

		var frame = window.frame
		frame.origin.y = frame.maxY - target
		frame.size.height = target
		window.setFrame(frame, display: true)
	}

	/// Told apart by level rather than class: the panel sits at the pop-up menu level,
	/// the status item's own window lower down at the status bar level, and the
	/// Settings window lower still. The class names for both are private to AppKit and
	/// SwiftUI.
	private static var panels: [NSWindow] {
		NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }
	}

	static var isOpen: Bool {
		!panels.isEmpty
	}

	/// True when something on screen is showing live figures: the panel with its meters,
	/// or the Settings window with its dropout count. When neither is up there is
	/// nobody to show them to, and thirty redraws a second buys nothing.
	static var isWatched: Bool {
		isOpen || NSApp.windows.contains { $0.isVisible && $0.level == .normal }
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
