// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Sidetone",
	platforms: [.macOS(.v15)],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
	],
	targets: [
		.target(name: "AudioDevices"),
		.target(name: "AudioCore", dependencies: ["AudioDevices"]),
		.target(name: "AppServices", dependencies: ["AudioCore", "AudioDevices"]),
		.executableTarget(
			name: "Sidetone",
			dependencies: [
				"AppServices",
				"AudioCore",
				"AudioDevices",
				.product(name: "Sparkle", package: "Sparkle"),
			]
		),
		.executableTarget(name: "Verify", dependencies: ["AppServices", "AudioCore", "AudioDevices"]),
	],
	swiftLanguageModes: [.v6]
)
