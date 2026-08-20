import AudioCore
import SwiftUI

/// Peak and RMS on one bar: the filled portion is RMS, the bright line is peak.
struct LevelMeterView: View {
	let peak: Float
	let rms: Float
	let clipping: Bool
	var isActive: Bool

	var body: some View {
		HStack(spacing: 8) {
			// One drawing pass rather than a stack of shapes whose frames and offsets
			// are recomputed thirty times a second.
			Canvas { context, size in
				let corner = CGSize(width: 3, height: 3)
				context.fill(
					Path(roundedRect: CGRect(origin: .zero, size: size), cornerSize: corner),
					with: .color(Theme.track)
				)

				guard isActive else { return }

				let level = CGFloat(normalized(rms))
				if level > 0 {
					context.fill(
						Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * level, height: size.height),
						     cornerSize: corner),
						with: .color(Theme.level(rms))
					)
				}

				guard peak > 0.001 else { return }
				let x = max(0, size.width * CGFloat(normalized(peak)) - 2)
				context.fill(
					Path(roundedRect: CGRect(x: x, y: 0, width: 2, height: size.height),
					     cornerSize: CGSize(width: 1, height: 1)),
					with: .color(Theme.level(peak))
				)
			}
			.frame(height: 8)

			Circle()
				.fill(clipping ? Theme.levelHot : Theme.track)
				.frame(width: 8, height: 8)
				.accessibilityLabel(clipping ? "Clipping" : "Not clipping")
		}
		// No animation on the level. The meter's ballistics already smooth it, and
		// animating asks for a redraw at the display's rate between every update.
		.help(clipping ? "The signal is clipping. Lower the gain." : "Input level")
	}

	/// Meters read better on a dB scale than a linear one: normal speech barely
	/// moves a linear meter.
	private func normalized(_ value: Float) -> Float {
		guard value > 0 else { return 0 }
		let decibels = Float(Decibels.fromLinear(value))
		return ((decibels + 60) / 60).clamped(to: 0 ... 1)
	}
}
