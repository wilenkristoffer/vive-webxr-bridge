# vive-webxr-bridge

Use **WebXR in the browser** (VR websites, WebXR demos, YouTube 360° videos) with a **VIVE Pro 2** or another headset that runs through **VIVE Console**.

## The problem

On these headsets, pressing "Enter VR" on a WebXR site in Edge or Chrome never shows anything in the headset. SteamVR sits on its loading screen, showing "Next up" or "Waiting…", while the browser is in fact running the VR session and sending frames. Native SteamVR games work fine.

Firefox doesn't support WebXR for PC headsets at all, so it fails in a different way.

## The cause

Three separate things go wrong:

1. **VIVE's OpenXR layers crash the browser's VR process.** VIVE Console installs OpenXR layers for hand tracking, facial tracking, SRWorks and trackers. They load into every OpenXR program, and Chromium's VR process hits an internal check with them loaded and stops itself after one frame.
2. **SteamVR's OpenXR runtime never shows browser frames.** Even with the layers off, frames from Edge or Chrome arrive at SteamVR but stay in its "startup" phase, so the loading screen never goes away. Native apps leave that phase within about 1.5 seconds.
3. **VIVE's own OpenXR runtime does show browser frames, but then shuts everything down.** VIVE Console runs its own VR server underneath SteamVR, and to that server SteamVR is just one app. When the browser takes the headset, VIVE's SteamVR driver opens the link `vrmonitor://quit`. That closes SteamVR, and VIVE's server then shuts itself down too. You see the scene for about a second.

[docs/how-it-works.md](docs/how-it-works.md) has the log evidence for each step.

## What this tool does

`Start WebXR.cmd` opens a separate Edge window set up for VR. For as long as that window is open, it:

1. **Blocks the quit link.** It points `vrmonitor://` at a harmless logger, so VIVE's quit signal goes nowhere and SteamVR keeps running.
2. **Starts Edge on VIVE's OpenXR runtime,** with VIVE's crashing layers switched off. Both are set through environment variables for this Edge window only.
3. **Pauses SteamVR's compositor during a VR session.** Otherwise SteamVR keeps drawing, VIVE's compositor alternates between its picture and the browser's, and the image flickers. The tool watches VIVE's log for when the browser takes and releases the headset, and resumes SteamVR's compositor when the session ends.
4. **Loads browser extensions from `extensions/`,** such as a YouTube VR player (see below).
5. **Restores everything when Edge closes,** then offers to restart SteamVR and VIVE Console. VIVE doesn't hand the display back to SteamVR by itself.

Nothing is changed permanently. Your normal Edge, your default browser and the system-wide OpenXR runtime are not touched. If the tool is interrupted, it puts the `vrmonitor://` link back the next time it starts.

## Requirements

- Windows 10 or 11
- A headset that uses **VIVE Console** with SteamVR. Developed and tested on a VIVE Pro 2. Cosmos and Pro Eye use the same VIVE runtime and may work, but haven't been tested.
- **Microsoft Edge** (installed with Windows)
- SteamVR

Tested with VIVE Software 1.0.9.202 (VIVE driver 1.0.5.4), SteamVR 2.17.10 and Edge 155 on Windows 11.

## Usage

1. Start VIVE Console and SteamVR as usual, and wait until the headset shows SteamVR.
2. Double-click **`Start WebXR.cmd`**. A status window and an Edge window open.
3. In that Edge window, open a WebXR site and press **Enter VR**. The status window prints *"VR session started"*.
4. To leave VR, use the site's exit button (on the desktop) or close the tab. You can enter VR again in the same window.
5. When you're done, close Edge and press Enter in the status window to restart SteamVR and VIVE Console.

Sites to try: the [WebXR samples](https://immersive-web.github.io/webxr-samples/), [three.js WebXR examples](https://threejs.org/examples/?q=webxr), [A-Frame examples](https://aframe.io/examples/) and [Moon Rider](https://moonrider.xyz).

### YouTube 360° and VR180 videos

YouTube no longer shows a VR button on desktop. To get one, install [video2webxr](https://github.com/phit/video2webxr) into `extensions/` as described in [extensions/README.md](extensions/README.md). The tool then loads it into its Edge window automatically.

## Limitations

- **Controllers:** VIVE's runtime reports the controllers as VIVE Cosmos or Oculus Touch controllers, so button mappings in some WebXR apps may be off. Head tracking and the picture work.
- **Between sessions,** the headset may show VIVE's empty environment, or flicker briefly, until the next session starts or SteamVR is restarted.
- **The tool's Edge window accepts remote-control (DevTools) connections from this PC while it's open.** That's how extensions get loaded. It closes with the window.
- **It relies on VIVE's internal behaviour,** such as how its log is worded. A VIVE update could break it.

## Troubleshooting

- **"Can't find VIVE's OpenXR runtime":** VIVE Console isn't installed in the default location.
- **No "VR session started" line:** VIVE's log format may have changed. The tool looks for `Scene focus change to <pid>` in `%ProgramData%\HTC\ViveSoftware\ViveVRRuntime\logs\vrserver_<date>.txt`.
- **SteamVR doesn't detect the headset after a restart:** quit SteamVR, close VIVE Console, wait about 20 seconds, then start VIVE Console and SteamVR again. If VIVE's runtime is still shutting down when SteamVR starts, its driver fails to load.

## License

[MIT](LICENSE). Not affiliated with HTC, Valve or Microsoft.
