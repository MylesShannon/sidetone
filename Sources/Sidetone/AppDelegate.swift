import AppKit
import Foundation
import UserNotifications

/// Owns process lifetime: one instance only, and a complete teardown on the way
/// out no matter how the quit arrives.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	private var signalSources: [DispatchSourceSignal] = []
	private var didShutDown = false

	func applicationDidFinishLaunching(_: Notification) {
		guard isOnlyInstance() else {
			NSApp.terminate(nil)
			return
		}
		installSignalHandlers()
		UNUserNotificationCenter.current().delegate = self
		AppModel.shared.boot()
	}

	/// macOS drops banners for the app you are already looking at, and opening the
	/// panel makes Sidetone that app. Monitoring usually breaks while the panel is
	/// open, so without this the warning never reaches the screen and only lands in
	/// Notification Center.
	///
	/// Deliberately not isolated: the protocol is not main actor bound, and the
	/// isolated conformance syntax that would bridge it needs a newer compiler than
	/// CI runs. Nothing here touches this object, so there is nothing to isolate.
	nonisolated func userNotificationCenter(
		_: UNUserNotificationCenter,
		willPresent _: UNNotification,
		withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		handler([.banner, .list])
	}

	func applicationWillTerminate(_: Notification) {
		shutdown()
	}

	private func shutdown() {
		guard !didShutDown else { return }
		didShutDown = true
		AppModel.shared.shutdown()
	}

	private func isOnlyInstance() -> Bool {
		guard let bundleID = Bundle.main.bundleIdentifier else { return true }
		return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count <= 1
	}

	/// A terminal `kill` or a stop from a launcher has to release the audio device
	/// too, so both signals run the same teardown instead of dropping the process.
	private func installSignalHandlers() {
		for code in [SIGINT, SIGTERM] {
			signal(code, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
			source.setEventHandler {
				MainActor.assumeIsolated {
					self.shutdown()
					exit(0)
				}
			}
			source.resume()
			signalSources.append(source)
		}
	}
}
