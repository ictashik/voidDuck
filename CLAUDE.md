# CLAUDE.md — VoidDuck

*This is a full rewrite, not a patch, reflecting the v6 architecture (see `VoidDuck_Specification_v6.md`). It supersedes everything this file said about Rive, custom pixel-art rendering, spring-driven gaze tracking, and the emotion-tag expression system. If anything in the repo still assumes those, that's drift to reconcile toward this document, not the other way around.*

## What this project is

An offline desk companion. Runs on an old Android phone (root optional), propped in landscape, plugged in 24/7. It watches occasionally, not continuously in the sense of driving any real-time animation — and reacts through exactly two things on screen: a Unicode emoji and a short line of pixel-font text. There is no illustrated character, no rig, no persistent visual identity beyond that. No microphone, no voice — this was a deliberate choice to avoid an entire second project's worth of scope, not a limitation to work around later.

It has no utility beyond being good company. **Every design decision should be judged by "does this make it feel like it's actually noticing something," not "is this efficient" or "is this visually elaborate."**

Full technical spec: `VoidDuck_Specification_v6.md`. Read it before your first change and treat it as authoritative for architecture. This file governs *how we work together*.

---

## The single most important constraint

**You cannot test this application.** No camera, no device, no face — and now, no way to judge whether a generated emoji+text pair actually lands. `flutter build` succeeding tells you almost nothing, and it tells you *less* than it used to, because the Reaction Engine's output is genuinely generative, not just physics you can reason about from the code.

The human is the only test instrument. Structure all your work around that:

1. **Never claim something works.** You can say "this compiles" and "this should produce X behavior." You cannot say "the reactions feel right" — you have no way to know that. Wait for the human to confirm.
2. **Instrument everything.** If the human can't observe it, you can't debug it. See "Debug overlay" below — it is not optional.
3. **Minimize rebuild round-trips.** Each cycle costs the human a build, a transfer, an install, and a test session — and now, given the model is bundled in the APK, each cycle also costs a meaningfully larger transfer. Anything that might need tuning must be tunable *inside the app*, not by editing a constant and rebuilding.
4. **Ship small.** One coherent change per APK.

---

## Working loop

Unchanged in mechanics from prior versions:

1. Human states a goal or gives feedback from the last build.
2. You propose what you'll change, in one short paragraph, *before* writing code. Flag anything you're uncertain about.
3. You implement it.
4. You build a release APK.
5. You output a **test card**.
6. Human side-loads, tests, reports back.

### Build command

```
flutter build apk --release
```

Versioned output, e.g. `voidduck-v0.9.apk`. Increment every APK, no exceptions.

### Test card format

```
## v0.9

**Changed:** Reaction Engine now fires on the periodic ambient tick, not just Waking.

**Test this:**
- Sit at the desk for the full ambient-tick interval without leaving. Does a reaction fire on schedule?
- Check the debug overlay: does the emoji/text pair match what actually happened in frame?
- Hold up a handwritten note. Does it read the note instead of reacting to the general scene?

**Known rough:** Ambient tick interval is currently hardcoded, not yet in the tuning panel.

**Tuning knobs live in the panel:** none yet for this feature — flagged above.
```

### Feedback format for the human

- **What I saw:** plain description
- **How it felt:** did the reaction feel appropriate, funny, off, generic — this matters more now than it did for physics tuning, since there's no "correct" answer to check against
- **Debug values:** relevant overlay data
- **Device state:** thermal, battery, crashes

---

## Debug overlay (required in every build)

Triple-tap, top-left, semi-transparent, dismissible. Must show:

- Current `PetState` and seconds spent in it
- Raw ML Kit face detection values (still driving `PetState` transitions exactly as before)
- Gesture recognizer output: last detected gesture, confidence, cooldown status
- Last 5 Reaction Engine calls: which trigger fired each one (`Waking` / ambient tick / gesture), the raw `{emoji, text}` output, inference latency, and whether it was valid structured output or hit the fallback default
- Current screen brightness value
- Achieved camera fps vs target fps

This overlay is how the human tells you *why* something looks wrong instead of just *that* it looks wrong. When behavior is mysterious, add to this overlay before you add speculative fixes.

---

## In-app tuning panel (required)

Every number that affects feel, live-editable, persisted across restarts:

- Ambient-tick interval (how often the periodic Reaction Engine call fires during `Tracking`)
- Gesture debounce frame count and post-trigger cooldown
- All four `PetState` timeouts
- Brightness levels and ramp durations per state
- Banner text scroll speed

Add a "copy current values" button that dumps them as a Dart snippet. **If you find yourself writing a numeric literal that affects how this feels, it belongs in this panel.**

---

## What "alive" means now

The aliveness layers from earlier versions (damped gaze, stare-break, idle breathing, micro-drift, an interest meter, response pools, notice latency, circadian mood, rare events) were built for a continuously-animated procedural character. That character doesn't exist anymore. Some of those ideas survive in adapted form; most don't, and shouldn't be forced to.

