# Architecture

## Signal path

```
Input device ──▶ HAL input unit ──▶ gain ──▶ limiter ──┬──▶ ring buffer ──▶ resampler ──▶ AVAudioSourceNode ──▶ Output device
                                                       └──▶ analysis ring ──▶ meters + FFT ──▶ UI at 30 Hz
```

Capture and playback are separate engines joined by a lock-free ring buffer. Most
monitoring tools route one input to one output through a single duplex stream,
which fails once the two devices run on different clocks: the stream drifts and
eventually crackles or dies. Independent engines plus drift compensation let any
pair of devices work together.

Capture uses a bare HAL input unit rather than `AVAudioEngine`, because an engine
always brings up an output IO unit as well. That would open the default output
device unasked, and can force a Bluetooth headset into low quality headset mode.

The resampling ratio is the nominal rate ratio between the devices multiplied by a
correction from a PI controller watching the ring buffer fill level. The
correction is clamped to half a percent, far below where a pitch change is
audible.

Nothing in the capture callback or the render callback allocates, locks, or logs.
Metering and the FFT run on a separate timer reading a second ring buffer, so a
slow UI frame cannot cause a dropout.

## Latency

The panel shows an estimate, not a measurement. It adds up the input and output
device latency, the driver safety offsets, the hardware buffer size, and the ring
buffer target. A true round-trip figure needs a loopback cable and a test tone,
which is out of scope.

## Targets

| Target         | Contents                                                          |
| -------------- | ----------------------------------------------------------------- |
| `AudioDevices` | CoreAudio HAL wrappers, device enumeration and change notification |
| `AudioCore`    | Ring buffer, resampler, drift control, DSP, the monitoring engine  |
| `AppServices`  | Settings, presets, login item, global shortcuts, feedback rule     |
| `Sidetone`     | Menu bar app and SwiftUI views                                     |
| `Verify`       | The checks run by `make test`                                      |

Building and testing are covered in [development.md](development.md).
