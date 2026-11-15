import SwiftUI

struct SidetoneApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@State private var model = AppModel.shared

	var body: some Scene {
		MenuBarExtra {
			MonitorPanel(model: model)
		} label: {
			MenuBarLabel(symbol: menuBarSymbol, accessibilityLabel: accessibilityLabel)
		}
		.menuBarExtraStyle(.window)

		Window("Sidetone Settings", id: SidetoneWindow.settings) {
			SettingsView(model: model)
		}
		.windowResizability(.contentSize)
		.defaultPosition(.center)
	}

	private var accessibilityLabel: String {
		if model.microphoneDenied { return "Sidetone, needs microphone access" }
		return model.isRunning ? "Sidetone, monitoring" : "Sidetone, stopped"
	}

	private var menuBarSymbol: String {
		if model.microphoneDenied { return "exclamationmark.triangle" }
		if case .failed = model.engine.state, !model.failureSeen { return "exclamationmark.triangle" }
		guard model.isRunning else { return "waveform" }
		return model.settings.data.muted ? "waveform.slash" : "waveform.circle.fill"
	}
}

/// Opens Settings when the app is reopened, because the icon is the one view that
/// lives as long as the app and can reach `openWindow`.
private struct MenuBarLabel: View {
	let symbol: String
	let accessibilityLabel: String
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Image(systemName: symbol)
			.accessibilityLabel(accessibilityLabel)
			.onReceive(NotificationCenter.default.publisher(for: AppDelegate.reopened)) { _ in
				openWindow(id: SidetoneWindow.settings)
				NSApp.activate(ignoringOtherApps: true)
			}
	}
}
