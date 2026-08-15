import AppKit
import AppServices
import SwiftUI

/// Click, then press a shortcut. Escape cancels, Delete clears.
struct HotKeyRecorder: View {
	let title: String
	@Binding var combo: KeyCombo?
	let onChange: () -> Void

	@State private var isRecording = false
	@State private var monitor: Any?

	var body: some View {
		HStack {
			Text(title)
			Spacer()
			Button(label) {
				isRecording ? stopRecording() : startRecording()
			}
			.frame(minWidth: 120)

			Button {
				combo = nil
				onChange()
			} label: {
				Image(systemName: "xmark.circle.fill")
			}
			.buttonStyle(.borderless)
			.foregroundStyle(.secondary)
			.disabled(combo == nil)
			.help("Clear this shortcut")
		}
		.onDisappear(perform: stopRecording)
	}

	private var label: String {
		if isRecording { return "Press keys…" }
		return combo?.displayString ?? "Click to set"
	}

	private func startRecording() {
		isRecording = true
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			let keyCode = UInt32(event.keyCode)
			let flags = event.modifierFlags.rawValue
			MainActor.assumeIsolated { record(keyCode: keyCode, flags: flags) }
			// Swallow the keystroke so recording a shortcut cannot trigger anything.
			return nil
		}
	}

	private func record(keyCode: UInt32, flags: UInt) {
		let escape: UInt32 = 53
		guard keyCode != escape else {
			stopRecording()
			return
		}
		let modifiers = KeyCombo.carbonModifiers(fromCocoa: flags)
		guard modifiers != 0 else { return }
		combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
		onChange()
		stopRecording()
	}

	private func stopRecording() {
		isRecording = false
		if let monitor {
			NSEvent.removeMonitor(monitor)
			self.monitor = nil
		}
	}
}
