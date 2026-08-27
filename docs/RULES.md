# Rules — cogame-vizdoom-deathmatch

Eight cogs, four RED and four BLUE, in one walled arena with cover, glass
windows, med kits and nothing to capture. Kill an enemy, take a frag. Die,
lose one. After 108 seconds the two teams' net frags are compared and the
margin is the score. Nobody is capturing anything; the only thing that happens
in this game is that somebody shoots first.

This is **not** a ViZDoom port — see [Divergences](#divergences). What it
reproduces is the ViZDoom multiplayer benchmark's *shape*: eight agents, one
map, an egocentric observation, frags − deaths.

## Seats, cogs, teams, aliases

- **`num_agents` = 8, always** — in both shipped variants, in the certification
  fixture and as `SMOKE_SEATS` in `tools/ci/docker_smoke.sh`. **One cog per
  seat** (`cogsPerTeam: 1`), so eight seats drive eight bodies.
- **Teams are assigned by the server, never chosen.** Every variant's `slots[]`
  is `red, blue, red, blue, …`, so slot parity *is* the team: seats **0, 2, 4,
  6 are RED** and **1, 3, 5, 7 are BLUE**. `closedRoster` is true, so a joining
  player takes the slot its token names or is refused.
- **Two name spaces.** In game a cog is `RED-alpha`…`RED-delta` /
  `BLUE-alpha`…`BLUE-delta`, and those aliases are the only names in an
  observation, a prompt, an order, a shout, a radio line or a sprite label. A
  seat's real policy name exists spectator-side only: the replay config's
  `players[].name`, `results.names`, and the viewer's scorebug plates and
  endcard. `showPlayerLabels` is false in every variant.

## The arena

The board is **1235 × 659 px in every shipped variant**. Two variants, two ways
of choosing the geometry, the same dimensions either way:

| Variant | `mapPath` | Geometry |
|---|---|---|
| `arena` | `"arena"` | the hand-tuned symmetric arena, identical every episode |
| `pool` | `"pool"`, `mapSize: "standard"` | the curated 20-seed pool; the entry index is derived from the episode seed **before any seat connects**, and the resolved geometry is pinned into the replay as `mapSpec` |

**Zones.** The board is divided once into a **5 × 3 lettered grid**: columns
`A`…`E` left to right (247 px each), rows `1`…`3` top to bottom. `A1` is the
top-left corner, `E3` the bottom-right. Zone centres are published to every
seat in its first observation and are the only place names in the game. **RED
spawns in column A, BLUE in column E.** Each zone carries a one-word terrain
label derived at load from its wall fraction: `open` (< 8 % wall), `cover`, or
`corridor` (> 22 %).

## Weapons, health, respawns

| Thing | Value |
|---|---|
| Gun | instant line-of-sight hitscan along the aim, `A` button |
| `fireWindupTicks` | 5 (≈0.2 s from trigger pull to shot; **the aim locks at the pull**) |
| `fireCooldownTicks` | 12 (≈0.5 s between shots) |
| `gunRange` | 1050 px on every map |
| Aim fuzz | a fully visible target at max range is hit ~80 % of the time, near-certainly closer |
| `hitPoints` | 3 |
| Friendly fire | **on** — a team kill costs the killer a frag |
| `respawnTicks` | 48 (2.0 s), at the team's own spawn pocket, hp reset to 3 |
| `lives` | 60 — high enough that a wipe is provably unreachable |
| Med kits | placed by the map, respawn 30 s after being taken |
| `aimTurnRate` | 5 brads/tick (≈7°/tick; a full turn in 51 ticks) |
| `visionConeDeg` | **45** — a 90° beam, ViZDoom's default horizontal FOV |
| `visionBubble` | 90 px, still line-of-sight blocked |
| Vision range | `gunRange * 3 div 2` = 1575 px — you see further than you shoot |
| Glass windows | block movement and bullets, transparent to vision |
| Shout | `say` is an in-world shout audible to **both** teams within 247 px, alive 72 ticks, at most one per 24 ticks |

**A wipe is unreachable, which is why `wipe` is not a legal end rule.** A cog
cannot die more often than once per `respawnTicks + 1` ticks, so its ceiling in
a 2592-tick game is 52 deaths, and `lives` is 60.

## The clock

- **Tick** = 1/24 s. **Turn** = one order round every 108 ticks (4.5 s).
- **One game** = 2592 ticks = **24 turns = 108 s of sim**, `maxGames: 1`.
- Between turns the loop runs uncapped (`fastMode`), so the episode's wall
  clock is the 24 LLM turns.
- **Playback** is 1 tick per frame at 24 fps, so a full episode plays for 108 s.

## Scoring

Per cog `c`, from counters the sim already maintains:

```
frags[c]      = kills of ENEMY cogs by c
teamFrags[c]  = kills of OWN-TEAM cogs by c
deaths[c]     = every death of c, whatever the cause
net[c]        = frags[c] - teamFrags[c] - deaths[c]
```

`net[c]` is literally frags − deaths, with a team kill charged to the killer as
a lost frag — the Quake/ViZDoom convention, and the only thing that stops
friendly fire from being a free way to deny an enemy a frag.

```
teamNet[T]       = sum of net[c] over the four cogs of team T
margin(T)        = teamNet[T] - teamNet[other(T)]        (exactly antisymmetric)
DecisiveMargin   = 12
scorePermille[s] = 500 + clamp(margin * 500 div 12, -500, +500)
scores[s]        = scorePermille[s] / 1000.0             in [0.0, 1.0]
win[s]           = scorePermille[s] > 500
```

**Higher is better.** `1.000` is a 12-frag rout, `0.500` a dead-even game,
`0.000` the reverse. A red seat's score and a blue seat's score sum to
**exactly 1.000** for every legal margin.

**There is no tiebreak, deliberately.** A margin of exactly 0 is a draw: all
eight seats score `0.500` and every `win` is false. A manufactured tiebreak
would be a second scoring rule, it would break the exact zero sum, and Elo
handles draws natively.

Everything else is measured and shown, never scored: per-seat `frags`,
`teamFrags`, `deaths`, `net`, `damageDealt`, `damageTaken`, `shotsFired`,
`shotsHit`, `medkits`, `longestStreak`. `damageDealt` / `damageTaken` are
recorded so an episode's damage graph is reconstructable from `results` alone.

## End conditions

The episode ends at the first of full time, the wall-clock stop, or a fault.
`results.reason` is exactly one of:

- **`complete`** — 2592 ticks elapsed. `results.endRule = "full_time"`. The
  healthy value.
- **`deadline`** — the engine's own wall-clock stop at
  `wallClockBudgetSeconds` (660 s). The engine settles from the **real frag
  counters so far**, so a deadline episode is still rankable and still exactly
  zero-sum. `results.endRule = "wall_clock"`.
- **`fault`** — an unexpected exception, caught. Both sides score 0.500,
  artifacts are still written, and `tools/ci/docker_smoke.sh` fails the build
  if the smoke episode reports it.

`results.endRule` is therefore also closed: `full_time | wall_clock |
sim_fault | host_error`. **`mercy` and `wipe` are gone** with the mechanics
that produced them.

**Budget guard.** At the start of each turn, if two more full turns would not
fit inside the wall-clock stop, the LLM is switched off for every remaining
turn (all seats fall to `rusher`, microseconds per turn), the remaining ticks
run at full speed, and the episode still ends `complete` / `full_time`. The
comparison uses the LARGER of `turnBudgetMs` and the derived rate floor.

## Orders

Each seat gives its cog ONE order per turn and a deterministic driver carries
it out until the seat changes it.

| Field | Cap / domain |
|---|---|
| `intent` | ≤ 12 runes; `hunt` \| `hold` \| `move_to` \| `flank` \| `retreat` \| `regroup`. Anything unknown is repaired to `hunt` |
| `at` | ≤ 12 runes; a published zone id (`A1`…`E3`) or a contact alias (`BLUE-delta`). **`at` wins over `to`.** Unresolvable → falls back to `to`, counts in `ordersRejected`, reports `unknown_target` |
| `to` | `[x, y]`, clamped into `[0, 1234] × [0, 658]` |
| `face` | optional `[x, y]`; the bearing a `hold` keeps once it arrives |
| `say` | ≤ 10 runes — an **in-world shout**, heard by *both* teams within 247 px |
| `radio` | ≤ 96 runes — the **team** channel, delivered to your three teammates' next observation, never audible in-world |
| `notes` | ≤ 160 runes — private, echoed back to this seat only |

| Intent | What the driver does |
|---|---|
| `hunt` | flow-field nav to the target; on arrival it sweeps around the approach bearing |
| `hold` | nav to the point, then stop dead and hold `face` if given, else the bearing to the map centre |
| `move_to` | flow-field nav to the point; aim along velocity unless `face` is given |
| `flank` | nav to the point **via a waypoint** in row 1 or row 3 — whichever has had no enemy contact in the last 72 ticks — in the column midway between the cog and the target |
| `retreat` | nav to the team's own spawn anchor, then hold facing the map centre; fire is held only while more than 300 px from the anchor |
| `regroup` | nav to the centroid of the living teammates, snapped to a walkable cell, then hold |

**The trigger rule.** `A` is pressed iff **all** of: the cog is alive; the gun
is off cooldown with no windup in flight; a **live enemy** is known with
`ticks_ago == 0` (seen *this* tick, never a memory); it is inside `gunRange`;
the aim error is inside 24 brads; the line of sight is clear; **and no
teammate's body box intersects the bullet corridor**. There is no suppressive
fire and no firing at memories. Friendly fire is on in the *sim*; the driver
simply refuses to cause it, so a team kill in a replay is always an accident of
movement, never a bot bug.

## The two scripted baselines

Both emit the same order object an LLM does, through the same validator.
Neither ever emits `radio` or `notes`.

**`rusher`** (`PLAYER_SCRIPTED=rusher`) — also the per-turn fallback and the
default for a seat that registers with neither field. First matching rule wins:
dead → `hold` at the spawn anchor; a live enemy known within 520 px → `hunt`
it; hp ≤ 1 with a live med kit within 360 px → `move_to` it; otherwise
`move_to` the **contested zone** (the zone with the most distinct enemy
contacts in the last 72 ticks, ties toward the centre, `C2` with no contacts).

**`sentry`** (`PLAYER_SCRIPTED=sentry`) — deliberately weaker and different in
*shape*: it never crosses the centre line unless it is already hunting, and its
hunt radius is 260 px. Otherwise it holds an assigned post on its own half,
facing the map centre.

`rusher` — not `sentry` — is the fallback **because a degraded episode must
still be a legible deathmatch**: eight sentries hold eight posts and produce a
0-0 draw with an empty kill feed.

## Divergences

1. **This is not a ViZDoom port.** No ZDoom, no `vizdoom` bindings, no WAD, no
   raw pixel buffer, no depth/labels *image*.
2. **The observation is text, not pixels.** The 16-ray depth strip and the
   labelled contact list are ViZDoom's depth and labels buffers written as
   JSON. See [OBSERVATION.md](OBSERVATION.md).
3. **Teammates are not fogged** (the starter fogs everyone). Four independent
   policies on one team, each driving one body at a 4.5 s cadence, cannot play
   team deathmatch blind. Enemies are fogged exactly as the starter fogs them.
4. **`visionConeDeg` 60 → 45.** A 90° total cone is ViZDoom's default FOV, and
   a 120° cone at 1575 px on a 1235 px board is very close to no fog at all.
5. **One cog per seat.** `num_agents` is the cog count.
6. **The driver refuses to cause friendly fire**, though the sim allows it.
7. **`mercy` and `wipe` are gone.** Full time, wall clock or fault — nothing
   else can end an episode.
