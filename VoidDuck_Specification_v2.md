# Project Specification: VoidDuck (Desk Pet Companion) — v2

## 1. Project Overview
**Concept:** A 100% offline, privacy-first, visually interactive digital desk pet for developers. Designed to run continuously on a repurposed Android device (root optional — see Section 2), propped in **landscape**, plugged into wall power. Pure pampering/companionship toy — no utility, no chores, just a duck that's happy to see you.
**Character:** A 2D animated Duck (serving as the ultimate "Rubber Duck" for debugging).
**Environment:** Pitch black background, landscape orientation. Minimalist.
**Phase 1 Goal:** Visual interactions only. No audio, no internet. The character watches the user, follows their movements, reacts to facial expressions, and manages its own screen/power state to last indefinitely on a desk — all using entirely local processing.
**Phase 2 Goal (Future):** Connect to a local LLM (Hermes agent) via Tailscale for conversational capabilities. Not built now; architecture stays modular enough to bolt this on later.

**Suggested weekend build order** (see Section 10 for full agent instructions):
- **Day 1:** Project scaffold, camera pipeline, `CameraImage → InputImage` conversion (test on the real target phone, not an emulator), raw gaze-following working against a placeholder shape.
- **Day 2:** Swap in the real Rive rig, wire up the PetState machine (Section 4), landscape lock + brightness control, ambient idle quirks, polish.
If you don't already have a rigged duck asset, don't let art block logic — build Section 4's state machine against a colored circle first, swap the Rive file in last.

## 2. Hardware & OS Constraints
- **Device:** Old Android smartphone, mounted/propped horizontally (landscape). **Root is optional.** Nothing in Sections 4–7 (tracking, PetState, brightness, Rive) requires it — the app is fully functional on a stock, non-rooted phone.
- **Power Management:** Left plugged in 24/7.
  - *If rooted:* **ACC (Advanced Charging Controller)** via Magisk caps battery charge at 60%, preventing the bloat/degradation that comes from months of continuous trickle charging. This is the single feature in the entire spec that touches root — nothing else does or should.
  - *If not rooted:* there's no userspace API for a hard charge cap, so there's no in-app equivalent. Mitigate at the hardware/OS layer instead: check whether the phone already has a built-in charge limiter (Samsung "Protect Battery," Pixel "Adaptive Charging," and similar features exist on a lot of recent Android skins) and enable it if so. Failing that, a cheap mechanical USB power timer on the wall socket that cuts power for a few hours a day achieves a similar effect with zero app involvement and zero added permissions.
- **Display:** Managed entirely in software via brightness (see Section 6), regardless of root status — this was a deliberate choice even before the non-root question came up, to keep root's footprint (rooted or not) to ACC alone.
- **Orientation:** Locked to landscape at the manifest/Flutter level.

