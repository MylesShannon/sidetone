import Foundation
import ServiceManagement

/// Launch at login, via the modern `SMAppService` registration.
///
/// The system is the source of truth here rather than a stored preference, so the
/// checkbox cannot drift out of sync with what macOS will actually do.
@MainActor
public enum LoginItem {
	public static var isEnabled: Bool {
		SMAppService.mainApp.status == .enabled
	}

	/// True when the user has to finish the job in System Settings, which happens
	/// if registration was previously denied.
	public static var requiresApproval: Bool {
		SMAppService.mainApp.status == .requiresApproval
	}

	public static func set(_ enabled: Bool) throws {
		if enabled {
			try SMAppService.mainApp.register()
		} else if SMAppService.mainApp.status == .enabled {
			try SMAppService.mainApp.unregister()
		}
	}

	public static func openSystemSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}
}
