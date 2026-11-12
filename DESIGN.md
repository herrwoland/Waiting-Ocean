# DESIGN — Waiting Ocean

A first-person, melancholic delivery game across five days on a hostile, indifferent sea.
You are a small creature surviving a huge land. Every day the world gets stranger.

Tone references: *Dredge*, *No One Lives Under the Lighthouse*, Arnold Böcklin — *Isle of the Dead*.

---

## 1. Core Loop (one in-game day)

1. **Wake up** in the shack. A letter has been thrown in from the mailbox slot.
2. **Read the letter** — it contains the pickup coordinates. The paper is carried with you and can be re-read any time (diegetic — no HUD).
3. **Walk the beach** to the ship. Board, take the helm.
4. **Sail** to the pickup coordinates. The brass device on the ship shows current coordinates, live.
5. **Dive** — packages are always underwater. Retrieve the package.
6. **Inspect the package** — the delivery coordinates are written on it. Re-inspect any time.
7. **Sail** to the delivery coordinates and hand off the package.
8. **Sail home**, walk to the shack, **sleep**. The game saves ONLY here. Next day begins.

You cannot sleep if the mission is unfinished.

## 2. Structure — Five Days

Each day is a `DayConfig` resource (data, not code):
pickup coords, delivery text/coords on the package, letter text, strangeness swaps to fire,
optional special scene, optional scripted cutscene triggers.

| Day | Beats (draft — tune freely) |
|-----|------------------------------|
| 1 | Clean run. Teaches the loop by shape alone. Calm-ish sea. |
| 2 | Scripted unrepeatable scare: something enormous passes under the ship — silhouette only, never again. First mild strangeness on waking (small props wrong). |
| 3 | First big swap visible on waking (e.g. lighthouse changed). Device digits flicker/drift briefly during sailing. Hunters more aggressive. |
| 4 | **Isle of the Dead** day: island resembling Böcklin's painting; deep well at its center; giant eel circling inside (Mario 64 homage). Package at the bottom of the well. |
| 5 | The letter breaks the pattern: delivery coordinates are **your own shack**. When you arrive, a fish hovers on the shore in front of the house. Climbing onto its back triggers the ending cutscene: the fish flies you to the moon. The game ends. |

Strangeness fires at transitions (wake up, return from a trip) — transformations are never witnessed, only discovered. Examples: ship→fish, shack→fish, giant lighthouse altered. Prefer few devastating swaps over many mild ones.

## 3. World

- Sandy shore with the shack; the only walkable land. Surrounded by a stony beach walled off by 20–30 m natural stone walls. One way to go.
- An absolutely huge lighthouse near the house on the rocks; its light sweeps far into the distance.
- Endless ocean, no other shores. Stormy, thick black clouds.
- Giant swimming creatures; some hunt you when you dive too deep.
- Giant ships on the far horizon, unreachable (candidate delivery framing / set dressing).
- Big feeling of melancholia. The world is hostile but indifferent.

## 4. Mechanics

### Navigation — coordinates only
- Ship device (brass instrument) shows live coordinates via `CoordinateSystem` (world XZ → displayed numbers, offset/scaled to read like an instrument, not engine units).
- Letter shows pickup coords; the package shows delivery coords. No map, no markers, no HUD.
- Later days: device digits occasionally flicker to wrong values (madness, cheap + effective).

### Diving, oxygen, death
- No oxygen meter: screen desaturation + vignette + heartbeat audio + existing underwater low-pass filter escalate as air runs out.
- Danger is depth-based and readable by darkness: hunters aggro below a depth threshold.
- **Death (drowning or eaten): you wake panting in your bed, same day restarts** (packages reset). No fail screen. The game never sends you back further than the current morning.

### The amulet (sonar echo)
Underwater you can barely see. A magical amulet the player finds lets them send an echo (V,
underwater only): for a moment everything within 300 m shows as a grainy pale echo, then it
crumbles back into the murk. **The echo itself is done** (`SonarPulse`, dials in GameSettings →
Sonar pulse); the amulet around it is next. Plan (agreed 2026-10-01, build once the model exists):
- **Found, not given:** the echo only works once the amulet is picked up (where/when — decide; a
  `has_amulet` flag in GameState, so it survives the death→morning loop and saves on sleep).
- **On cooldown:** the amulet rises from the player's neck into the bottom of the view, dull, not
  glowing. It shows how long is left — e.g. a pale light slowly filling it, or runes/facets lighting
  one by one, or the glow creeping back from its edge. Pick to suit the model. No HUD numbers.
- **Ready + pressed:** it glows pale blue as the echo goes out (emission + a small pale-blue OmniLight3D
  on it, so it lights the hands and nearby water), then dims as the cooldown starts.
