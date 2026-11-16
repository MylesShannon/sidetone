import Sparkle

/// Without a Dock icon, Sparkle's update window opens behind other apps, so it comes to the front with one.
@MainActor
final class UpdateAlerts: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
	var supportsGentleScheduledUpdateReminders: Bool { true }

	func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
		if handleShowingUpdate { DockIcon.show(for: "update") }
	}

	func standardUserDriverWillFinishUpdateSession() {
		DockIcon.hide(for: "update")
	}
}
