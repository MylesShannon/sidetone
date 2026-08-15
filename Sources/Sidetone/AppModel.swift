import AVFoundation
import AppKit
import AppServices
import AudioCore
import AudioDevices
import Foundation
import Observation
import UserNotifications

/// Ties settings, hardware and the engine together, and is the only thing the
/// views talk to.
@MainActor
@Observable
final class AppModel {
	static let shared = AppModel()

	let settings = Settings()
	let devices = DeviceStore()
	let engine = MonitorEngine()

	private(set) var snapshot = AudioSnapshot.silent
	private(set) var statusMessage: String?
	private(set) var microphoneDenied = false

	/// The menu bar badge exists to get the panel opened. Once it is open the message
	/// is being read, so the badge has done its work and the menu bar goes quiet.
	private(set) var failureSeen = false

	@ObservationIgnored lazy var updater = Updater(checksAutomatically: settings.data.checkForUpdates)

	/// Set when monitoring stopped because hardware vanished, so the same pair can
	/// be picked back up when it returns.
	@ObservationIgnored private var awaitingReconnect = false
	@ObservationIgnored private var isStarting = false
	@ObservationIgnored private var latencyStepUps = 0
	@ObservationIgnored private var meterTimer: Timer?
	@ObservationIgnored private var toggleHotKeyID: UInt32?
	@ObservationIgnored private var pushToMuteHotKeyID: UInt32?
	@ObservationIgnored private var pushToMuteWasMuted = false
	@ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
	@ObservationIgnored private var wasRunningBeforeSleep = false

	var isRunning: Bool { engine.state == .running }

	var selectedInput: AudioDevice? {
		devices.device(uid: settings.data.input?.uid) ?? devices.defaultInput()
	}

	var selectedOutput: AudioDevice? {
		devices.device(uid: settings.data.output?.uid) ?? devices.defaultOutput()
	}

	var feedbackRisk: FeedbackGuard.Risk? {
		guard settings.data.feedbackGuard, let output = selectedOutput else { return nil }
		return FeedbackGuard.risk(input: selectedInput, output: output)
	}

	var latencyDescription: String {
		guard isRunning else { return "Not monitoring" }
		let milliseconds = engine.estimatedLatencyMilliseconds
		return String(format: "about %.1f ms at %d frames", milliseconds, Int(engine.bufferFrames))
	}

	// MARK: - Lifecycle

	func boot() {
		devices.start()
		devices.onChange = { [weak self] in self?.hardwareChanged() }
		engine.onConfigurationChange = { [weak self] in self?.hardwareChanged() }
		engine.onLatencyStepUpNeeded = { [weak self] in self?.stepUpLatency() }
		registerHotKeys()
		observeSleep()
		Self.askAboutNotifications()

		if settings.data.startMonitoringOnLaunch {
			start()
		}

		// Sparkle schedules its own background checks from here on.
		_ = updater
	}

	// MARK: - Updates

	func setChecksForUpdates(_ enabled: Bool) {
		settings.data.checkForUpdates = enabled
		updater.checksAutomatically = enabled
	}

	// MARK: - Sleep

	/// Audio does not survive a sleep. Devices come back at their own pace, and a
	/// stream left open across a sleep tends to come back dead, with the switch still
	/// showing on. Stopping first and starting again afterwards is what keeps a
	/// machine that sleeps all day usable.
	private func observeSleep() {
		let center = NSWorkspace.shared.notificationCenter

		sleepObservers.append(center.addObserver(
			forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.isRunning else { return }
				self.wasRunningBeforeSleep = true
				self.stopMeterTimer()
				self.engine.stop()
				self.snapshot = .silent
			}
		})

