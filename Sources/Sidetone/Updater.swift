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

	/// Shows progress and any "you are up to date" result, so it is only for a
	/// check the user asked for.
	func checkNow() {
		controller.updater.checkForUpdates()
	}
}
