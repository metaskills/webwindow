# Giving a WKWebView app its own audio channel

*Dev log, November 2026. WebWindow, macOS 14.2+.*

WebWindow is a single `WKWebView` in a window. People run it next to everything else, which means they often run it next to a per-app audio mixer like Elgato Wave Link or Rogue Amoeba's SoundSource. Those tools give every app its own fader. WebWindow didn't get one. Its sound showed up on the Safari channel instead, and turning Safari down turned WebWindow down with it.

This is how we tracked it down and what we ended up shipping.

## Where WebKit's audio actually comes from

`WKWebView` doesn't render media in your app's process. WebKit runs a few helper processes per app, and the one that plays sound is `com.apple.WebKit.GPU`. Every WebKit app gets its own copy, but they all share that same bundle ID.

The first theory was that macOS itself thinks those helpers belong to Safari. It doesn't. Asking each helper who its "responsible" process is (with the private `responsibility_get_pid_responsible_for_pid` call) gave the right answer:

```
WebWindow                    -> responsible WebWindow
com.apple.WebKit.GPU         -> responsible WebWindow
com.apple.WebKit.WebContent  -> responsible WebWindow
```

Then we asked Core Audio which processes were playing sound, using `kAudioHardwarePropertyProcessObjectList` and reading `kAudioProcessPropertyBundleID` on each:

```
pid 31905  output=1  bundle=com.apple.WebKit.GPU
```

So the system knows the helper belongs to WebWindow, but Core Audio reports the sound under the helper's own bundle ID. A mixer that groups audio by bundle ID only sees "some WebKit GPU process". The mixer's binary has a short list of known helper bundle IDs, and `com.apple.WebKit.GPU` is on it, so the likely behavior is that it maps any WebKit GPU helper to Safari. That's an inference from the strings, not something we confirmed in its code.

Nothing in WebKit's public API changes the bundle ID a helper reports. So the fix had to make the sound come from somewhere else.

## Attempt 1: keep media out of the GPU process (didn't work)

WebKit has an internal feature flag, `UseGPUProcessForMediaEnabled`, reachable through the private `WKPreferences._features` list and `_setEnabled:forFeature:`. The idea was that if media stayed in the WebContent process, mixers might resolve it differently.

Flipping the flag on the configuration had no effect. Audio still came from the GPU helper. We dropped it rather than dig into whether the flag is ignored for third-party apps or read too late.

## Attempt 2: tap our own helper and replay the sound (worked)

macOS 14.2 added Core Audio process taps. A tap captures the audio a set of processes is producing, and it can mute the original at the same time. That allows a relay:

1. Find the Core Audio process objects whose responsible process is us. Those are our WebKit helpers, and only ours, never Safari's or anyone else's.
2. Create a tap on them with `CATapDescription(stereoMixdownOfProcesses:)`, with `muteBehavior = .mutedWhenTapped` and `isPrivate = true`.
3. Create a private aggregate device with the current default output as its main sub-device, plus the tap.
4. Run an IOProc on the aggregate that copies the tap's input buffers to the output buffers.

The sound now leaves the speakers from WebWindow's own process, so Core Audio reports it under WebWindow's own bundle ID, and the mixer gives it its own channel. The original helper output is muted, so you don't hear it twice.

The core of it is small:

```swift
let desc = CATapDescription(stereoMixdownOfProcesses: helpers)
desc.muteBehavior = .mutedWhenTapped
desc.isPrivate = true
AudioHardwareCreateProcessTap(desc, &tapID)

let agg: [String: Any] = [
    kAudioAggregateDeviceNameKey: "WebWindow Relay",
    kAudioAggregateDeviceUIDKey: "\(bundleID).relay.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                       kAudioSubTapDriftCompensationKey: true]],
]
AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
```

Helpers can restart, so the relay checks every two seconds and rebuilds the tap if the set of helper processes changes. It also listens for `kAudioHardwarePropertyDefaultOutputDevice` and rebuilds when you switch outputs.

## Bug 1: rebuilds went silent

After a rebuild, the relay ran but produced nothing. The cause was the System Audio Recording permission. macOS ties it to the app's code signature, and an ad-hoc signed app gets a new signature on every build, so each build starts out without permission.

A tap made without permission doesn't fail. It mutes the helper and captures silence. That's the worst outcome: a window that plays nothing.

The fix is to check the permission before tapping. There is no public API for this, so WebWindow uses the private TCC framework the same way other capture tools do: `TCCAccessPreflight("kTCCServiceAudioCapture")`, then `TCCAccessRequest` if the user hasn't answered yet. If the user says no, WebWindow never creates the tap and audio plays the old way, filed under Safari, but audible. If the TCC symbols aren't there, it falls back to letting the tap trigger the prompt.

## Bug 2: silent on output devices with a microphone

It worked with Bluetooth headphones, then went silent on a USB audio interface. Logging the IOProc showed why:

```
in=1ch/2048,2ch/4096  out=2ch/4096  peak=0.0
```

The aggregate device's input list starts with the output device's own input streams, here the interface's mono mic, and only then the tap. The IOProc copied buffer 0 to the speakers, so it relayed a silent mic. The headphones in the earlier test happened not to add an input stream, which hid the bug.

The fix counts the output device's input streams (`kAudioDevicePropertyStreams`, input scope) and skips past them:

```swift
let skip = caInputStreamCount(outDev)
// in the IOProc:
if i + skip < ins.count, let src = ins[i + skip].mData { memcpy(dst, src, n) }
```

After that the tap buffer peaked around 0.24 during playback and the mixer showed the WebWindow channel moving.

## What it costs

- About 150 lines in `main.swift`, still one file and no dependencies.
- Two private symbols: `responsibility_get_pid_responsible_for_pid` to find our helpers, and the TCC preflight/request pair. Either could change in a future macOS. If the responsibility call goes away, the relay finds no helpers and audio plays the old way.
- A System Audio Recording prompt on first launch, and again after each rebuild for anyone building from source.
- macOS 14.2 or later. On older systems the relay is skipped and nothing changes.

## Still untested

- Declining the permission. The code path exists, but nobody has clicked Don't Allow and listened yet.
- Switching output devices in the middle of playback. The relay listens for the change and rebuilds, but it hasn't been exercised by hand.
- Audio and video staying in sync over a long session. A short session sounded clean, but nobody has measured drift.
