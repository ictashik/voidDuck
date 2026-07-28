# CLAUDE.md — VoidDuck

## What this project is

An offline digital desk pet. A pair of pixel-art eyes floating on a pitch-black field — no head, no body, no glasses frame, just the eyes — on an old Android phone (root optional), propped in landscape, plugged in 24/7. It watches the user via the front camera (ML Kit, fully local), reacts via hand-coded pixel-art rendering (see "Rendering Approach" below), and manages its own screen brightness and inference rate so it can sit on a desk indefinitely.

It has no utility. It is a companion toy. **Every design decision should be judged by "does this make it feel more alive," not "is this efficient."**

Full technical spec: `VoidDuck_Specification_v5.md`. Read it before your first change and treat it as authoritative for architecture. This file governs *how we work together*.

---

## The single most important constraint

**You cannot test this application.** You have no camera, no device, no face. Everything that matters about this project — whether the gaze feels natural, whether the wake animation lands, whether the eyes read as alive — is invisible to you. `flutter build` succeeding tells you almost nothing.

The human is the only test instrument. Structure all your work around that:

1. **Never claim something works.** You can say "this compiles" and "this should produce X behavior." You cannot say "gaze tracking now works." Wait for the human to confirm.
2. **Instrument everything.** If the human can't observe it, you can't debug it. See "Debug overlay" below — it is not optional.
3. **Minimize rebuild round-trips.** Each cycle costs the human a build, a transfer, an install, and a test session. Anything that might need tuning must be tunable *inside the app*, not by editing a constant and rebuilding. This is the highest-leverage rule in this file.
4. **Ship small.** One coherent change per APK. If the human reports "it feels wrong" after you changed five things, neither of you can tell which one caused it.

---

## Working loop

Each cycle:

1. Human states a goal or gives feedback from the last build.
2. You propose what you'll change, in one short paragraph, *before* writing code. Flag anything you're uncertain about or any place you're guessing at a value.
3. You implement it.
4. You build a release APK.
5. You output a **test card** (format below).
6. Human side-loads, tests, reports back.

Do not skip step 2. A 30-second check on intent is much cheaper than a wasted build cycle.

### Build command

```
flutter build apk --release
```

Copy the output to the outputs directory with a versioned name: `voidduck-v0.4.apk`. Increment the minor version every APK, no exceptions — the human needs to be able to say "v0.3 felt better than v0.4" and have that mean something.

### Test card format

Every APK ships with this. Keep it short and specific — vague asks get vague feedback.

```
## v0.4

**Changed:** Gaze now runs through a damped spring instead of setting the eye-dot position directly.

**Test this:**
- Move your head side to side slowly. Does the gaze trail you naturally or does it feel sluggish?
- Move fast, then stop. Does it overshoot and settle, or snap?
- Open the debug overlay and check: is fps holding at ~15 in Tracking?

**Known rough:** Wake animation still snaps instead of ramping. Not fixed yet.

**Tuning knobs live in the panel:** spring stiffness, spring damping.
```

### Feedback format for the human

The human should report back roughly like this — remind them if reports get too vague to act on:

- **What I saw:** plain description of behavior
- **How it felt:** vibes are legitimate data here and often the most important signal
- **Debug values:** anything relevant off the overlay
- **Device state:** phone warm? battery holding? anything crash?

"It feels creepy" is a completely valid and useful bug report on this project. Treat it as high priority, and ask follow-up questions to localize it rather than guessing.

---

## Debug overlay (required in every build)

Hidden behind a triple-tap in the top-left corner. Semi-transparent, small, dismissible. Must show:

- Current `PetState` and seconds spent in it
- Raw ML Kit values: bounding box center + size, `headEulerAngleZ`, `smilingProbability`, both eye-open probabilities
- Normalized `LookX` / `LookY` after smoothing (and raw, for comparison)
- Actual achieved camera fps vs target fps
- Current screen brightness value
- Current eyelid-frame index per eye (open/half/closed/squint/wide)
- Current pupil/highlight-dot position, raw vs. spring-smoothed
- Interest/attention meter value, current mood scalar
- Last 5 triggered animations with timestamps
- `lapSeconds` and `totalSeconds`, as HH:MM:SS

