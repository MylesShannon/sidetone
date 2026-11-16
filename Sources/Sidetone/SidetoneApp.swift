import SwiftUI

struct SidetoneApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@State private var model = AppModel.shared

	var body: some Scene {
		MenuBarExtra {
			MonitorPanel(model: model)
		} label: {
			MenuBarLabel(symbol: menuBarSymbol, attention: attention, accessibilityLabel: accessibilityLabel)
		}
		.menuBarExtraStyle(.window)

		Window("Sidetone Settings", id: SidetoneWindow.settings) {
			SettingsView(model: model)
		}
		.windowResizability(.contentSize)
		.defaultPosition(.center)
	}

	private var attention: String? {
		if model.microphoneDenied { return "microphone access is off" }
		if case .failed = model.engine.state, !model.failureSeen { return "monitoring stopped" }
		return nil
	}

	private var accessibilityLabel: String {
		if let attention { return "Sidetone, needs attention: \(attention)" }
		return model.isRunning ? "Sidetone, monitoring" : "Sidetone, stopped"
	}

	private var menuBarSymbol: String {
		guard model.isRunning else { return "waveform" }
		return model.settings.data.muted ? "waveform.slash" : "waveform.circle.fill"
	}
}

/// Opens Settings when the app is reopened, because the icon is the one view that
/// lives as long as the app and can reach `openWindow`.
private struct MenuBarLabel: View {
	let symbol: String
	let attention: String?
	let accessibilityLabel: String
	@Environment(\.openWindow) private var openWindow
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		icon
			.accessibilityLabel(accessibilityLabel)
			.onReceive(NotificationCenter.default.publisher(for: AppDelegate.reopened)) { _ in
				openWindow(id: SidetoneWindow.settings)
				NSApp.activate(ignoringOtherApps: true)
			}
	}

	@ViewBuilder private var icon: some View {
		if attention != nil, let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
			Image(nsImage: Self.attentionIcon(glyph)).id(colorScheme)
		} else {
			Image(systemName: symbol)
		}
	}

	static func attentionIcon(_ glyph: NSImage) -> NSImage {
		let side: CGFloat = 18, gap: CGFloat = 8, dot: CGFloat = 6
		let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
			let s = glyph.size
			let tinted = NSImage(size: s, flipped: false) { rect in
				glyph.draw(in: rect)
				NSColor.labelColor.set()
				rect.fill(using: .sourceAtop)
				return true
			}
			tinted.draw(in: NSRect(x: (side - s.width) / 2, y: (side - s.height) / 2, width: s.width, height: s.height))
			NSGraphicsContext.current?.compositingOperation = .clear
			NSBezierPath(ovalIn: NSRect(x: side - gap, y: 0, width: gap, height: gap)).fill()
			NSGraphicsContext.current?.compositingOperation = .sourceOver
			NSColor.systemRed.setFill()
			NSBezierPath(ovalIn: NSRect(x: side - gap + (gap - dot) / 2, y: (gap - dot) / 2, width: dot, height: dot)).fill()
			return true
		}
		image.isTemplate = false
		return image
	}
}
