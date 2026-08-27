# What a seat sees

The guiding line: **a seat sees what its cog's eyes see, plus what its team
says.** There is no free-cam and no map-wide enemy list — the fog is the game.

Structurally this is ViZDoom's *depth buffer plus labels buffer*, written as
text: sixteen ray distances across the cone, and one labelled row per thing the
cone or the bubble actually contains. Both come out of `marchRays` in
`src/vzd/egoview.nim` — **the same proc the viewer's first-person inset uses** —
so the wall the model reads about and the wall the spectator sees can never
disagree.

The observation is a JSON object appended to the user message, and it is
mirrored (minus `your_notes`) into the replay's `directive` record, so the
replay explains every decision.

```json
{
  "you": "RED-beta",
  "team": "RED",
  "turn": 7, "turns": 24,
  "clock": {"played_s": 31, "left_s": 77},
  "map": {"w": 1235, "h": 659,
          "zones": [{"id":"A1","c":[123,110],"t":"cover"},
                    {"id":"C2","c":[617,330],"t":"corridor"}],
          "your_spawn": "A2", "their_spawn": "E2",
          "medkits": [{"at":[617,120],"zone":"C1"}]},
  "you_at": {"pos": [402,318], "aim": 8, "facing": "E", "zone": "B2",
             "hp": 2, "alive": true, "respawn_in_ticks": 0, "fire_ready": true,
             "frags": 2, "deaths": 1, "streak": 1},
  "rays": [[-45,318,-1],[-39,341,-1],[-33,377,-1],[-27,441,-1],[-21,612,-1],
           [-15,905,-1],[-9,1204,-1],[-3,-1,742],[3,-1,742],[9,1188,-1],
           [15,884,-1],[21,598,-1],[27,430,-1],[33,369,-1],[39,334,-1],
           [45,312,-1]],
  "contacts": [
    {"label":"enemy","id":"BLUE-alpha","bearing":-4,"dist":688,"zone":"C2","hp":3,"ticks_ago":0},
    {"label":"enemy","id":"BLUE-delta","bearing":22,"dist":915,"zone":"D3","hp":null,"ticks_ago":41},
    {"label":"medkit","id":null,"bearing":-31,"dist":214,"zone":"B1","hp":null,"ticks_ago":0}
  ],
  "team_net": [
    {"id":"RED-alpha","pos":[268,140],"hp":3,"alive":true,"zone":"A1","radio":"holding the north lane"}
  ],
  "heard": [{"team":"BLUE","text":"push mid","at":[640,330],"ticks_ago":18}],
  "score": {"you": 6, "them": 4, "margin": 2,
            "your_team": [{"id":"RED-alpha","f":3,"d":1}]},
  "your_last_order": {"intent":"hunt","at":"C2","result":"chasing"},
  "your_notes": "hold the B2 doorway, they funnel through C2"
}
```

## Field rules

- **`map`** is sent ONCE, at this seat's first turn: fifteen zones is a lot of
  tokens to resend twenty-four times for a board that cannot move. The terrain
  is public knowledge — only *bodies* are fogged — because a seat that cannot
  navigate cannot play.
- **`rays`** is the depth strip: 16 entries spanning the cone from −45° to +45°
  in 6° steps, each `[bearing_deg, wall_dist_px, glass_dist_px]`, with `-1`
  meaning "nothing within `visionRange`". Glass is transparent to vision and
  solid to bullets, so a column can report a glass pane in front of a wall.
- **`contacts`** is one row per entity the cog can legitimately see right now
  (inside the cone with a clear line, or inside the 90 px bubble), plus every
  enemy this cog saw within the last 72 ticks tagged `ticks_ago` and positioned
  where it **was when seen**. `label` is exactly ViZDoom's labels-buffer object
  class: `enemy`, `ally` or `medkit`. **An enemy with `ticks_ago` above 0 is a
  MEMORY, not a sighting — it has moved.**
- **`aim`** is brads (256 per turn, 0 = east, counter-clockwise); `facing` is
  the nearest of the eight compass points, because a model reasons better about
  "NE" than about "32".
- **`bearing`** is **degrees relative to your own aim**, negative left — an
  egocentric quantity, never a world angle.
- **`margin`** is `teamNet[you] − teamNet[them]`, so "higher is better for me"
  always holds.
- **`your_last_order.result`** is the driver's honest report of how the previous
  order ended: `moving | arrived | chasing | holding | firing | no_route |
  dead | respawned | unknown_target`. It is what lets a seat recover from a
  race it could not see.

## Hidden

Every other seat's order, notes, radio and prompt; every seat's real player
name, policy name and kind; the enemy team's per-cog frag/death breakdown (only
its team total is public); enemy positions outside your cone, bubble and
72-tick memory; enemy aim and intent; the seed; the unselected pool entries;
and the map's own `mapSpec` document — a seat gets zones, not wall rectangles.

## Reply

One JSON object, beginning with `{`:

```json
{"intent": "hunt", "at": "C2", "to": [617, 330], "face": [700, 330],
 "say": "mid", "radio": "BLUE-alpha is in C2 at 3hp, I take the north door",
 "notes": "hold B2 next turn if this fails"}
```

Every field is **repaired, never rejected**: an unknown `intent` becomes
`hunt`, an unresolvable `at` falls back to `to`, an out-of-board `to` is
clamped, and a reply that names no order at all keeps last turn's order (else
`rusher`'s). A reply with a valid `say`/`radio` but no `intent` is **usable**:
the cog carries on and the line is delivered. The starter's `cogs: [...]` array
form is still accepted, with its single entry read as the flat order.

Every string that lands in the replay — `say`, `radio`, `notes`, the policy
label, `stopDetail`, recorded error text — is **truncated on RUNE boundaries**,
never by byte index. Byte truncation is what makes a replay that renders in a
browser fail a strict UTF-8 parser.