This overlay is how the human tells you *why* something looks wrong instead of just *that* it looks wrong. When behavior is mysterious, add to this overlay before you add speculative fixes.

---

## In-app tuning panel (required)

Also behind the debug gesture, on a second tab. Every magic number in the codebase that affects feel must be a live slider here, persisted across app restarts:

- Spring stiffness and damping for gaze
- All smile/blink/proximity thresholds (both the on and off values for hysteresis)
- Debounce frame counts
- All four PetState timeouts
- Brightness levels and ramp durations per state
- Stare-break frequency range
- Interest decay rate
- Ambient quirk interval range
- Lap-ring reference duration, star-field seed rate (minutes per star) and max star count

Add a "copy current values" button that dumps them as a Dart snippet the human can paste to you. Then tuning becomes a conversation instead of a build queue.

**If you find yourself writing a numeric literal that affects how the eyes feel, it belongs in this panel.**

---

## Aliveness systems

These are the point of the project. Implement them as separate, independently toggleable layers so the human can turn each on and off in the debug panel to feel its individual contribution.

| Layer | What it does |
|---|---|
| Damped gaze | Trails the face by ~150ms, overshoots on fast movement, settles |
| Stare-break | Brief glance off-axis every 3–8s, then back |
| Idle breathing | Always-running loop under everything, amplitude varies by state |
| Micro-drift | Tiny continuous random jitter in the eye pair's position |
| Interest meter | Decays when the scene is static, refreshes on novelty; low interest = the eyes look away and do their own thing |
| Response pools | Every trigger picks from 3–4 variants, weighted random, never the same one twice consecutively |
| Notice latency | Randomized 200ms–1.5s delay before reacting to reacquisition |
| Circadian mood | Device clock biases animation speed and energy; groggy at 3am, perky at 9am |
| Rare events | ~1-in-300 special animations (sneeze, dream bubble, glance behind the user) |

### Signature moments

Build these deliberately, they are the personality:

- **Staring contest** — sustained eye contact without blinking builds into a micro-jitter/darting under the held tension, then the eyes break away first. The user can win.
- **Debugging listen** — sustained close proximity (as opposed to a sudden lean-in, which startles) shifts the eye pair into a slow, synchronized nodding arc — no head or torso needed. This is the thematic heart of the project.
- **Staged sleep** — eyelids droop, jerk back up, droop again, closed. Never a cut.
- **Exit glance** — when the face leaves frame, the eye pair keeps watching the edge it left through, then searches, then gives up.
- **Absence-scaled greeting** — a 30-second absence gets a mild look-up; an 8-hour absence gets the full delighted greeting.

---

## Rendering Approach

No Rive dependency, no external rig or state-machine asset, and no head/body/glasses geometry — the character *is* a pair of eyes, rendered natively in Flutter:

- Each eye is a code-defined pixel-art socket grid (2D array of colors painted as filled rects via `CustomPainter`), not a PNG sprite sheet and not an external art tool. Art-making stays inside code.
- Eyelid state (open, half, closed/blink, squint/happy, wide/startled) is a discrete frame-swap on a timer or trigger — a handful of grid variants per eye, the way retro sprite animation works. Pair-level transforms (rigid rotation for head-tilt, scale/spacing for proximity/startle, a slow position/scale pulse for idle breathing, a nodding arc for the debugging-listen pose) move the whole eye pair as one unit on top of whichever eyelid frame is active.
- The pupil/highlight dot is the one exception to frame-based rendering: drawn on top of the socket every frame, positioned continuously from the damped-spring LookX/LookY math (see "Damped gaze" in the Aliveness systems table). Never pixel-snap or frame-swap its position — it has to stay smooth and continuous, or the gaze-tracking feel described throughout this doc breaks.
- Rationale: motion sells "alive," not art fidelity. Keep the easy-to-get-wrong part (illustration) minimal and code-simple, and put the effort into the part that actually matters (motion).

