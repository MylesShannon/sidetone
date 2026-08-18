import AppServices
import AudioCore
import AudioDevices
import SwiftUI

/// Hover and pressed states for icon-only controls, which otherwise give no sign
/// that they can be clicked. Follows Control Center: a translucent rounded fill
/// under the cursor rather than permanent button chrome.
private struct GlyphButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		Glyph(configuration: configuration)
	}

	private struct Glyph: View {
		let configuration: ButtonStyleConfiguration
		@State private var hovering = false

		var body: some View {
			let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
			return configuration.label
				.frame(width: 22, height: 22)
				.background(shape.fill(Color.primary.opacity(fill)))
				.contentShape(shape)
				.onHover { hovering = $0 }
		}

		private var fill: Double {
			if configuration.isPressed { return 0.18 }
			return hovering ? 0.09 : 0
		}
	}
}

/// The panel is a fixed width, so its controls are given exact widths derived from it
/// rather than being told to fill. Filling only works while SwiftUI offers a width,
/// and it stops offering one as soon as the panel's window has to be re-sized.
private enum Metrics {
	static let panel: CGFloat = 340
	static let inset: CGFloat = 16
	static let icon: CGFloat = 16
	static let gap: CGFloat = 8
	static let glyph: CGFloat = 22
	static let readout: CGFloat = 58

	static let content = panel - inset * 2
	/// A control on a row that begins with an icon.
	static let control = content - icon - gap
	/// A control indented under the row above it.
	static let indented = control - icon - gap
	static let slider = content - glyph - readout - gap * 2
}

/// A real `NSPopUpButton`, because no SwiftUI menu will take a width. `Menu` sizes
/// itself to its title and ignores any frame put on it or its label, and `Picker`
/// leaves its button at that size, centred in whatever space it is given.
///
/// A definite width is what makes this survive the panel resizing. Builds linked
/// against newer SDKs answer a re-size by laying the panel out at its ideal size,
/// where anything flexible shrinks to its own content and stays there.
private struct PopUpButton: NSViewRepresentable {
	let titles: [String]
	let selection: Int
	let width: CGFloat
	let onSelect: (Int) -> Void

	func makeNSView(context: Context) -> NSPopUpButton {
		let button = NSPopUpButton(frame: .zero, pullsDown: false)
		button.target = context.coordinator
		button.action = #selector(Coordinator.pick(_:))
		button.cell?.lineBreakMode = .byTruncatingTail
		return button
	}

	func updateNSView(_ button: NSPopUpButton, context: Context) {
		context.coordinator.onSelect = onSelect

		if button.itemTitles != titles {
			button.removeAllItems()
			// Added through the menu because `addItem(withTitle:)` drops a title that
			// repeats one already there, and two devices can share a name.
			for title in titles {
				button.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
			}
		}
		if titles.indices.contains(selection), button.indexOfSelectedItem != selection {
			button.selectItem(at: selection)
		}
	}

	func sizeThatFits(_: ProposedViewSize, nsView: NSPopUpButton, context _: Context) -> CGSize? {
		CGSize(width: width, height: nsView.intrinsicContentSize.height)
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(onSelect: onSelect)
	}

	@MainActor
	final class Coordinator: NSObject {
		var onSelect: (Int) -> Void

		init(onSelect: @escaping (Int) -> Void) {
			self.onSelect = onSelect
		}

		@objc func pick(_ sender: NSPopUpButton) {
			onSelect(sender.indexOfSelectedItem)
		}
	}
}

/// The window that drops down from the menu bar icon.
struct MonitorPanel: View {
	@Bindable var model: AppModel
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			header
			if let message = model.statusMessage {
				notice(message, isWarning: true)
			}
			if let risk = model.feedbackRisk {
				notice(risk.message, isWarning: true)
			}