## 3. Tech Stack (Phase 1)
- **Framework:** Flutter
- **Animations:** Rive (`rive` package) for 2D character state machines.
- **Vision/Tracking:** `google_mlkit_face_detection` (100% offline).
- **Camera Pipeline:** `camera` package.
- **Screen wake/keep-alive:** `wakelock_plus` (keeps the app's process and CPU alive; does not control brightness).
- **Brightness control:** `screen_brightness` (or equivalent) — used for the dim/sleep/wake ramps in Section 6. Deliberately not a root-based solution.

## 4. Core Architecture & Data Flow
1. **Camera Feed:** The front camera runs invisibly in the background — never shown on the UI. Framerate is not fixed; it's throttled by the current `PetState` (Section 6) between 15fps (Tracking) and ~1fps (Sleeping) to manage heat and battery.
2. **ML Kit Processing:** Frames are piped into the `FaceDetector`.
3. **Face Selection:** If multiple faces are detected in a frame, select the one with the **largest bounding box** (closest to camera) as the primary subject. Ignore all others for that frame.
4. **Debounce:** State-relevant transitions (face lost, face reacquired, startled trigger) require **N consecutive frames** (suggest N=3–5) in the new condition before firing — a single missed or spurious detection must not flicker the duck between states.
5. **Coordinate Normalization:** Extract `boundingBox.center`, `headEulerAngleZ`, `smilingProbability`, `leftEyeOpenProbability`, `rightEyeOpenProbability` from the selected face. Normalize X/Y to `-1.0` to `1.0`.
6. **PetState Machine (new):** A mediator service sits between ML Kit output and both Rive and the display, and is the single source of truth for the pet's current mode. See Section 6 for the full state definitions and timeouts.
7. **Rive State Machine Integration:** Pass normalized values into Rive's numerical inputs (`LookX`, `LookY`, head tilt) and boolean/trigger inputs (`isSmiling`, `isBlinking`, `startled`, `wake` one-shot trigger), gated by the current PetState.

## 5. Required Visual Interactions (Visual Cues)
- **Gaze Following:** Maps face X/Y to the duck's eyes/head direction.
- **Curiosity/Confusion (Euler Angles):** Maps `headEulerAngleZ` — user tilts head, duck tilts head.
- **Proximity:** Maps bounding-box size. Leaning in close triggers a "startled/backing up" animation. Apply the same debounce as Section 4 plus a short cooldown (~2s) after triggering, so rapid in-and-out movement doesn't spam the reaction.
- **Blinking:** Maps `EyeOpenProbability` — user winks or blinks, duck mimics it.
- **Happiness:** Maps `smilingProbability` with **hysteresis** to avoid flicker at the threshold: set `isSmiling = true` above 0.7, only reset to `false` below 0.5.
- **Welcome Animation (new):** A one-shot "greeting" trigger — eyes pop open, quick happy bounce — played exactly once whenever the duck transitions from `Sleeping`/`Dimming` back into `Tracking`. This is the payoff moment for the whole power-management system: leave the desk, duck settles down; come back, duck lights up to see you.
- **Ambient Idle Quirks (new):** While in the `Idle` state (face absent but screen not yet dimmed), trigger a small random ambient animation every 30–90s — a preen, a stretch, a yawn — so the duck reads as alive rather than frozen, without needing a user to be present.

## 6. Attention & Power Management (New Section)
This is the mechanism that makes the pet last indefinitely unattended. One `PetState` enum drives Rive, screen brightness, and camera/inference throttling together, so they can never drift out of sync.

| State | Trigger | Screen | Inference rate | Notes |
|---|---|---|---|---|
| `Tracking` | Face present | Full brightness | 15fps | Normal reactive behavior (Section 5) |
| `Idle` | No face for 15s+ | Full brightness | ~5fps | Ambient quirks fire here |
| `Dimming` | No face for 45s+ | Ramps down over ~3s to low brightness | ~2fps | Gradual fade, not a snap cut |
| `Sleeping` | No face for 90s+ | Near-zero brightness | ~1fps (just enough to notice a returning face) | Duck plays a slow breathing/sleep loop |
| `Waking` | Face redetected from `Dimming` or `Sleeping` | Ramps up over ~1s | Jumps immediately to 15fps | One-shot greeting animation (Section 5), then falls through to `Tracking` |

Notes:
- All brightness transitions are **ramped**, not instant — a sudden full-brightness flash after darkness looks jarring and defeats the "gentle" feel of a pet waking up.
- Throttling inference rate during `Dimming`/`Sleeping` is what actually delivers on "designed for long lasting" — it's not just the screen, it's the SoC doing far less work for the majority of the time the desk is empty, which also keeps thermal throttling from creeping in during multi-hour idle stretches.
- Timeout values above are suggestions — expose them as constants, they'll want tuning once you're testing live.

## 7. Face Detection Robustness
- **CameraImage → InputImage conversion:** this is the highest-risk part of the build. YUV_420_888 plane layout, stride, and rotation metadata vary by manufacturer. Test against the actual target phone as early as possible — don't validate this against an emulator or a different dev device.
- **Multi-face handling:** largest bounding box wins (Section 4.3); everyone else in frame is ignored for that pass.
- **Hysteresis + debounce:** applied throughout (Sections 4.4, 5) to prevent any single noisy frame from causing a visible flicker in either the animation or the PetState.

## 8. Privacy & Security Requirements
- **Absolute Offline Mode:** Phase 1 must strictly work without internet.
- **Manifest Restriction:** `<uses-permission android:name="android.permission.INTERNET" />` must **not** be present. Check this in the *merged* manifest post-build (`app/build/outputs/.../AndroidManifest.xml`), not just the source manifest — bundled plugins can inject their own permissions during the Gradle merge.
- **Data Ephemerality:** Camera frames are processed in RAM and instantly discarded. No images or logs written to disk.

## 9. Phase 2 Architecture (Context for Future Planning)
*Do not build this in Phase 1, but keep the architecture modular enough to support it later.*
- **The Brain:** A local LLM (Nous Research Hermes 3) running on a local PC/home server (Ollama/LM Studio).
- **Network:** Connected via a Tailscale mesh network; the Flutter app talks to the Hermes server over the Tailscale IP.
- **Interactions:** Local Speech-to-Text (STT) → API call to Hermes over Tailscale → Text-to-Speech (TTS) response.
- Conversation and voice are explicitly out of scope for Phase 1 — the `PetState` machine in Section 6 is designed so a future `Listening`/`Talking` state can slot in alongside the existing ones without a rewrite.

## 10. Instructions for AI Coding Agent
1. **Setup:** Initialize a new Flutter project. Clean out default counter app code. Lock orientation to landscape.
2. **Dependencies:** Add `camera`, `google_mlkit_face_detection`, `rive`, `wakelock_plus`, `screen_brightness`.
3. **Permissions:** Configure the Android manifest for camera access ONLY. No internet permission — and verify the merged manifest post-build, not just the source.
4. **Camera Controller:** Implement an efficient image streaming pipeline; handle `CameraImage → InputImage` conversion carefully, test on the real device early.
5. **Face Selection & Debounce:** Implement largest-bounding-box selection and the N-consecutive-frames debounce before any downstream logic consumes detection results.
6. **PetState Service:** Implement the state machine from Section 6 as a single mediator — it owns the current state, the brightness ramp, and the inference-rate throttle. Rive and the camera pipeline both read from it; neither drives it independently.
7. **UI Layer:** Simple black scaffold containing only the Rive animation widget, landscape-locked.
8. **Rive Integration:** Wire normalized gaze/tilt/smile/blink values into Rive numeric and boolean inputs (Section 5), gated by `PetState`; wire the one-shot `wake` trigger for the greeting animation.
9. **Ambient Behavior:** Implement the random idle-quirk timer (Section 5) for the `Idle` state.