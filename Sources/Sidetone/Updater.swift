import Sparkle

/// Sparkle, wrapped so the rest of the app sees three things instead of a
/// framework.
///
/// Sparkle owns the whole update path: it reads the appcast, compares versions,
/// shows its own dialog with the release notes, downloads, verifies the EdDSA
/// signature against `SUPublicEDKey`, replaces the bundle, and relaunches. None of
/// that is worth reimplementing.
@MainActor
final class Updater {
	private let controller: SPUStandardUpdaterController

	init(checksAutomatically: Bool) {
		controller = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: nil,
			userDriverDelegate: nil
		)
		controller.updater.automaticallyChecksForUpdates = checksAutomatically
	}

	var checksAutomatically: Bool {
		get { controller.updater.automaticallyChecksForUpdates }
		set { controller.updater.automaticallyChecksForUpdates = newValue }
	}

	var canCheck: Bool { controller.updater.canCheckForUpdates }

	/// Sparkle's own schedule is a day long and counted from its last check, so a copy
	/// that has been closed for a month can sit on an old version for another day after
	/// it opens. This asks once, a few seconds after launch, late enough to stay out of
	/// the way of starting up. Nothing appears unless there is a newer version.
	func checkQuietlyAtLaunch() {
		guard checksAutomatically else { return }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(5))
			guard canCheck else { return }
			controller.updater.checkForUpdatesInBackground()
		}
	}

	/// Shows progress and any "you are up to date" result, so it is only for a
	/// check the user asked for.
	func checkNow() {
		controller.updater.checkForUpdates()
	}
}