- When ready and idle it rests on the chest, out of view (maybe a faint pulse in it when it's
  ready again — a sound or a glimmer at the screen's edge).
- Code side: an `Amulet` node on the player camera driven by `SonarPulse.cooldown_left()` and
  `EventBus.sonar_pulsed`; the raise/lower like the carry sockets. Ideas still open: the pulse
  attracting the hunter fish, and echo-only apparitions (shapes that show in the echo but aren't there).

### Item inspection (letter, paper, package)
Standard "hold-to-inspect" pattern (Resident Evil / Gone Home style):
- Interact picks the item into an **inspect state**: player input frozen, item lerps to a socket ~0.5 m in front of the camera, slight DOF/dim on the world behind.
- Mouse drag rotates the item; scroll zooms; E/Esc puts it away.
- Implemented as a small `Inspectable` component + one `InspectionController` on the player camera. Text on items is actual texture/mesh text readable up close (works at 640×480 — test font size on the package early).

### Cutscenes
- Small scripted moments at trigger points (Area3D or mission-phase signals), plus the day-5 ending (fish flight to the moon).
- Implementation: `CutscenePlayer` autoload wrapping AnimationPlayer + a dedicated Camera3D; cutscenes defined per-scene, triggered via EventBus. Skippable? — decide later (suggest: no, they're short).

### Saving
- Save ONLY on sleep: `user://save.cfg` — day number + settings (settings already persist separately).
- Death reload = re-enter the saved morning state.

### Ship
- Stairs/ladders on both sides of the hull (part of ship model or separate): Area3D + interact while swimming lerps you onto the deck. Same pattern as helm enter/exit.

### The kraken (guardian of a rock)
A giant, very old octopus (~66 m) wrapped round a rock column (`kraken_lair.tscn`: Column, Perch
marker, GuardArea, Kraken). Code: `kraken.gd` (behaviour) + `kraken_arm.gd` (procedural arms).
- **Idle:** arms wound round the rock (the rock's real shape is measured with rays once, so any rock
  works), creeping slowly, a couple of arms restless, the mantle breathing. Never fully still.
- **Wakes** when the player enters the GuardArea (any shapes the user sizes), swimming or sailing.
  Slow and huge: jet strokes (arms open slowly, snap shut), gradual turns.
- **Swimming player:** one arm reaches, two more follow a few seconds apart. Caught = coiled, swung
  about, dragged down; the arms never kill — the breath does. Mashing jump/swim_up (Space) loosens
  the grip; harder for each arm holding (1 arm ≈ 3.5 s at 8 presses/s, 2 barely, 3 never).
- **Player aboard a ship:** it takes the ship. Rises beneath her (its one fast burst), grips the hull
  (first grip drags her to a stop), shakes her ~12 s, rolls her over (player thrown off, one arm goes
  for them), drags her down and home and keeps her. Fighting free of that one arm = left alone.
- **Arms** move like real octopus arms: stiff long base, curling tip (per-joint bend limits rising toward
  the tip), always smooth curves, eased and slow (joint 18 deg/s, tip 14 m/s caps). A reach is a bend
  travelling base to tip. A caught player rides in the tip's coil; it loosens as they struggle.
- **Looks at its catch:** once it holds the player it slowly turns its head until they hang in front
  of its eyes (eye_center / gaze_direction on the Kraken match the model's eyes).
- **Grips the real ship:** it measures her visible meshes once and lays each arm up her side and over
  her rail. Optional exact spots: Marker3D nodes named `KrakenGrip*` on the ship (their height = hook).
- **Takes a giant fish over the player** (the lure): a giant fish in its waters comes first (it cuts its
  wake short for one). Too slow to chase it, it lashes and pounces; once an arm lands it coils four
  arms round the fish, drags it to its rock and feeds there, beak in the fish's flank, munching. The
  fish thrashes ~20 s, then is still. Fed, it ignores the player for the rest of the day. A player it
  already holds stays held, but fights free 4x more easily. Idle giant fish keep out of its waters;
  only a hunt (chasing the player) leads one in.
- **Gives up** when the player is 200 m from the perch; swims home and wraps round the rock again.
  Hunters stand down while it is awake. A new morning resets it and gives the ship back.
- Open: the kept ship strands the player at sea until they drown or the day resets — see §8.

### The leviathan (eats lit ships)
An ancient, colossal (1 km in game, one `body_length` dial) basking-shark-like creature, its mouth
always open. Why the power panel exists. Code: `leviathan.gd` (behaviour),
`leviathan_encounter.gd` + `scenes/world/leviathan_waters.tscn` (EncounterArea, user-sized).
- **Mostly under the sea (2026-11-12):** it swims about with only the ridge of its back showing
  (`cruise_exposure`, 0.15 = 15% of its height, ~50 m of a 337 m tall body). It comes up out of the
  sea, mouth and all, only to swallow her: **the breach**. The moment it commits it heaves all of
  itself up, level, over `breach_time` (5 s) so as to be fully up `breach_hold` (2.5 s) before its
  mouth reaches her; the sea bursts off its whole back, it calls again (`breach_call`), a swell
  rolls out. The safe distance is whichever is farther: `judge_distance`, or its closing speed x
  (breach_time + breach_hold), ~260 m on a first pass. Rule for the player: once it rises, it is
  too late.
- **Lights cut in time:** it is far too wide (340 m) to swerve round her, so it goes under (its back
  `pass_under_depth`, 25 m, below the sea) and passes beneath her; its water shapes are stilled
  meanwhile (the plunge would drag a 37 m hole in the sea and drop her onto its back). It stays
  under until its tail has cleared her, even if she lights up again.
- Its size is measured from its colliders (LeviathanSplash `body_top/bottom/side`), not guessed:
  spawn depth, the call's lead and the passing gaps all use it.
- **Comes** only at night (sun dimmer than `night_sun_energy`, until there is a clock), when the
  player swims or sails into the EncounterArea; once per entry, 240 s cooldown. Debug builds: F8.
- **Never pops in:** made 250 m down well off, ahead of the ship (±60°), it swims up. Its call
  is heard ~10 s before it breaks the surface (5 s moan, 5 s silence), 1.5-2.5 km from where the
  ship will be by then (`surface_distance_min/max`); the water domes,
  breaks and rings (two WaterDeformers).
- **Always on a curve:** far too big to turn on the spot. Its body follows the path its head swam
  (the Head is rigid, the Body's segments are laid along the trail), so it bends through curves.
  Tuned in `backups/leviathan_replays/leviathan_tuning.html` (interactive preview + escape test).
- **Dark from the start:** it never knows she is there; its drifting curve (3 km radius) carries it
  past her 100-200 m off its flank, and 200-500 m later it sinks away (out of sight in ~20 s).
- **Lit:** it curves in on her at 17 m/s; inside the 200 m safe distance it comes for her at 20 m/s.
  Cutting the lights before 200 m: it carries on past her (~50 m off its flank) and goes down
  200-500 m later. Lights back on before it goes down: it comes round 1.5× faster, the safe distance
  is now 300 m; cut again in time and it passes very close (~30 m) and goes down. Cutting inside the
  safe distance is too late: it holds its course. A lit ship it misses is hunted again.
- **No escaping by sailing** (ship: 10 m/s, 18°/s): faster than her; if she gets inside the circle
  it can turn it swims straight out and comes back in a line; in its last 450 m its head swings round
  as tight as 100 m and the sea flows into its mouth (20 m/s at the mouth, from 250 m ahead). Fleeing,
  sidestepping, zigzags, circles and crossing its line all fail in the preview (210/210) and in game.
- A node in group `leviathan_lure` within 400 m draws it while the ship is dark (hook for throwable
  distractions, nothing uses it yet).
- **Swallowed:** the ship touching its MouthZone (an Area3D at the end of the throat) is caught there
  and carried with it; nothing moves the player, who stays aboard like on any moving deck. A player
  inside its MouthInside (an Area3D over the mouth cavity) for 10 s straight is lost: the view fades
  to black (3 s), then they die (same morning). Once it has caught her or the player is in its
  mouth it swims on 3-4 s (barely slowing: braking hard there would let her sail back out), then
  goes back down, gone only once its tail too is under; a ship it takes down without the player is
  kept until the morning gives her back. Its model's collision is made a moving body (two-sided).
- Placeholder built from primitives (`leviathan.tscn`: Head + Body/Seg00..08). The real model needs
  to bend: a rigid head piece and a body cut in segments (or bones) along +Z, see §7.

## 5. Code Architecture

Existing foundation to build on: FFT ocean + `get_wave_height()`, buoyancy ship + helm piloting,
player walk/swim/pilot state machine, interactable pattern (Area3D + `interact()` + highlight),
settings/menus/theme, PS1 post-process, underwater audio filter.

New systems:

```
autoloads:
  GameState        current_day, phase, flags; save/load (sleep only)
  EventBus         signal hub: day_started, letter_read, package_picked_up,
                   package_delivered, returned_home, player_died, strangeness_triggered
  CutscenePlayer   plays scripted sequences, owns cutscene camera

resources:
  DayConfig        per-day data: coords, letter text, swaps, special scene, cutscenes
                   campaign = Array[DayConfig]

world systems:
  SanityDirector   listens for day_started / triggers; tells SwappableProps to swap
  SwappableProp    Array[PackedScene] variants (normal → strange → fish); swap(tier)
  CreatureDirector spawns/despawns ambient swimmers around player
  HunterBehavior   depth-triggered pursuit steering
  CoordinateSystem static helper: world XZ <-> display coords

player additions:
  InspectionController   hold-to-inspect state (freezes movement, rotates item)
  OxygenController       breath timer -> visual/audio escalation -> death signal

interactables (existing pattern):
  Bed (sleep/save gate), Letter, Paper, Package, ShipLadder, HelmInteractable (done)
```

Mission phase enum: `WAKE → HAS_LETTER → PICKED_UP → DELIVERED → CAN_SLEEP`.
Everything reacts to EventBus signals; nothing polls GameState.

Suggested script layout: `assets/scripts/core/`, `assets/scripts/world/`, `assets/scripts/player/`, `assets/scripts/interactables/` (migrate existing scripts opportunistically, not in one big move).

## 6. Build Milestones (each ends playable)

1. **Day-cycle skeleton** — GameState/EventBus, bed/sleep/save, letter with placeholder text, full phase loop with debug-box props.
2. **Mission objects** — inspection system (letter/paper/package), ship coords device, underwater package pickup, delivery point.
3. **World layout** — shore, rock walls, lighthouse placement, ship stairs, walk-only boundaries.
4. **Diving danger** — oxygen escalation, hunters, death→morning loop.
5. **Strangeness system** — SanityDirector + SwappableProps, day 2–3 content.
6. **Island day** — Isle of the Dead, the well, the eel.
7. **Tone & ending** — cutscenes (incl. fish-to-moon finale), storm audio pass, day 5, credits.

## 7. Asset List (user-made models)

Already have: ship, lighthouse, multiple giant fish.

Needed next (milestones 1–3):
- Shack: exterior + simple interior (bed, door, table, mailbox/letter slot)
- Letter + coordinate paper (readable text at close range)
- Package: waterproof bundle/crate, delivery coords written on it (readable when inspected)
- Ship coordinate device (brass instrument, readable numbers)
- Ship stairs/ladders (both sides) if not part of ship model
- Rock wall modules (20–30 m natural stone) for coast boundary
- Delivery marker (bell buoy or basket-on-rope from a giant ship)

Later (milestones 4–7):
- Hunter creature variant(s) — may reuse giant fish
- Isle of the Dead island, well interior, giant eel
- Strangeness variants: ship-fish, shack-fish, altered lighthouse (+ small prop swaps)
- The hovering shore fish (ending) + moon flight cutscene assets
- Distant giant ship silhouettes
- The amulet (sonar echo): hangs at the neck, rises into view on cooldown; needs an emissive
  part (or separate mesh) that can glow pale blue, and something that can show the cooldown filling
  (facets/runes as separate meshes, or a texture strip the shader can reveal)
- The kraken: ~50–80 m octopus, replacing `kraken/kraken_placeholder.glb`. Rig convention (the code
  finds bones by name): `body` root at the arm crown, `mantle` child (scaled to breathe), arm chains
  `arm_<a>_<k>` (a = arm 0.., k = joint from root, each bone's +Y down the arm, same count per arm).
  Mantle toward -Z, arms toward +Z, eyes up. Script that built the placeholder (and documents the
  rig): `kraken/source/build_kraken_placeholder.py`. Plus its rock column (with a collider, layer 1)
  and sounds: presence loop, wake, arm grab, grip breaking, hull creak.
- The leviathan: ~500 m basking-shark-like body, mouth always open (pale gill rakers inside), a
  long dark throat the player is drawn down (the camera goes inside it: model the inside too).
  It bends along its path: one skinned mesh with a spine bone chain from `body_center` (at the
  head) down to the tail; the code turns each spine bone to follow the path the head swam, plus a
  tail beat tied to its speed (one beat per `tail_stride` body lengths; `tail_sway`, `head_recoil`). Bones with "obsolete" in the name (the
  jaw) are left out of the spine; they tremble on noise against the water pressure (`jaw_shake`,
  harder with speed). Done: `leviathan_fish.glb` (2026-10-19). Later: big swim splashes along its
  body at the waterline (the user makes the splash effects, then we hook them up). Its collision does not bend (it is
  the rest shape). Axis at the waterline when it swims half out. Sounds: call, surfacing, suction.

## 8. Open Questions (decide when relevant)

- Delivery hand-off staging: buoy vs. basket-from-giant-ship vs. underwater chute (leaning basket — connects the distant ships to the player).
- Cutscene skippability (suggest no; keep them short).
- Whether day 4's eel is lethal or only a terror (suggest: lethal only if touched — Mario 64 rules).
- Wall-calendar or other diegetic day indicator in the shack (crossed-out days).
- Title.
- Kraken keeping the ship: the player is left at sea with no way home but drowning (or diving until
  the air runs out). Accept as a deliberate dead end, or have the morning come on its own after a while?