			// Empty meters read as broken containers rather than as silence, so they
			// only appear when there is something to show.
			if model.isRunning {
				meters
				Divider().overlay(Theme.panelDivider)
			}
			deviceControls
			gainControls
			Divider().overlay(Theme.panelDivider)
			footer
		}
		.padding(Metrics.inset)
		.frame(width: Metrics.panel)
		// The menu bar window grows with the panel but will not shrink again, which
		// leaves an empty shadowed strip where the meters were. Changing identity with
		// the panel's shape makes SwiftUI build it afresh and size the window from
		// scratch. Setting the window's frame directly also works, but only in builds
		// linked against older SDKs: newer ones respond by laying the panel out at its
		// ideal size, where every menu shrinks to the width of its own text.
		.id(layout)
		.onAppear { model.panelOpened() }
	}

	/// Names the panel's shape: everything that can appear or disappear and so change
	/// how tall the panel is.
	private var layout: String {
		"\(model.isRunning)|\(model.statusMessage ?? "")|\(model.feedbackRisk?.message ?? "")"
	}

	private var header: some View {
		HStack {
			VStack(alignment: .leading, spacing: 1) {
				Text("Sidetone").font(.headline)
				Text(model.latencyDescription)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("Monitoring", isOn: Binding(
				get: { model.isRunning },
				set: { _ in model.toggle() }
			))
			.toggleStyle(.switch)
			.labelsHidden()
			.accessibilityLabel("Monitoring")
		}
	}

	private var meters: some View {
		VStack(spacing: 8) {
			LevelMeterView(
				peak: model.snapshot.peak,
				rms: model.snapshot.rms,
				clipping: model.snapshot.clipping,
				isActive: model.isRunning
			)
			SpectrumView(bands: model.snapshot.bands, isActive: model.isRunning)
		}
	}

	private var deviceControls: some View {
		VStack(alignment: .leading, spacing: 10) {
			devicePicker(
				title: "Input",
				systemImage: "mic",
				devices: model.devices.inputs,
				stored: model.settings.data.input,
				resolved: model.selectedInput,
				onSelect: model.select(input:)
			)

			if let input = model.selectedInput, input.inputChannels > 2 {
				channelPicker(for: input)
			}

			devicePicker(
				title: "Output",
				systemImage: "headphones",
				devices: model.devices.outputs,
				stored: model.settings.data.output,
				resolved: model.selectedOutput,
				onSelect: model.select(output:)
			)

			latencyPicker
		}
	}

	private var latencyPicker: some View {
		let profiles = LatencyProfile.allCases
		return HStack(spacing: Metrics.gap) {
			Label("Latency", systemImage: "timer")
				.labelStyle(.iconOnly)
				.foregroundStyle(.secondary)
				.frame(width: Metrics.icon)

			PopUpButton(
				titles: profiles.map(\.displayName),
				selection: profiles.firstIndex(of: model.settings.data.latency) ?? 0,
				width: Metrics.control
			) { choice in
				guard profiles.indices.contains(choice) else { return }
				model.setLatency(profiles[choice])
			}
			.accessibilityLabel("Latency profile")
		}
	}

	private func devicePicker(
		title: String,
		systemImage: String,
		devices: [AudioDevice],
		stored: DeviceRef?,
		resolved: AudioDevice?,
		onSelect: @escaping (AudioDevice?) -> Void
	) -> some View {
		// Nothing stored means follow whatever macOS is using, so the first entry
		// stands for that and says which device that currently is.
		let followsDefault = stored == nil
		let pinned = devices.firstIndex { $0.uid == stored?.uid }
		let absent = followsDefault || pinned != nil ? nil : stored?.name

		var titles = [resolved.map { "System default (\($0.name))" } ?? "System default"]
		if let absent { titles.append("\(absent) (not connected)") }
		titles += devices.map(\.name)

		// One entry for the default, and another for a pinned device that is not here.
		let offset = absent == nil ? 1 : 2
		let selected = followsDefault ? 0 : (pinned.map { $0 + offset } ?? 1)

		return devicePickerRow(
			title: title,
			systemImage: systemImage,
			titles: titles,
			selected: selected
		) { choice in
			guard choice != 0 else { return onSelect(nil) }
			let index = choice - offset
			guard devices.indices.contains(index) else { return }
			onSelect(devices[index])
		}
	}

	private func devicePickerRow(
		title: String,
		systemImage: String,
		titles: [String],
		selected: Int,
		onChoose: @escaping (Int) -> Void
	) -> some View {
		HStack(spacing: Metrics.gap) {
			Label(title, systemImage: systemImage)
				.labelStyle(.iconOnly)
				.foregroundStyle(.secondary)
				.frame(width: Metrics.icon)

			PopUpButton(titles: titles, selection: selected, width: Metrics.control, onSelect: onChoose)
				.accessibilityLabel("\(title) device")
		}
	}

	private func channelPicker(for input: AudioDevice) -> some View {
		let current = model.settings.data.channelMode ?? .default(availableChannels: input.inputChannels)
		let titles = ["Channels 1 and 2"] + (0 ..< input.inputChannels).map { "Channel \($0 + 1)" }
		let selected = switch current {
		case .stereo: 0
		case let .mono(channel): channel + 1
		}

		return HStack(spacing: Metrics.gap) {
			Spacer().frame(width: Metrics.icon)
			PopUpButton(titles: titles, selection: selected, width: Metrics.indented) { choice in
				model.select(channelMode: choice == 0 ? .stereo(left: 0, right: 1) : .mono(choice - 1))
			}
			.accessibilityLabel("Input channels")
		}
	}

	private var gainControls: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: Metrics.gap) {
				Button {
					model.setMuted(!model.settings.data.muted)
				} label: {
					Image(systemName: model.settings.data.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
						.frame(width: 16)
				}
				.buttonStyle(GlyphButtonStyle())
				.foregroundStyle(model.settings.data.muted ? Theme.warning : Color.secondary)
				.help(model.settings.data.muted ? "Unmute" : "Mute")
				.accessibilityLabel(model.settings.data.muted ? "Unmute" : "Mute")

				Slider(
					value: Binding(
						get: { model.settings.data.gainDecibels },
						set: { model.setGain($0) }
					),
					in: -24 ... 48
				)
				.frame(width: Metrics.slider)
				.disabled(model.settings.data.muted)

				Text(Decibels.format(model.settings.data.gainDecibels))
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
					.frame(width: Metrics.readout, alignment: .trailing)
			}
		}
	}

	private var footer: some View {
		HStack {
			Button {
				// Ordered out before the window opens, because the panel stays up
				// otherwise and sits over whatever it just opened.
				MenuBarPanel.dismiss()
				openWindow(id: SidetoneWindow.settings)
				NSApp.activate(ignoringOtherApps: true)
			} label: {
				Image(systemName: "gearshape")
			}
			.buttonStyle(.accessoryBar)
			.help("Settings")
			.accessibilityLabel("Settings")

			if !model.settings.data.presets.isEmpty {
				Menu("Presets") {
					ForEach(model.settings.data.presets) { preset in
						Button(preset.name) { model.apply(preset) }
					}
				}
				.menuStyle(.borderlessButton)
				.fixedSize()
			}

			Spacer()

			Button("Quit") {
				NSApp.terminate(nil)
			}
			.buttonStyle(.accessoryBar)
		}
		.font(.callout)
	}

	private func notice(_ message: String, isWarning: Bool) -> some View {
		HStack(alignment: .top, spacing: 6) {
			Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
				.foregroundStyle(isWarning ? Theme.warning : Theme.accent)
			Text(message)
				.font(.caption)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 6).fill(Theme.track))
	}
}
