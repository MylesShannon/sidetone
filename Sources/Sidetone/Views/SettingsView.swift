import AppServices
import AudioCore
import SwiftUI

enum SidetoneWindow {
	static let settings = "settings"
}

struct SettingsView: View {
	@Bindable var model: AppModel

	var body: some View {
		TabView {
			GeneralSettings(model: model)
				.tabItem { Label("General", systemImage: "gearshape") }
			AudioSettings(model: model)
				.tabItem { Label("Audio", systemImage: "waveform") }
			PresetSettings(model: model)
				.tabItem { Label("Presets", systemImage: "bookmark") }
			ShortcutSettings(model: model)
				.tabItem { Label("Shortcuts", systemImage: "command") }
			AboutSettings()
				.tabItem { Label("About", systemImage: "info.circle") }
		}
		// The width is fixed because the tab bar lives in the title bar on macOS 26
		// and collapses into an overflow menu when it does not fit, which needs about
		// 520 points here. Height follows the selected pane, the way tabbed
		// preference windows have always behaved, so a short pane is not mostly empty.
		.frame(width: 640)
		.frame(minHeight: 200)
	}
}

private struct GeneralSettings: View {
	@Bindable var model: AppModel
	@State private var launchAtLogin = LoginItem.isEnabled
	@State private var loginError: String?

	var body: some View {
		Form {
			Toggle("Open Sidetone at login", isOn: $launchAtLogin)
				.onChange(of: launchAtLogin) { _, enabled in
					do {
						try LoginItem.set(enabled)
						loginError = nil
					} catch {
						launchAtLogin = LoginItem.isEnabled
						loginError = "macOS refused the login item: \(error.localizedDescription)"
					}
				}

			Toggle("Start monitoring when Sidetone opens", isOn: Binding(
				get: { model.settings.data.startMonitoringOnLaunch },
				set: { model.settings.data.startMonitoringOnLaunch = $0 }
			))

			Toggle(isOn: Binding(
				get: { model.settings.data.checkForUpdates },
				set: { model.setChecksForUpdates($0) }
			)) {
				Text("Check for updates automatically")
				Text("Sidetone asks for permission before installing anything.")
			}

			LabeledContent("Updates") {
				Button("Check Now") { model.updater.checkNow() }
					.disabled(!model.updater.canCheck)
			}

			if LoginItem.requiresApproval {
				LabeledContent("Login item") {
					Button("Open Login Items settings") { LoginItem.openSystemSettings() }
				}
			}
			if let loginError {
				Text(loginError).font(.caption).foregroundStyle(Theme.warning)
			}
		}
		.formStyle(.grouped)
	}
}

private struct AudioSettings: View {
	@Bindable var model: AppModel

	var body: some View {
		Form {
			Picker(selection: Binding(
				get: { model.settings.data.latency },
				set: { model.setLatency($0) }
			)) {
				ForEach(LatencyProfile.allCases, id: \.self) { profile in
					Text(profile.displayName).tag(profile)
				}
			} label: {
				Text("Latency")
				Text(model.settings.data.latency.detail)
			}

			Toggle(isOn: Binding(
				get: { model.settings.data.safetyLimiter },
				set: { model.setSafetyLimiter($0) }
			)) {
				Text("Safety limiter")
				Text("Holds the output below full scale so feedback or a mis-set gain cannot get painful.")
			}

			Toggle("Warn about feedback", isOn: Binding(
				get: { model.settings.data.feedbackGuard },
				set: { model.settings.data.feedbackGuard = $0 }
			))

			LabeledContent("Measured") {
				VStack(alignment: .leading, spacing: 2) {
					Text(model.latencyDescription)
					if model.isRunning {
						Text("\(model.snapshot.underruns) dropouts, \(model.snapshot.overruns) overruns")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.formStyle(.grouped)
	}
}

private struct PresetSettings: View {
	@Bindable var model: AppModel
	@State private var newName = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			List {
				ForEach(model.settings.data.presets) { preset in
					HStack {
						VStack(alignment: .leading) {
							Text(preset.name)
							Text(summary(for: preset))
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
								.truncationMode(.middle)
						}
						Spacer()
						Button("Use") { model.apply(preset) }
						Button(role: .destructive) {
							model.removePreset(preset)
						} label: {
							Image(systemName: "trash")
						}
						.buttonStyle(.accessoryBar)
						.help("Delete this preset")
						.accessibilityLabel("Delete \(preset.name)")
					}
				}
			}
			.overlay {
				if model.settings.data.presets.isEmpty {
					Text("Save the current devices and gain as a preset.")
						.foregroundStyle(.secondary)
				}
			}

			HStack {
				TextField("Preset name", text: $newName)
					.onSubmit(save)
				Button("Save current", action: save)
					.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
			}
		}
		.padding()
	}

	private func save() {
		let name = newName.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty else { return }
		model.capturePreset(named: name)
		newName = ""
	}

	private func summary(for preset: Preset) -> String {
		let input = preset.input?.name ?? "Default input"
		let output = preset.output?.name ?? "Default output"
		return "\(input) → \(output), \(Decibels.format(preset.gainDecibels))"
	}
}

private struct ShortcutSettings: View {
	@Bindable var model: AppModel

	var body: some View {
		Form {
			HotKeyRecorder(
				title: "Toggle monitoring",
				combo: Binding(
					get: { model.settings.data.toggleHotKey },
					set: { model.settings.data.toggleHotKey = $0 }
				),
				onChange: model.registerHotKeys
			)

			HotKeyRecorder(
				title: "Hold to mute",
				combo: Binding(
					get: { model.settings.data.pushToMuteHotKey },
					set: { model.settings.data.pushToMuteHotKey = $0 }
				),
				onChange: model.registerHotKeys
			)

			Text("Shortcuts work while other apps are in front. Hold to mute stays muted only while the keys are held.")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.formStyle(.grouped)
	}
}

private struct AboutSettings: View {
	private static let repository = URL(string: "https://github.com/MylesShannon/sidetone")!

	private var version: String {
		"Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
	}

	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: "waveform")
				.font(.system(size: 40))
				.foregroundStyle(Theme.accent)
			Text("Sidetone").font(.title2.bold())
			Text(version).font(.caption).foregroundStyle(.secondary)
			Text("Hear your own microphone, with your system audio, through whichever output you choose.")
				.font(.callout)
				.multilineTextAlignment(.center)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 40)
			Text("By Myles Shannon")
				.font(.callout)
				.foregroundStyle(.secondary)
			Link("github.com/MylesShannon/sidetone", destination: Self.repository)
				.font(.caption)
			Text("MIT licensed")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
