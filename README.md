# Coin Spotter

An iPhone app that watches the camera on your Meta glasses for coins on the ground and tells you, through the glasses' speakers, when it sees one: "Coin, ahead on your left, near your feet."

It is built on Meta's Wearables Device Access Toolkit 1.0.1 (`MWDATCore`, `MWDATCamera`).

## How it works

1. The app opens a session with the glasses and streams the camera to the phone (720 x 1280, HEVC, 7 frames per second).
2. Twice a second, an on-phone filter looks for small round or elliptical outlines that stand out from the ground. This costs nothing.
3. When the filter finds something, enlarged crops of up to three candidates go to Claude, which answers whether each is really a coin.
4. If Claude agrees, the phone vibrates and speaks the alert. The glasses are the phone's Bluetooth audio output while you wear them, so you hear it there.

After an alert the app stays quiet for 20 seconds so one coin is announced once. Claude is asked at most once every 4 seconds and at most 300 times an hour.

## What you need

- An iPhone on iOS 17.2 or newer with the Meta AI app, paired with your glasses.
- Developer Mode switched on in Meta AI: Settings, your glasses, Developer Mode.
- An Anthropic API key from https://platform.claude.com.
- Either a GitHub account plus a Windows PC (no Mac), or a Mac with Xcode 26.4 or newer.

## Build and install without a Mac

iOS apps can only be compiled by Xcode, so the build runs on a GitHub-hosted Mac and you work from WSL.

1. Push this folder to a GitHub repository. Each push to `main` runs `.github/workflows/build-ios.yml`. macOS build minutes are free on public repositories; private ones use the plan's allowance ten times faster than Linux builds.
2. Download the result into WSL:

   ```bash
   gh run watch
   gh run download --name CoinSpotter-ipa
   ```

   If the build fails, `gh run view --log-failed` shows the compiler errors.
3. On Windows, install iTunes and [Sideloadly](https://sideloadly.io), connect the iPhone by USB, drag in `CoinSpotter.ipa`, and sign in with your Apple ID. Sideloadly signs the app and installs it.
4. On the iPhone, trust the developer under Settings, General, VPN & Device Management, and switch on Settings, Privacy & Security, Developer Mode.

With a free Apple ID the app stops opening after 7 days; repeat step 3 to renew it. A paid Apple Developer account extends that to a year.

## Build and install with a Mac

```bash
brew install xcodegen
cd meta_glasses
xcodegen
open CoinSpotter.xcodeproj
```

In Xcode, select the CoinSpotter target, open Signing & Capabilities, choose your team, and change the bundle identifier from `com.example.coinspotter` to one of your own. Plug in the iPhone and press Run.

If signing fails on the Hotspot Configuration or Access Wi-Fi Information capability (free Apple accounts cannot use them), delete those two lines from the `entitlements` section of `project.yml` and run `xcodegen` again. They are copied from Meta's sample app for the glasses' Wi-Fi link.

## First run

1. Open Settings in the app and paste your Anthropic API key.
2. Tap Play a test alert while wearing the glasses to confirm you hear it through them.
3. Tap Connect glasses. Meta AI opens; approve Coin Spotter.
4. Tap Start spotting. The first time, Meta AI opens again to grant camera access.
5. Look at the ground. The preview draws a yellow box on everything the on-phone filter flags.

You can lock the phone and put it in your pocket once it says "Watching for coins".

## Trying it without glasses

Settings has a test mode, "Use phone camera as glasses". It uses the SDK's simulated glasses with the phone's back camera as the feed. Put some coins on the floor, point the phone at them, and tap Start spotting.

## Tuning

Every threshold is in `CoinSpotter/Detection/ShapeTest.swift` under `Tuning`. The values there were chosen on paper and have not been tried on a device yet.

- Too many yellow boxes on things that are obviously not coins: raise `minContrast` or narrow `ellipseFillRange`.
- Coins in plain view get no box: lower `minContrast`, lower `minWidthPixels`, or widen `perimeterRatioRange`.
- Claude costs too much: switch the model to Haiku 5.5 in Settings, or raise `verifyInterval`.

## Limits worth knowing

- The camera points where your head points. Coins are found on the ground you are looking at, a few steps ahead, and not at the horizon.
- A coin a few metres away is only a handful of pixels wide in the stream, so range is short.
- Streaming the camera drains the glasses battery quickly, and the capture light on the glasses stays on while it runs.
- A single tap on the glasses' touchpad pauses the stream; another tap resumes it.
- The app runs in Developer Mode on your own glasses. Sharing it with other people needs an app registered in Meta's Wearables Developer Center.

## Layout

| Path | Purpose |
|------|---------|
| `project.yml` | XcodeGen project definition, Info.plist values, entitlements |
| `CoinSpotter/App/SpotterModel.swift` | Glasses registration, session, camera stream, app state |
| `CoinSpotter/Detection/FrameDecoder.swift` | HEVC frames to pixel buffers |
| `CoinSpotter/Detection/CandidateFinder.swift` | On-phone outline filter and crops |
| `CoinSpotter/Detection/ShapeTest.swift` | Shape rules and all tuning values |
| `CoinSpotter/Detection/ClaudeVerifier.swift` | Claude confirmation request |
| `CoinSpotter/Detection/CoinPipeline.swift` | Rate limits, cooldown, alert decisions |
| `CoinSpotter/Alerts/Announcer.swift` | Spoken alert and vibration |
| `CoinSpotter/Views/` | Main screen and Settings |
