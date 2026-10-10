# How it works

This page records the investigation behind the tool, with the log lines that show each step, so you can check whether your system behaves the same way.

The setup it was found on: VIVE Pro 2, VIVE Software 1.0.9.202 (VIVE SteamVR driver `viveVR` 1.0.5.4), SteamVR 2.17.10, Edge and Chrome 155, AMD Radeon RX 7800 XT, Windows 11.

## 1. VIVE's OpenXR layers crash Chromium's VR process

VIVE Console registers four implicit OpenXR layers under `HKLM\SOFTWARE\Khronos\OpenXR\1\ApiLayers\Implicit`:

| Layer | Off switch (environment variable) |
| --- | --- |
| `XR_APILAYER_VIVE_hand_tracking` | `DISABLE_XR_APILAYER_VIVE_HAND_TRACKING_1` |
| `XR_APILAYER_VIVE_facial_tracking` | `DISABLE_XR_APILAYER_VIVE_FACIAL_TRACKING_1` |
| `XR_APILAYER_VIVE_srworks` | `DISABLE_XR_APILAYER_VIVE_SRWORKS_1` |
| `XR_APILAYER_VIVE_xr_tracker` | `DISABLE_XR_APILAYER_VIVE_XRTRACKER_1` |

With them loaded, Edge's XR device-service process exits about one second after taking the headset. It writes a crash dump with a `BREAKPOINT` exception in `msedge.dll`, which is a deliberate Chromium check failure. With the four variables set to `1` for the browser only, the crash goes away.

## 2. SteamVR's OpenXR runtime keeps browser frames in "startup"

With the layers off, Edge and Chrome both run a full session through SteamVR: about 90 frames per second, a head pose on every frame, and `visibilityState` "visible". The headset still shows "Next up" or "Waiting…". SteamVR's compositor log (`Steam\logs\vrcompositor.txt`) shows that every browser frame is counted as startup:

```
Lost pipe connection from msedge (25580)
Total.................. 14715 presents.    1 dropped.    4 reprojected
Startup................ 14715 presents.    1 dropped.    4 reprojected
```

A native OpenXR app (a Unity game) on the same system leaves startup after about 140 frames:

```
Total.................. 20265 presents.    9 dropped.  650 reprojected
Startup................   139 presents.    2 dropped.    5 reprojected
```

None of these changed the result:

- turning off SteamVR Home
- closing the SteamVR dashboard
- switching off Chromium's XR sandbox (`--disable-features=XRSandbox`)
- render resolution at 50%
- 90 Hz versus 120 Hz
- Chrome instead of Edge

## 3. VIVE's runtime shows the frames, then quits SteamVR

VIVE Console ships its own OpenXR runtime (`...\ViveVRRuntime\ViveVR_openxr\ViveOpenXR.json`). Pointing the browser at it with `XR_RUNTIME_JSON` shows the WebXR scene in the headset straight away. The session reaches `XR_SESSION_STATE_FOCUSED`, which it never does through SteamVR.

VIVE's server log (`%ProgramData%\HTC\ViveSoftware\ViveVRRuntime\logs\vrserver_<date>.txt`, written in UTF-16) shows that VIVE treats SteamVR as one ordinary app. It makes the browser the active app and tells SteamVR's process to quit:

```
ClientManager] Push Quit event to process: 4952      <- SteamVR's vrserver
EventManager] SceneFocusChanged old 4952 new 24824   <- the browser
VRServer] Confirm SteamVR off
VRServer] Trigger wave vive console 1
ClientManager] Vive console disconnected 1
VRServer] TriggerExitMainLoop
```

The quit is carried out by VIVE's SteamVR driver (`driver_viveVR.dll`). It contains the strings `ViveVR quit event, trigger exit steamVR` and `explorer.exe vrmonitor://quit`, so it opens the `vrmonitor://quit` link, and SteamVR's `vrmonitor.exe` handles it. The handler is registered under `HKCU\Software\Classes\vrmonitor\Shell\Open\Command`.

## 4. Blocking the quit, and the flicker

With the handler temporarily pointed at a logger, the quit arrives (`vrmonitor://quit/`) but does nothing. SteamVR, VIVE's server and VIVE Console all keep running, and the browser keeps the headset.

SteamVR keeps rendering, though. About 10 seconds in, VIVE's compositor starts alternating between SteamVR's picture and the browser's (`AppTextureHandler] Update new syncTexture` toggling between two textures). The browser drops to about 28 frames per second and the image flickers. Suspending SteamVR's `vrcompositor.exe` for the length of the browser session stops this: the browser held a steady 83–90 frames per second for the whole test.

## 5. Handing back

When the browser session ends, VIVE logs `Scene session (<pid>) disconnect`, but doesn't return scene focus to SteamVR, because it believes SteamVR was told to quit. That's why the tool offers a SteamVR and VIVE Console restart at the end.

## Notes for other headsets

Steps 3 to 5 are specific to the VIVE runtime. If you have another headset brand and see the same "Waiting…" screen with browser frames counted as `Startup` in `vrcompositor.txt`, step 2 probably applies to you, but this tool won't fix it.
