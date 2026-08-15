import SwiftUI

@main
struct SidetoneApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@State private var model = AppModel.shared

	var body: some Scene {
		MenuBarExtra {
			MonitorPanel(model: model)
		} label: {
			Image(systemName: menuBarSymbol)
				.accessibilityLabel(model.isRunning ? "Sidetone, monitoring" : "Sidetone, stopped")
		}
		.menuBarExtraStyle(.window)

		Window("Sidetone Settings", id: SidetoneWindow.settings) {
			SettingsView(model: model)
		}
		.windowResizability(.contentSize)
		.defaultPosition(.center)
	}

	private var menuBarSymbol: String {
		if case .failed = model.engine.state, !model.failureSeen { return "exclamationmark.triangle" }
		guard model.isRunning else { return "waveform" }
		return model.settings.data.muted ? "waveform.slash" : "waveform.circle.fill"
	}
}
