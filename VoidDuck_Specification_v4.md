# Project Specification: VoidDuck (Desk Pet Companion) — v4

*v4 changes from v3: the character simplifies further — drops the robot body/head/glasses entirely. It's now just a pair of pixel-art eyes with continuously spring-driven pupils and eyelid-frame states (open/half/closed/squint/wide), floating on the black field. See Section 1, 3, 4.7, 5, and 6.*

## 1. Project Overview
**Concept:** A 100% offline, privacy-first, visually interactive digital desk pet for developers. Designed to run continuously on a repurposed Android device (root optional — see Section 2), propped in **landscape**, plugged into wall power. Pure pampering/companionship toy — no utility, no chores, just a pair of eyes that's happy to see you.
**Character:** A pair of pixel-art eyes on a pitch-black field — no head, no body, no glasses frame. Each eye is a socket shape with a continuously spring-driven pupil/highlight dot, plus eyelid-frame states for blink/sleep/squint/wide. Not a literal rubber duck, but built on the same idea — a small presence that watches and listens while you work through a problem.
**Environment:** Pitch black background, landscape orientation. Minimalist.
**Phase 1 Goal:** Visual interactions only. No audio, no internet. The character watches the user, follows their movements, reacts to facial expressions, and manages its own screen/power state to last indefinitely on a desk — all using entirely local processing.
**Phase 2 Goal (Future):** Connect to a local LLM (Hermes agent) via Tailscale for conversational capabilities. Not built now; architecture stays modular enough to bolt this on later.

**Suggested weekend build order** (see Section 10 for full agent instructions):
- **Day 1:** Project scaffold, camera pipeline, `CameraImage → InputImage` conversion (test on the real target phone, not an emulator), raw gaze-following working against a placeholder shape.
- **Day 2:** Build the pixel-art eye-pair renderer (code-defined eye-socket + eyelid-frame grids, continuous spring-driven pupil dot per socket — see Section 4.7), wire up the PetState machine (Section 4), landscape lock + brightness control, ambient idle quirks, polish.
There's no external asset to wait on — build Section 4's state machine against a colored circle first, then grow that circle into the pixel-art eye pair last. The placeholder isn't thrown away; it becomes the character.

## 2. Hardware & OS Constraints
- **Device:** Old Android smartphone, mounted/propped horizontally (landscape). **Root is optional.** Nothing in Sections 4–7 (tracking, PetState, brightness, rendering) requires it — the app is fully functional on a stock, non-rooted phone.
- **Power Management:** Left plugged in 24/7.
  - *If rooted:* **ACC (Advanced Charging Controller)** via Magisk caps battery charge at 60%, preventing the bloat/degradation that comes from months of continuous trickle charging. This is the single feature in the entire spec that touches root — nothing else does or should.
  - *If not rooted:* there's no userspace API for a hard charge cap, so there's no in-app equivalent. Mitigate at the hardware/OS layer instead: check whether the phone already has a built-in charge limiter (Samsung "Protect Battery," Pixel "Adaptive Charging," and similar features exist on a lot of recent Android skins) and enable it if so. Failing that, a cheap mechanical USB power timer on the wall socket that cuts power for a few hours a day achieves a similar effect with zero app involvement and zero added permissions.
- **Display:** Managed entirely in software via brightness (see Section 6), regardless of root status — this was a deliberate choice even before the non-root question came up, to keep root's footprint (rooted or not) to ACC alone.
- **Orientation:** Locked to landscape at the manifest/Flutter level.

