import AppKit

// A second copy, such as one opened from the DMG while the installed one runs, brings the first forward and quits.
if let id = Bundle.main.bundleIdentifier,
   let first = NSRunningApplication.runningApplications(withBundleIdentifier: id)
   .first(where: { $0.processIdentifier != getpid() })
{
	first.activate()
	exit(0)
}

SidetoneApp.main()
