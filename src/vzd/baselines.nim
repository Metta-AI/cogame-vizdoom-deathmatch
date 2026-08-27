## The two published scripted baselines.
##
## Both emit the SAME order object an LLM does, on the same 4.5 s cadence,
## through the same validator, so their output is legal by construction and
## the two policy kinds are strictly comparable. Both are pure functions of
## the world state, which is what makes the bounded-orders test in
## tests/test_vzd_control.nim meaningful, and neither ever emits `radio` or
## `notes` — those are the LLM's channels.
##
## `rusher` is load-bearing in three places: it is the per-turn fallback when
## a seat's LLM call fails twice, the default for a seat that registers with
## neither PLAYER_PROMPT nor PLAYER_SCRIPTED, and one of the two certification
## players. It is `rusher` and not `sentry` BECAUSE A DEGRADED EPISODE MUST
## STILL BE A LEGIBLE DEATHMATCH: eight sentries hold eight posts and produce
## a 0-0 draw with an empty kill feed, which is a useless replay and a useless
## CI smoke. `rusher` walks at the contested zone and shoots, so even a fully
## degraded episode has frags in it.

import
  std/strutils,
  sim, control, directives

type
  Baseline* = enum
    blRusher = "rusher"
    blSentry = "sentry"

  BaselineParams* = object
    ## The four tunables of the two baselines. They are a parameter rather
    ## than a literal because they were CHOSEN by a grid sweep, not guessed:
    ## `tools/tune_baselines.nim` plays the head-to-head episode over a
    ## bounded matrix of them and prints the table;
    ## `tools/ci/baseline_tuning.json` records the sweep's pick and
    ## `tests/test_vzd_tuning.nim` asserts the shipped defaults below still
    ## equal it.
    rusherHuntPx*: int         ## px: switch a `rusher` cog to `hunt`.
    sentryHuntPx*: int         ## px: the weaker baseline commits much later.
    medPx*: int                ## px: how far a wounded cog will walk to heal.
    postRotation*: int         ## how the four sentry posts are dealt to seats.

const DefaultBaselineParams* = BaselineParams(
  ## The grid harness's pick, not a guess. The sweep's target is a
  ## `rusher`-vs-`sentry` TEAM MARGIN in [+2, +10] frags over 6 seeds:
  ## `rusher` must clearly win — pressure beats posting — without making the
  ## game a walkover. `tools/ci/baseline_tuning.json` records the whole grid.
  rusherHuntPx: 520,
  sentryHuntPx: 260,
  medPx: 360,
  postRotation: 2
)

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `rusher`: a seat that
  ## says nothing useful still plays the published default rather than
  ## sitting out, and the published default is the one that makes frags.
  case text.strip().toLowerAscii()
  of "sentry", "post", "guard": blSentry
  else: blRusher

proc mapCentre*(sim: SimServer): tuple[x, y: int] {.inline.} =
  (MapWidth div 2, MapHeight div 2)

proc contestedZone*(ctl: ControlState, sim: SimServer, team: Team): int =
  ## The zone with the most distinct enemy contacts inside the control
  ## layer's HuntMemoryTicks window. Ties break toward the zone nearest the
  ## map centre; with no contacts at all it is the centre zone, C2. This is
  ## the shared vocabulary the prompt and the bots both speak.
  var counts: array[ZoneCols * ZoneRows, int]
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != team:
      continue
    let enemy = ctl.knownEnemy(sim, i)
    if not enemy.known:
      continue
    inc counts[zoneAtIndex(enemy.x, enemy.y)]
  let centre = sim.mapCentre()
  result = zoneAtIndex(centre.x, centre.y)
  var
    best = 0
    bestDist = high(int)
  for index, count in counts:
    if count == 0:
      continue
    let at = zoneCentreOf(index)
    let d = distSq(at.x, at.y, centre.x, centre.y)
    if count > best or (count == best and d < bestDist):
      best = count
      bestDist = d
      result = index

proc nearestMedKit*(
  sim: SimServer, cogIndex, withinPx: int
): tuple[found: bool, x, y: int] =
  ## The nearest med kit whose respawn timer has expired, inside `withinPx`.
  result = (false, 0, 0)
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let
    cx = sim.players[cogIndex].x + CollisionW div 2
    cy = sim.players[cogIndex].y + CollisionH div 2
  var best = withinPx * withinPx
  for spawn in sim.medKitSpawns:
    if not spawn.present:
      continue
    let d = distSq(cx, cy, spawn.x, spawn.y)
    if d <= best:
      best = d
      result = (true, spawn.x, spawn.y)