---

## Non-negotiables

Violating any of these is a build-breaking bug, not a preference:

1. **No `INTERNET` permission.** Not in the source manifest, and not in the merged manifest. Check `app/build/outputs/.../AndroidManifest.xml` after every build that adds or updates a dependency — plugins can inject permissions during the Gradle merge. If it ever appears, stop and report it before doing anything else.
2. **No camera data leaves RAM.** No frames, no crops, no landmarks, no derived biometric values written to disk, ever.
3. **The camera preview is never rendered.** The feed runs invisibly. If a preview widget appears on screen, that's a bug.
4. **Landscape locked.**
5. **Root is optional, and if present, used for ACC battery capping only — nothing else.** Every core system (camera, ML Kit, rendering, brightness, wakelock) runs on stock userspace APIs and must work identically on a non-rooted phone. Screen control stays in userspace via brightness APIs regardless of root status. Do not add root-dependent display code, and never gate any pet behavior behind a root check — only the ACC integration should branch on it. Detect root at startup (a root-check package is fine); if present, offer to enable ACC; if absent, skip silently and say nothing about it in the normal UI.
6. **Pupil position is never frame-snapped or quantized.** It's computed continuously every frame from the spring-damped LookX/LookY values, independent of whichever eyelid frame (open/half/closed/squint/wide) or pair-level transform is currently active.

### The one persistence carve-out

Circadian mood, absence-scaled greetings, and the lifetime total-time counter need state across restarts. Permitted storage is **exactly three values**: a last-seen-face timestamp, a mood scalar, and `totalSeconds` (a monotonically increasing count of cumulative Tracking/Idle presence time, in seconds). Nothing else. No counts of faces, no session logs, no expression history, no timestamped history of any kind — `totalSeconds` is a single running total, not a log. If you think you need to persist a fourth thing, ask first — this boundary is deliberate and the human owns it, not you.

---

## Build order

Checkpoint after each. Don't run ahead — each stage needs device confirmation before the next is worth building.

1. **Scaffold** — Flutter project, landscape lock, black scaffold, wakelock, debug overlay skeleton.
2. **Camera pipeline** — invisible stream, `CameraImage → InputImage` conversion, face detection running, raw values displayed in the overlay. *This is the highest-risk stage: YUV plane layout, stride padding, and rotation metadata vary by manufacturer, and the target is an old phone with unpredictable HAL behavior. Test on the real device, not an emulator. Expect this to take longer than it looks.*
3. **Placeholder tracking** — a plain circle on screen following the face, with smoothing. Proves the whole pipeline end to end without needing any art. **Do not wait for pixel-art assets to start this.**
4. **PetState machine** — the five states, brightness ramps, inference throttling. Testable with the circle.
5. **Pixel rendering** — replace the placeholder circle with the eye pair: code-defined pixel-art eye-socket grids with eyelid-frame states (open/half/closed/squint/wide), pair-level transforms for tilt/proximity/breathing/listen, and the continuously spring-driven pupil dot layered on top inside each socket.
6. **Aliveness layers** — add one at a time, each independently toggleable, each with its own test cycle.
7. **Signature moments.**
8. **Lap/total timers** — lapSeconds (since the last Waking, in-memory only) and totalSeconds (lifetime, persisted) tracked off `PetState`; encoded ambiently as a lap ring around each eye socket and a slowly-seeded background star field, with exact HH:MM:SS values available in the debug overlay. Independently toggleable in the debug panel like the other aliveness layers — this reads PetState, it doesn't drive it.
9. **Soak test** — leave it running overnight. Check morning-after thermals, battery, memory, whether it still wakes correctly. This stage is not optional; a desk pet that dies after six hours has failed at its only job.

---

## Notes on tone

When the human reports something feels off, resist the urge to immediately ship a fix. Ask what specifically felt wrong first — "creepy," "sluggish," and "robotic" have completely different causes and the wrong guess costs a full cycle.

If you think a request will make the eyes feel *less* alive, say so before implementing it. Being useful here means having an opinion about the character, not just executing instructions.