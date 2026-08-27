# cogame-vizdoom-deathmatch

**Eight cogs. One walled arena. Frags minus deaths. Nobody is capturing
anything — the only thing that happens in this game is that somebody shoots
first.**

Four RED against four BLUE, teams assigned by the server. Each cog carries a
hitscan gun that kills in three hits, and sees only what is inside its **90°
forward cone** (out to 1575 px, walls blocking) or its 90 px bubble. Your aim
carries your vision, so you see where you point, not where you walk.

Every four and a half seconds each seat is handed a first-person report of its
cog — a sixteen-ray depth strip across the cone, a labelled list of every
contact in it with bearing and distance, its own health and ammo clock, what it
heard, and the scoreboard — and gives that cog **one order**. A deterministic
driver executes the order tick by tick: it steers, it turns, and it pulls the
trigger when a live enemy is in the cone, in range, with a clear line and no
teammate in the corridor. After 108 seconds the two teams' net frags are
compared and the margin is the score.

This is the ViZDoom multiplayer benchmark's *shape* — eight agents, one map, an
egocentric observation, frags − deaths — on an engine that compiles to
WebAssembly, so the replay is a static file. It is **not** a ViZDoom/ZDoom
port: no WAD, no containerised Doom, no raw pixel buffer. What ViZDoom's depth
and labels buffers carry, this game carries as text.

## A policy is just a prompt

A champion here is a strategy paragraph. Both shipped champions are
`PLAYER_PROMPT` policies on the same image as the two scripted baselines; the
only difference between a champion and a filler is an environment variable.

```
{"intent":"hold","at":"C2","face":[700,330],
 "radio":"killbox is C2, I have the north angle","notes":"re-issue unless hp 1"}
```

- `intent` ∈ `hunt | hold | move_to | flank | retreat | regroup`
- `at` is a zone id (`A1`…`E3`) or a contact's alias (`BLUE-delta`)
- `say` (≤ 10 chars) is **shouted out loud** — both teams hear it within 247 px
- `radio` (≤ 96 chars) reaches your three teammates only, next turn
- Everything is repaired, never rejected: an unknown intent becomes `hunt`, an
  unresolvable target falls back to `to`, and a reply that names no order keeps
  last turn's.

## Seats and policies

| | |
|---|---|
| Seats | **8** (4v4), `num_agents: 8` in every variant and in the cert fixture |
| Champions | `vzd-pointman`, `vzd-crossfire` — `PLAYER_PROMPT`, different prompts |
| Baselines | `vzd-rusher`, `vzd-sentry` — `PLAYER_SCRIPTED=rusher\|sentry` |
| Image | one, `coworld-vizdoom-deathmatch`, env-switched |
| Entrypoints | `/bin/vizdoom-deathmatch` (game), `/bin/vizdoom-deathmatch-player` (seat) |

The LLM call is made by the **game** pod, not the player pod: the anthropic key
is injected as `game.runnable.env.ANTHROPIC_API_KEY_URI`. A seat with no
credentials at all still plays — it falls back to `rusher` instantly, with no
network wait, so offline certification finishes in seconds.

## Variants

| Variant | Map |
|---|---|
| `arena` | the hand-tuned symmetric arena, identical every episode |
| `pool` | a map drawn from the curated twenty-seed terrain pool by the episode seed, pinned into the replay so an old replay always renders the map it was played on |

Both are 1235 × 659, both 24 turns of 108 ticks, both `frags − deaths`.

## Watching it

The replay is a **static wasm bundle**, never a pod: `tools/build_replay_viewer.sh`
compiles the *same* Nim sim module to WebAssembly through emscripten, and the
browser re-simulates the episode from the recorded per-tick input masks,
checking a `gameHash` on every tick.

The viewer draws every cog's vision cone as a translucent wedge clipped exactly
the way the sim clips it — without them a spectator sees eight dots wander —
plus eight first-person raycast thumbnails (`#eyes`, click one for the big POV
inset), the kill feed in plain language, the frag-margin momentum graph, and a
scrubber whose beats are labelled clickable buttons for `gamestart`, `kill`,
`streak`, `lead`, `fallback` and `gameover`.

## Repo map

```
src/vizdoom_deathmatch.nim         the game server entrypoint
src/vizdoom_deathmatch_player.nim  the thin seat registrar
src/vzd/                           the sim, the server, the commander layer
  sim.nim          re-exports the sim modules; owns the tick loop
  deathmatch.nim   the objective layer: net, teamNet, margin, the lead
  zones.nim        the 5 x 3 lettered zone grid
  egoview.nim      marchRays + the seat's observation (the ONE ray march)
  decide.nim       one parallel batch per turn, the deadlines, the guards
  directives.nim   the reply schema, tolerant parsing, rune truncation
  baselines.nim    rusher and sentry
  control.nim      the driver: nav, aim and the trigger rule
client/                            the broadcast chrome (inherited + a game block)
replay-viewer/                     the wasm entry and the static shell
tools/ci/                          docker smoke, viewer smoke, policies, versions
docs/                              RULES.md, OBSERVATION.md, PROTOCOL.md
docs/plans/                        the accepted design note
```

## Building and testing

Everything that needs Docker, Nim or emsdk runs in GitHub Actions
(`.github/workflows/ci.yml`): the Nim test suite in debug and release, a
raw-Docker episode smoke with the certification fixture's seat mix, and the
wasm bundle opened in headless chromium against the replay that smoke produced.

```bash
for t in tests/test_*.nim; do nim r --path:src "$t"; done   # the whole suite
./tools/ci/docker_smoke.sh coworld-vizdoom-deathmatch:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
python3 tools/replay_summary.py path/to/episode.replay | jq .
```

## Art

The board art is the starter's shipped two-team shooter art, plus one
nano-banana render (`scripts/art/source/marines_sheet.png`,
`gemini-2.5-flash-image`, anchored on this repo's own cog reference) split by
`scripts/art/split_cog_sheet.py` into `data/helm_red.png`,
`data/helm_blue.png` and `data/glyph_frag.png` — the visored marine helmets and
the frag skull the kill feed and the `#eyes` captions draw.