proc postAnchors*(sim: SimServer, team: Team): array[4, tuple[x, y: int]] =
  ## The four posts a `sentry` holds, derived from the INSTALLED map and never
  ## hard-coded: the two spawn-pocket corridor mouths and the two mid-lane
  ## mouths on this team's own half. Red's half is column A..B, Blue's D..E,
  ## so a sentry that never crosses the centre line has somewhere to stand at
  ## all three rows.
  let
    anchor = sim.gameMap.teamAnchor(team)
    centre = sim.mapCentre()
    inward = (anchor.x + centre.x) div 2
    top = MapHeight div 4
    bottom = MapHeight - MapHeight div 4
  [(anchor.x, top),
   (anchor.x, bottom),
   (inward, top),
   (inward, bottom)]

proc scriptedDirective*(
  ctl: ControlState,
  sim: SimServer,
  kind: Baseline,
  governed: seq[int],
  params = DefaultBaselineParams
): SquadDirective =
  ## The order one baseline issues for the cog it governs this turn.
  ##
  ## `rusher` — first matching rule wins:
  ##   1. dead -> `hold` at the team's spawn anchor, facing the map centre;
  ##   2. a live enemy known within `rusherHuntPx` -> `hunt` it, and say
  ##      "on it" on the turn the intent becomes `hunt`;
  ##   3. own hp <= 1 and a live med kit within `medPx` -> `move_to` it;
  ##   4. otherwise -> `move_to` the CONTESTED zone.
  ##
  ## `sentry` — deliberately weaker and different in SHAPE, so the ladder gets
  ## a spread rather than two versions of one bot: it never crosses the map's
  ## centre line unless it is already hunting, and its hunt radius is half
  ## `rusher`'s.
  result.source = dsScripted
  result.note = ""
  result.radio = ""
  if governed.len == 0:
    return
  let centre = sim.mapCentre()
  for cogIndex in governed:
    if cogIndex < 0 or cogIndex >= sim.players.len:
      continue
    let
      self = sim.players[cogIndex]
      team = self.team
      anchor = sim.gameMap.teamAnchor(team)
    var order = CogOrder(
      cogIndex: cogIndex,
      id: sim.cogAlias(cogIndex),
      intent: intHold,
      targetX: anchor.x,
      targetY: anchor.y,
      hasFace: true,
      faceX: centre.x,
      faceY: centre.y,
      fromReply: true
    )
    if not self.alive:
      order.at = zoneAt(anchor.x, anchor.y)
      result.orders.add(order)
      continue
    let
      enemy = ctl.knownEnemy(sim, cogIndex)
      huntPx =
        if kind == blSentry: params.sentryHuntPx else: params.rusherHuntPx
      huntable = enemy.known and
        distSq(self.x, self.y, enemy.x, enemy.y) <= huntPx * huntPx
    if huntable:
      order.intent = intHunt
      order.at =
        if enemy.index >= 0 and enemy.index < sim.players.len:
          sim.cogAlias(enemy.index)
        else:
          zoneAt(enemy.x, enemy.y)
      order.targetX = enemy.x
      order.targetY = enemy.y
      order.hasFace = false
      order.say = "on it"
    else:
      let kit = sim.nearestMedKit(cogIndex, params.medPx)
      if self.hp <= 1 and kit.found:
        order.intent = intMoveTo
        order.at = zoneAt(kit.x, kit.y)
        order.targetX = kit.x
        order.targetY = kit.y
        order.hasFace = false
      elif kind == blSentry:
        let
          posts = sim.postAnchors(team)
          seat = sim.cogSeat(cogIndex)
          post = posts[(seat div max(1, params.postRotation)) mod posts.len]
        order.intent = intHold
        order.at = zoneAt(post.x, post.y)
        order.targetX = post.x
        order.targetY = post.y
        order.hasFace = true
        order.faceX = centre.x
        order.faceY = centre.y
      else:
        let
          zone = ctl.contestedZone(sim, team)
          at = zoneCentreOf(zone)
        order.intent = intMoveTo
        order.at = zoneId(zone)
        order.targetX = at.x
        order.targetY = at.y
        order.hasFace = false
    result.orders.add(order)
  # Neither baseline ever emits `radio` or `notes`: those are the LLM.s
  # channels, and the bounded-orders test asserts they stay empty.
