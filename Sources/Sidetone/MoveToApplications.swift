import AppKit

/// The login item and Sparkle updates need the copy in Applications, so a copy opened
/// anywhere else offers to move itself there.
@MainActor
enum MoveToApplications {
	static let relaunchArgument = "relaunched"
	private static let applications = URL(fileURLWithPath: "/Applications/Sidetone.app")

	static var isInApplications: Bool {
		Bundle.main.bundleURL.resolvingSymlinksInPath().path == applications.path
	}

	/// True when the copy in Applications was started and this one is quitting.
	static func offer() -> Bool {
		let alert = NSAlert()
		alert.messageText = "Move Sidetone to Applications?"
		alert.informativeText = "Sidetone opens at login and updates itself from the Applications folder."
		alert.addButton(withTitle: "Move to Applications")
		alert.addButton(withTitle: "Not Now")
		NSApp.activate(ignoringOtherApps: true)
		guard alert.runModal() == .alertFirstButtonReturn else { return false }
		let fm = FileManager.default
		do {
			if fm.fileExists(atPath: applications.path) { try fm.trashItem(at: applications, resultingItemURL: nil) }
			try fm.copyItem(at: Bundle.main.bundleURL, to: applications)
		} catch {
			let failed = NSAlert()
			failed.messageText = "Sidetone couldn't move itself to Applications."
			failed.informativeText = "\(error.localizedDescription)\n\nDrag Sidetone into Applications in Finder and open it from there."
			failed.runModal()
			return false
		}
		// A copy macOS opened from a temporary place can't be removed, and that's fine.
		try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
		let config = NSWorkspace.OpenConfiguration()
		config.createsNewApplicationInstance = true
		config.arguments = [relaunchArgument]
		NSWorkspace.shared.openApplication(at: applications, configuration: config) { _, _ in
			Task { @MainActor in NSApp.terminate(nil) }
		}
		return true
	}
}