		sleepObservers.append(center.addObserver(
			forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.wasRunningBeforeSleep else { return }
				self.wasRunningBeforeSleep = false
				self.resumeAfterWake()
			}
		})
	}

	private func resumeAfterWake() {
		// Devices reappear over a second or two after a wake, so an immediate start
		// tends to find half of them missing.
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(2))
			guard !isRunning else { return }
			if selectedInput == nil || selectedOutput == nil {
				// Let the hardware listener pick it up when they do come back.
				awaitingReconnect = true
				statusMessage = "Waiting for your devices to come back"
				return
			}
			start(automatic: true)
		}
	}

	/// Everything this app touches gets released here: audio units, HAL listeners,
	/// global shortcuts, timers, and the settings file.
	func shutdown() {
		for observer in sleepObservers {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
		sleepObservers.removeAll()
		stopMeterTimer()
		HotKeyCenter.shared.unregisterAll()
		toggleHotKeyID = nil
		pushToMuteHotKeyID = nil
		engine.shutdown()
		devices.stop()
		settings.save()
	}

	// MARK: - Monitoring

	func panelOpened() {
		failureSeen = true
	}

	func toggle() {
		isRunning ? stop() : start()
	}

	/// `automatic` marks a start nobody asked for: a restart after a hardware change,
	/// or a resume after waking. Those are the ones worth a notification if they fail.
	func start(automatic: Bool = false) {
		guard !isRunning, !isStarting else { return }
		guard let input = selectedInput else {
			statusMessage = "No input device available"
			return
		}
		guard let output = selectedOutput else {
			statusMessage = "No output device available"
			return
		}

		isStarting = true
		Task { @MainActor in
			defer { isStarting = false }
			guard await Self.microphoneAccess() else {
				microphoneDenied = true
				statusMessage = "Sidetone needs microphone access in System Settings"
				return
			}
			microphoneDenied = false
			launch(input: input, output: output, automatic: automatic)
		}
	}

	func stop() {
		awaitingReconnect = false
		latencyStepUps = 0
		stopMeterTimer()
		engine.stop()
		snapshot = .silent
		statusMessage = nil
	}

	private func launch(input: AudioDevice, output: AudioDevice, automatic: Bool = false) {
		let configuration = MonitorConfiguration(
			input: input,
			output: output,
			channelMode: settings.data.channelMode ?? .default(availableChannels: input.inputChannels),
			latency: settings.data.latency,
			gainDecibels: settings.data.gainDecibels,
			muted: settings.data.muted,
			safetyLimiter: settings.data.safetyLimiter
		)

		do {
			try engine.start(configuration, stepUps: latencyStepUps)
			settings.data.input = input.ref
			settings.data.output = output.ref
			statusMessage = nil
			awaitingReconnect = false
			startMeterTimer()
		} catch {
			let message = (error as? MonitorError)?.description
				?? "Could not start monitoring: \(error.localizedDescription)"
			statusMessage = message
			failureSeen = false
			engine.fail(message)

			// Hardware pulled mid-run usually fails the restart before the device list
			// catches up, so this arrives as a failure rather than as a disconnect. It is
			// the same outage, and it has to arm the listener that brings monitoring back.
			// Already waiting means this is a retry, which nobody needs telling about
			// twice.
			guard automatic else { return }
			if !awaitingReconnect {
				Self.notify("Monitoring stopped", message)
			}
			awaitingReconnect = true
		}
	}

	// MARK: - Notifications

	/// Asked at launch, because the moment monitoring drops is usually a moment you
	/// are not at the keyboard, and asking then puts a dialog in front of the very
	/// notification you needed. macOS shows this once and remembers the answer.
	///
	/// The reply closure has to be `@Sendable`. Without it the closure inherits this
	/// type's main actor isolation, and UserNotifications answers on its own XPC
	/// queue, which trips the isolation check and traps before the app finishes
	/// launching.
	private static func askAboutNotifications() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { @Sendable _, _ in }
	}

	/// Says something when monitoring stops without being asked to. Silence is the
	/// symptom either way, and silence is easy to miss for a long time.
	///
	/// Nothing is delivered if permission was refused. Turn these off in System
	/// Settings under Notifications like any other app's.
	private static func notify(_ title: String, _ body: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		UNUserNotificationCenter.current().add(UNNotificationRequest(
			identifier: UUID().uuidString, content: content, trigger: nil
		))
	}

	// MARK: - Controls

	func setGain(_ decibels: Double) {
		settings.data.gainDecibels = decibels
		engine.apply(gainDecibels: decibels, muted: settings.data.muted)
	}

	func setMuted(_ muted: Bool) {
		settings.data.muted = muted
		engine.apply(gainDecibels: settings.data.gainDecibels, muted: muted)
	}

	func setLatency(_ profile: LatencyProfile) {
		settings.data.latency = profile
		latencyStepUps = 0
		restartIfRunning()
	}

	func setSafetyLimiter(_ enabled: Bool) {
		settings.data.safetyLimiter = enabled
		engine.setSafetyLimiter(enabled)
	}

	func select(input device: AudioDevice) {
		settings.data.input = device.ref
		settings.data.channelMode = .default(availableChannels: device.inputChannels)
		restartIfRunning()
	}

	func select(output device: AudioDevice) {
		settings.data.output = device.ref
		restartIfRunning()
	}

	func select(channelMode: InputChannelMode) {
		settings.data.channelMode = channelMode
		restartIfRunning()
	}

	private func restartIfRunning() {
		guard isRunning else { return }
		stop()
		start(automatic: true)
	}

	// MARK: - Presets

	func capturePreset(named name: String) {
		let preset = Preset(
			name: name,
			input: settings.data.input,
			output: settings.data.output,
			channelMode: settings.data.channelMode,
			gainDecibels: settings.data.gainDecibels,
			latency: settings.data.latency
		)
		settings.data.presets.append(preset)
	}

	func apply(_ preset: Preset) {
		settings.data.input = preset.input
		settings.data.output = preset.output
		settings.data.channelMode = preset.channelMode
		settings.data.gainDecibels = preset.gainDecibels
		settings.data.latency = preset.latency
		latencyStepUps = 0
		restartIfRunning()
	}

	func removePreset(_ preset: Preset) {
		settings.data.presets.removeAll { $0.id == preset.id }
	}

	// MARK: - Hardware changes

	/// Remembered devices are matched by UID, so a replug that hands out a new
	/// CoreAudio ID still counts as the same hardware.
	private func hardwareChanged() {
		if isRunning {
			let inputGone = devices.device(uid: settings.data.input?.uid) == nil
			let outputGone = devices.device(uid: settings.data.output?.uid) == nil
			if inputGone || outputGone {
				let missing = inputGone ? settings.data.input?.name : settings.data.output?.name
				engine.stop()
				stopMeterTimer()
				snapshot = .silent
				awaitingReconnect = true
				let name = missing ?? "A device"
				statusMessage = "\(name) disconnected. Waiting for it to come back."
				Self.notify(
					"Monitoring stopped",
					"\(name) disconnected. Sidetone will start again when it comes back."
				)
				return
			}
			restartIfRunning()
			return
		}

		guard awaitingReconnect,
		      let input = devices.device(uid: settings.data.input?.uid),
		      let output = devices.device(uid: settings.data.output?.uid)
		else { return }

		// Cleared on success inside `launch`, so a device that comes back still broken
		// leaves the app waiting rather than giving up.
		launch(input: input, output: output, automatic: true)
	}

	private func stepUpLatency() {
		guard latencyStepUps < 3 else { return }
		latencyStepUps += 1
		statusMessage = "Audio was breaking up, so the buffer was increased"
		restartIfRunning()
	}

	// MARK: - Shortcuts

	func registerHotKeys() {
		HotKeyCenter.shared.unregisterAll()
		toggleHotKeyID = nil
		pushToMuteHotKeyID = nil

		if let combo = settings.data.toggleHotKey {
			toggleHotKeyID = HotKeyCenter.shared.register(combo) { [weak self] in
				self?.toggle()
			}
		}
		if let combo = settings.data.pushToMuteHotKey {
			pushToMuteHotKeyID = HotKeyCenter.shared.register(combo) { [weak self] in
				guard let self else { return }
				pushToMuteWasMuted = settings.data.muted
				setMuted(true)
			} onRelease: { [weak self] in
				guard let self else { return }
				setMuted(pushToMuteWasMuted)
			}
		}
	}

	// MARK: - Metering

	private func startMeterTimer() {
		stopMeterTimer()
		meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.snapshot = self.engine.snapshot()
			}
		}
	}

	private func stopMeterTimer() {
		meterTimer?.invalidate()
		meterTimer = nil
	}

	private static func microphoneAccess() async -> Bool {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized: true
		case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
		default: false
		}
	}
}