## 3. Tech Stack (Phase 1)
- **Framework:** Flutter
- **Rendering:** Hand-coded pixel art via Flutter's `CustomPainter`/`Canvas` — no external animation package, no character asset file, no rig. Eye-socket and eyelid frames are 2D color-grid arrays defined directly in Dart, swapped on a timer/trigger for eyelid state (open/half/closed/squint/wide); see Section 4.7 for how gaze/pupil positioning stays smooth despite everything else being frame-based.
- **Vision/Tracking:** `google_mlkit_face_detection` (100% offline).
- **Camera Pipeline:** `camera` package.
- **Screen wake/keep-alive:** `wakelock_plus` (keeps the app's process and CPU alive; does not control brightness).
- **Brightness control:** `screen_brightness` (or equivalent) — used for the dim/sleep/wake ramps in Section 6. Deliberately not a root-based solution.

## 4. Core Architecture & Data Flow
1. **Camera Feed:** The front camera runs invisibly in the background — never shown on the UI. Framerate is not fixed; it's throttled by the current `PetState` (Section 6) between 15fps (Tracking) and ~1fps (Sleeping) to manage heat and battery.
2. **ML Kit Processing:** Frames are piped into the `FaceDetector`.
3. **Face Selection:** If multiple faces are detected in a frame, select the one with the **largest bounding box** (closest to camera) as the primary subject. Ignore all others for that frame.
4. **Debounce:** State-relevant transitions (face lost, face reacquired, startled trigger) require **N consecutive frames** (suggest N=3–5) in the new condition before firing — a single missed or spurious detection must not flicker the character between states.
5. **Coordinate Normalization:** Extract `boundingBox.center`, `headEulerAngleZ`, `smilingProbability`, `leftEyeOpenProbability`, `rightEyeOpenProbability` from the selected face. Normalize X/Y to `-1.0` to `1.0`.
6. **PetState Machine (new):** A mediator service sits between ML Kit output and both the renderer and the display, and is the single source of truth for the pet's current mode. See Section 6 for the full state definitions and timeouts.
7. **Pixel Renderer Integration:** Pass normalized values into the renderer: continuous `LookX`/`LookY` drive a small pupil/highlight dot inside each eye socket every frame, using the damped-spring smoothing described in Section 5 — this is the one element that must never be pixel-snapped or frame-swapped, or gaze tracking loses its "trails and settles" feel. Everything else is driven by boolean/trigger state selecting which pre-defined eyelid frame to display (`isSmiling` → squint, `isBlinking` → closed, `startled` → wide + dilate, `wake` → wide + brighten) and which pair-level transform to apply, gated by the current PetState. Head tilt (`headEulerAngleZ`) rotates the eye pair as one rigid unit around the midpoint between the two sockets rather than driving separate head geometry.

## 5. Required Visual Interactions (Visual Cues)
- **Gaze Following:** Maps face X/Y to the pupil/highlight dot's continuous position within each eye socket.
- **Curiosity/Confusion (Euler Angles):** Maps `headEulerAngleZ` to a rigid rotation of the eye pair as one unit around the midpoint between the two sockets — there's no separate head geometry to tilt.
- **Proximity:** Maps bounding-box size. Leaning in close triggers the eyes to widen and pull slightly apart (dilate), or a quick shrink-then-rebound flinch — there's no body to back away with. Apply the same debounce as Section 4 plus a short cooldown (~2s) after triggering, so rapid in-and-out movement doesn't spam the reaction.
- **Blinking:** Maps `EyeOpenProbability` — user winks or blinks, the corresponding eyelid frame closes over the socket to mimic it.
- **Happiness:** Maps `smilingProbability` with **hysteresis** to avoid flicker at the threshold: set `isSmiling = true` above 0.7 (the eye shape squints into a crescent — there's no mouth to smile with), only reset to `false` below 0.5.
- **Welcome Animation (new):** A one-shot "greeting" trigger — both eyes snap wide and brighten, optionally with a quick double-blink — played exactly once whenever the character transitions from `Sleeping`/`Dimming` back into `Tracking`. This is the payoff moment for the whole power-management system: leave the desk, the eyes settle down; come back, they light up to see you.
- **Ambient Idle Quirks (new):** While in the `Idle` state (face absent but screen not yet dimmed), trigger a small random ambient animation every 30–90s — asynchronous blinking between the two eyes, a solo wink, or the eyes drifting to "notice something" off to the side before snapping back — so the character reads as alive rather than frozen, without needing a user to be present.

## 6. Attention & Power Management (New Section)
This is the mechanism that makes the pet last indefinitely unattended. One `PetState` enum drives the pixel renderer, screen brightness, and camera/inference throttling together, so they can never drift out of sync.

| State | Trigger | Screen | Inference rate | Notes |
|---|---|---|---|---|
| `Tracking` | Face present | Full brightness | 15fps | Normal reactive behavior (Section 5) |
| `Idle` | No face for 15s+ | Full brightness | ~5fps | Ambient quirks fire here |
| `Dimming` | No face for 45s+ | Ramps down over ~3s to low brightness | ~2fps | Gradual fade, not a snap cut |
| `Sleeping` | No face for 90s+ | Near-zero brightness | ~1fps (just enough to notice a returning face) | Eyes play the staged slow-close sleep sequence (Section 5), frame-swapped |
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
2. **Dependencies:** Add `camera`, `google_mlkit_face_detection`, `wakelock_plus`, `screen_brightness`. No rendering package required — pure Flutter `Canvas`/`CustomPainter` covers Section 4.7.
3. **Permissions:** Configure the Android manifest for camera access ONLY. No internet permission — and verify the merged manifest post-build, not just the source.
4. **Camera Controller:** Implement an efficient image streaming pipeline; handle `CameraImage → InputImage` conversion carefully, test on the real device early.
5. **Face Selection & Debounce:** Implement largest-bounding-box selection and the N-consecutive-frames debounce before any downstream logic consumes detection results.
6. **PetState Service:** Implement the state machine from Section 6 as a single mediator — it owns the current state, the brightness ramp, and the inference-rate throttle. The renderer and the camera pipeline both read from it; neither drives it independently.
7. **UI Layer:** Simple black scaffold containing only the custom pixel-art painter widget, landscape-locked.
8. **Renderer Integration:** Wire normalized gaze values into the continuous pupil-dot position per eye socket (Section 4.7); wire head tilt into eye-pair rotation, and smile/blink/proximity into eyelid-frame selection and pair-level scale/spacing state (Section 5), gated by `PetState`; wire the one-shot `wake` trigger for the greeting animation.
9. **Ambient Behavior:** Implement the random idle-quirk timer (Section 5) for the `Idle` state.
