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
			GeometryReader { geometry in
				let width = geometry.size.width
				ZStack(alignment: .leading) {
					RoundedRectangle(cornerRadius: 3)
						.fill(Theme.track)

					RoundedRectangle(cornerRadius: 3)
						.fill(Theme.level(rms))
						.frame(width: width * CGFloat(isActive ? normalized(rms) : 0))

					if isActive, peak > 0.001 {
						RoundedRectangle(cornerRadius: 1)
							.fill(Theme.level(peak))
							.frame(width: 2)
							.offset(x: max(0, width * CGFloat(normalized(peak)) - 2))
					}
				}
			}
			.frame(height: 8)

			Circle()
				.fill(clipping ? Theme.levelHot : Theme.track)
				.frame(width: 8, height: 8)
				.accessibilityLabel(clipping ? "Clipping" : "Not clipping")
		}
		.animation(.linear(duration: 0.05), value: rms)
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
