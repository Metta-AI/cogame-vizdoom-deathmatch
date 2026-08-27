# Wire protocol — Sprite v1 plus this game's extensions

Both the player endpoints (`/player`, per-seat observation streams) and the
global/spectator endpoint speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything `vizdoom-deathmatch` adds or changes relative to
that base document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — mechanics, tuning defaults, scoring — live in
[`RULES.md`](RULES.md), and what a seat is *told* lives in
[`OBSERVATION.md`](OBSERVATION.md).

## A seat sends NO inputs

**This is the important one.** A player container in this game never sends a
`0x84` Player Input packet. Every actuator mask comes from the server-side
control layer, which compiles the seat's ORDER into per-tick d-pad / `A` / `B`
/ `Select` bytes and records those bytes — not the orders — into the replay.
Bit 7 (`C`) is never used: there is no grenade and no barrier here.

What a seat does send is exactly one thing, its **registration**, as a Sprite
v1 chat message (`0x81`):

```json
{"type":"register","policy":"<label>","prompt":"<PLAYER_PROMPT or empty>",
 "scripted":"rusher"|"sentry"|null}
```

- `prompt` is rune-truncated at 4000 runes and `policy` at 48 runes.
- A seat with a non-empty `prompt` is an **LLM seat**; a seat with `scripted`
  is a scripted seat; a seat with neither is `rusher`.
- The registration is **consumed as registration** — never applied as a shout
  and never written to the replay chat stream, because the prompt is a secret.
  The replay gets a redacted `register` record: the policy label and kind only.
- Any other chat text from a seat is dropped. Cogs speak through the order's
  `say` field; seats do not.
- A seat **re-sends** its registration for the first ~10 s of received frames,
  because joins are slot-sequential and a registration that arrives before the
  slot lands must not be lost.

`0x85` Player Ready is sent and is legitimate here for exactly that reason:
this seat contributes no inputs, so readiness pacing costs the episode nothing.

## The LLM call is made by the GAME, not the player

`ANTHROPIC_API_KEY_URI` is declared on `game.runnable.env`
(`secret://coworld/vizdoom-deathmatch/anthropic_api_key`) and the game pod is
the only process that talks to a provider. Policies carry no `USE_BEDROCK`
flag and need no credentials of their own.

Credentials are resolved in order: Bedrock sidecar
(`AWS_ENDPOINT_URL_BEDROCK_RUNTIME` + `AWS_BEARER_TOKEN_BEDROCK`) →
`ANTHROPIC_API_KEY` → `ANTHROPIC_API_KEY_URI` → **none**, in which case the
client is disabled and every turn falls back instantly with no network wait, so
offline certification finishes in seconds.

## Cadence, batching and the deadlines

One turn every 108 ticks; 24 turns per episode. At each turn the server builds
**every** LLM seat's request body and issues them as **ONE PARALLEL BATCH**
(`curly.makeRequests`) — this is a simultaneous-decision game and eight serial
calls would multiply the wall clock by eight for nothing.

```
attempt1Ms                          8.0 s
retryMs                             3.0 s
turnBudgetMs                       12.0 s   (monotonic deadline around the turn)
turnSpacingMs (configured floor)    5.0 s
effectiveSpacingMs(n) = max(turnSpacingMs, ceil(60000 * n / 28))
                                 -> 5.0 s at 2 LLM seats, 17.143 s at 8
wallClockBudgetSeconds            660   s   (engine hard stop -> "deadline")
```

A rolling 60-second request counter backs the floor up: if issuing the next
batch would push the trailing minute above 28 requests, the seats that would
exceed it skip the call for that turn and take the `rusher` order with
`cause = "rate_guard"`. Bounded, logged, never a sleep on the critical path.

## Endpoints

| Route | Purpose |
|---|---|
| `GET /healthz` | liveness; keeps answering for the `gameOverTicks` grace after artifacts are written |
| `WS /player?slot=<i>&token=<t>` | the seat socket; a token that does not match its seat is **closed** |
| `GET /client/player?slot=&token=` | the certifier's browser probe; token-checked, and it does **not** open the player socket |
| `GET /client/global`, `WS /global` | the spectator stream; fire-and-forget, so a slow viewer can never stall the episode |
| `GET /client/replay`, `GET /replay-data` | local developer replay mode; **never declared to the platform** — the hosted viewer is the static wasm bundle |

`COGAME_CONFIG_URI` in; `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI` out; `HOST` / `PORT`.
`COGAME_PLAYER_FAILURE_URI` receives the platform's **closed** payload —
exactly `{"message", "failed_policy_index"}`, nothing else.

## Your own aim, and dead reckoning between frames

Aim is decoupled from movement and **carries your vision**: the cone is 45°
either side of `aimBrads`, so you see where you point, not where you walk.
`B` rotates counter-clockwise and `Select` clockwise at `aimTurnRate` brads per
tick. A seat never presses these itself — the driver does — but a spectator
client reads `aim`, `cone`, `rng` and `bub` off every roster row on the global
stream, unconditionally, on every frame: the eight cones are the spectator's
whole understanding of who can see whom.

## The replay

The replay is the starter's binary **`COWLDVZD`** format, and it is
self-sufficient: header (magic, format version, `gameName`
`vizdoom-deathmatch`, `gameVersion`), the resolved config JSON **including the
full `mapSpec`**, joins/leaves, one input mask per cog per tick, the chat
records, and **one `gameHash` per tick**. The wasm viewer re-simulates from the
recorded masks with the *same* sim module and compares the hash every tick.

Chat records (written by the server, re-applied at playback into non-hashed
fields only, so they can never affect the sim):

| `k` | Fields |
|---|---|
| `register` | `seat`, `team`, `policy` (≤ 48 runes), `kind`, `baseline` |
| `directive` | `game`, `turn`, `seat`, `team`, `alias`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `intent`, `at`, `target`, `face`, `say` (≤ 10), `radio` (≤ 96), `note` (≤ 160), `view`; whole record ≤ 900 runes |
| `fallback` | `game`, `turn`, `seat`, `attempt`, `cause`, `detail` (≤ 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `stop` | `tick`, `endRule` — the load-bearing wall-clock/fault stop |
| `result` | the full results document, written once at episode end |

`tools/replay_summary.py` (python3 stdlib only) prints one strict-UTF-8 JSON
object for a `.replay` path, which is what phase 60's definition-of-done check
reads instead of `jq .` on the raw bytes.

## Frame pacing: drain the backlog, act on the latest frame

The server may send several frames while a client is thinking. Read every
pending frame and act on the newest; never queue one reply per frame. In this
game a seat's only outbound traffic after registration is the Player Ready
acknowledgement, so a backlog costs nothing but staleness.

## Observation render scale

Player observation coordinates are 1× map scale (the board is 1235 × 659 world
pixels). The global stream states the board's supersample factor per frame as
`bs` so a viewer can convert board pixels to world pixels.
