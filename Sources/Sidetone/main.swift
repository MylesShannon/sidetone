import AppKit
import ServiceManagement

if CommandLine.arguments.dropFirst().first == "unregister" {
	try? SMAppService.mainApp.unregister()
	exit(0)
}

// A second copy, such as one opened from the DMG while the installed one runs, reopens the first so it shows
// Settings, and quits. A copy that just moved itself to Applications starts the new one before it quits.
if !CommandLine.arguments.contains(MoveToApplications.relaunchArgument), let id = Bundle.main.bundleIdentifier,
   let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
   .first(where: { $0.processIdentifier != getpid() })?.bundleURL
{
	NSWorkspace.shared.openApplication(at: running, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
	dispatchMain()
}

SidetoneApp.main()