**Survives, adapted:**
- **Response variety / no consecutive repeats** — keep a short in-memory list of the last few generated lines and pass them to the Reaction Engine's prompt as "don't repeat these." Same principle as before, now implemented as prompt context instead of a hardcoded pool.
- **Circadian mood** — the device clock can still bias the system prompt's tone (groggier phrasing late at night, more energetic mid-morning). Cheap, still fits, no procedural animation required.
- **Rare events** — occasionally swap in a special prompt variant for the ambient tick (roughly 1-in-300) rather than the standard one. Same "creates folklore" rationale as before.
- **Absence-scaled greeting** — feed the actual absence duration into the `Waking` trigger's prompt context and let the model calibrate tone itself (a 30-second gap vs. an 8-hour one), rather than hand-coding animation-intensity tiers. This is a good example of the new architecture doing for free what used to require explicit logic.

**Resolved by architecture, not reimplemented:**
- **Notice latency** — used to be simulated (a randomized delay before reacting). Now it's real: the model call itself takes a few seconds. Don't add artificial delay on top of it.

**Retired, no replacement:**
- Damped gaze, stare-break, idle breathing, micro-drift, the interest meter — all were mechanics of a continuously-rendered character that no longer exists.
- **Staring contest** and **exit glance** — both depended on continuous eye/gaze mechanics with nothing to map onto now. Don't force an equivalent.
- **Staged sleep** — replaced by the fixed sleep-default emoji (Section 4.3 of the spec). Much simpler; that's fine.
- **Debugging listen** — this is the one worth carrying forward explicitly, because it's the thematic core of the whole project: the held-up-note case (the "show me something" gesture trigger, prompted to read and respond to handwritten text) *is* the new version of "the character listens while you debug." Same purpose, different mechanism.

---

## Non-negotiables

1. **No `INTERNET` permission, ever.** Check the *merged* manifest post-build, not just the source. This is now categorically true rather than aspirational — the model is bundled, not downloaded, and nothing else in this spec touches the network. If `INTERNET` ever appears, stop and report it before doing anything else.
2. **No camera data leaves RAM.** No frames, no crops, saved to disk — this explicitly includes frames used for the Reaction Engine, including the held-up-note case. Reading text from a frame is not the same as storing it.
3. **The camera preview is never rendered.**
4. **Landscape locked.**
5. **Root is optional, and if present, used for ACC battery capping only.** Every core system runs on stock userspace APIs regardless of root status.
6. **`RECORD_AUDIO` is a required permission, but the microphone is never continuously listening.** This replaces the earlier "no microphone" rule — that was a deliberate choice at the time, revisited by an explicit, separate decision when gesture-triggered voice recording was added (spec Section 4.2.3/4.4). The constraint that survives from the old rule is the one that actually mattered: no wake word, no hotword, no always-on audio pipeline. The mic is only ever live for one bounded window per trigger — from the end of the 3-2-1 countdown after `Open_Palm` fires, until recording stops (`Closed_Fist` or the hard time cap). Outside that window it is not recording, full stop. Check the *merged* manifest for `RECORD_AUDIO` with the same discipline as non-negotiable #1's `INTERNET` check — present is correct now, but if a future change turns this into anything resembling continuous listening, stop and report it before doing anything else; that would need its own explicit, separate decision, same as this one was.
7. **The model is bundled as an APK asset, never downloaded at runtime.** This is what makes non-negotiable #1 airtight. Don't add a download-on-first-run path even as a fallback.
8. **There is always an emoji on screen.** Structured output schema plus a fixed fallback default if a call ever returns malformed output — never a blank or error state.

### The persistence carve-out

Still exactly as constrained as before: last-seen-face timestamp, a mood scalar, and `totalSeconds` (added with explicit sign-off when the timer feature was introduced). The timer's *visual* representation (the old ring/star-field design) no longer fits the four-zone layout and needs a fresh decision — but the underlying data tracking is still permitted to exist. Don't invent a new visual for it without asking; that's an open item, not yours to resolve unilaterally. No other new persisted values without the same explicit sign-off.

`totalSeconds` is a per-device-local-day counter, not all-time (explicit sign-off, requested directly) — it resets the first time it's touched after the date rolls over, whether that's a fresh app start on a new day or the app staying on straight through midnight. It carries a small internal date-stamp key alongside it purely to detect that rollover; that's bookkeeping for `totalSeconds` itself, not a fourth independently meaningful persisted value.

---

## Build order

1. Confirm the existing camera pipeline, `PetState` machine, and brightness/inference throttling still work — this has survived every version unchanged and shouldn't need rebuilding.
2. Four-zone static layout: emoji zone, scrolling pixel-font banner zone, placeholder content, no model yet.
3. Bundle the chosen model as an asset; wire one structured `{emoji, text}` call against a static test image end to end before touching triggers.
4. Wire the three triggers (`Waking`, ambient tick, gesture) one at a time, each its own test cycle.
5. Gesture detection as its own isolated stage — separate on-device model from the Reaction Engine, test independently.
6. Fallback paths: sleep default, malformed-output default. Small, don't skip.
7. Soak test — multi-hour idle stretch, checking whether the bundled model's presence changes thermal behavior when combined with the existing continuous camera/gesture pipelines.

---

## Notes on tone

When the human reports a reaction felt off, ask what specifically felt wrong before touching the prompt — "generic," "tone-deaf," and "just wrong about what it saw" have different causes and point at different parts of the pipeline (prompt design vs. model capability vs. a vision-reading miss).

If you think a request will make responses feel more generic or less appropriate to the moment, say so before implementing it.