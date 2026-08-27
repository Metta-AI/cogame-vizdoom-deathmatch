## The control layer: the ONE deterministic function that turns a directive
## into per-tick Sprite v1 actuator masks.
##
## Both LLM directives and scripted directives are compiled by this same code,
## so the two policy kinds are strictly comparable and a scripted baseline is
## legal by construction. It is a pure function of
## `(sim state, directive, cogIndex) -> uint8`.
##
## It sits OUTSIDE the determinism boundary: the server records the masks this
## produces into the replay, and the wasm viewer feeds those recorded masks to
## the identical sim. Nothing here is re-run at playback, which is why this
## module may use ordinary floating-point navigation maths where the hashed
## paint grid may not.

import
  std/[math, tables],
  bitworld/spriteprotocol,
  sim, directives

const
  NavCell* = 12               ## nav grid cell side, in px.
                              ## Sized to the ARENA, not to the paint grid: the
                              ## arena's corridors are ~26 px wide for a 13 px
                              ## footprint, so a cell the size of a paint tile
                              ## (34 px) has no open cell anywhere inside a gap
                              ## between two obstacles and the flow field
                              ## reports the whole far side of every obstacle
                              ## column UNREACHABLE. Measured on that grid, a
                              ## sweeping squad fell back to the straight line,
                              ## walked into the first wall and pressed the same
                              ## d-pad direction for two thousand ticks. At
                              ## 12 px every 26 px corridor contains a cell
                              ## centre with the full footprint's clearance.
  FieldRefreshTicks* = 12     ## a flow field is recomputed at most this often.
  MaxCachedFields* = 64       ## flow fields kept before the cache is dropped.
                              ## A field is one int per cell, so an unbounded
                              ## cache on a fine grid is an unbounded leak over
                              ## a long episode; eight cogs never need more.
  ArriveRadius* = 20          ## px: a cog this close to its goal stops moving.
  AimMinRangeSq* = 16 * 16    ## an aim target nearer than this gives a vector
                              ## too short to mean a direction.
  AimDeadBrads* = 4           ## no turn button inside this error.
  FireAimBrads* = 24          ## widest aim error that still pulls the trigger.
  HuntMemoryTicks* = 72       ## how long a seen enemy stays "known".
  HuntRangePx* = 300          ## aim priority radius for a known enemy.
  StuckTicks* = 8             ## ticks of zero displacement after which a cog
                              ## steers along the obstacle instead of into it.
                              ## The flow field is built once, over the wall
                              ## mask alone: it cannot know about the spinning
                              ## diamonds' later frames, and it cannot know
                              ## about the other seven COGS at all — four cogs
                              ## sharing one goal in a 26 px corridor jam each
                              ## other. Degrade-never-hang applies to a cog as
                              ## much as to a network call.
  PaintProbeSteps* = [34, 68, 102, 136, 170]
                              ## px along the aim the trigger samples for floor
                              ## worth painting: one probe at a single distance
                              ## misses both the tile under the cog's nose and
                              ## the far end of the cone's reach.

type
  NavGrid* = object
    w*, h*: int
    open*: seq[bool]

  ControlState* = object
    ## Everything the control layer remembers between ticks. Lives on the
    ## SERVER, never on the sim, so it can never enter gameHash.
    grid*: NavGrid
    fields*: Table[int, seq[int]]      ## goal cell -> BFS distance field
    fieldTick*: Table[int, int]        ## goal cell -> tick it was built
    lastSeenX*, lastSeenY*: seq[int]   ## per cog: last known enemy position
    lastSeenTick*: seq[int]
    lastSeenIndex*: seq[int]
    lastX*, lastY*: seq[int]           ## per cog: position at the last observe
    stuckTicks*: seq[int]              ## per cog: consecutive motionless ticks

proc navCellOf*(grid: NavGrid, x, y: int): int =
  ## The flat nav cell containing a map pixel, or -1 off the grid.
  let
    cx = x div NavCell
    cy = y div NavCell
  if x < 0 or y < 0 or cx >= grid.w or cy >= grid.h:
    return -1
  cy * grid.w + cx

proc navCentre*(grid: NavGrid, cell: int): tuple[x, y: int] =
  ((cell mod grid.w) * NavCell + NavCell div 2,
   (cell div grid.w) * NavCell + NavCell div 2)

proc buildNavGrid*(sim: SimServer): NavGrid =
  ## A NavCell-px occupancy grid over the sim's REAL wall mask (not an
  ## observation stream): a cell is open when a cog footprint fits at its
  ## centre. Built once per episode, against the mask as it stands at build
  ## time — a spinning diamond that later rotates into a cell this grid calls
  ## open is handled by the stuck deflection in `compileMask`, not by rebuilding
  ## a five-thousand-cell grid every tick.
  result.w = (MapWidth + NavCell - 1) div NavCell
  result.h = (MapHeight + NavCell - 1) div NavCell
  result.open = newSeq[bool](result.w * result.h)
  for cell in 0 ..< result.open.len:
    let (cx, cy) = result.navCentre(cell)
    if cx < MapWidth and cy < MapHeight:
      result.open[cell] = sim.canOccupy(cx, cy)

proc nearestOpenCell*(grid: NavGrid, x, y: int): int =
  ## The open cell nearest a map point, by expanding ring search. -1 only
  ## when the grid has no open cell at all.
  let start = grid.navCellOf(clamp(x, 0, MapWidth - 1), clamp(y, 0, MapHeight - 1))
  if start >= 0 and grid.open[start]:
    return start
  let
    sx = clamp(x, 0, MapWidth - 1) div NavCell
    sy = clamp(y, 0, MapHeight - 1) div NavCell
  for r in 1 .. (grid.w + grid.h):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          cx = sx + dx
          cy = sy + dy
        if cx < 0 or cy < 0 or cx >= grid.w or cy >= grid.h:
          continue
        let cell = cy * grid.w + cx
        if grid.open[cell]:
          return cell
  -1

proc computeField*(grid: NavGrid, goal: int): seq[int] =
  ## Breadth-first flow field to `goal` over 4-connected open cells: the
  ## number of steps from every cell to the goal, -1 where unreachable.
  result = newSeq[int](grid.open.len)
  for i in 0 ..< result.len:
    result[i] = -1
  if goal < 0 or goal >= result.len or not grid.open[goal]:
    return
  var
    queue = @[goal]
    head = 0
  result[goal] = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod grid.w
      cy = cell div grid.w
      d = result[cell]
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= grid.w or ny >= grid.h:
        continue
      let next = ny * grid.w + nx
      if not grid.open[next] or result[next] >= 0:
        continue
      result[next] = d + 1
      queue.add(next)

proc fieldFor*(ctl: var ControlState, tick, goal: int): seq[int] =
  ## The cached flow field for one goal cell, rebuilt at most once every
  ## FieldRefreshTicks. Cheap enough that eight cogs chasing eight distinct
  ## goals still costs a handful of BFS passes per second.
  if goal < 0:
    return @[]
  if ctl.fields.hasKey(goal) and
      tick - ctl.fieldTick.getOrDefault(goal, low(int) div 2) < FieldRefreshTicks:
    return ctl.fields[goal]
  if ctl.fields.len >= MaxCachedFields and not ctl.fields.hasKey(goal):
    ctl.fields.clear()
    ctl.fieldTick.clear()
  let field = computeField(ctl.grid, goal)
  ctl.fields[goal] = field
  ctl.fieldTick[goal] = tick
  field

proc navSteer*(
  ctl: var ControlState, tick, fromX, fromY, goalX, goalY: int
): tuple[dx, dy: int] =
  ## The steering vector for one cog: straight at the goal when the line of
  ## sight is clear (so a cog does not stair-step around an open floor), else
  ## down the flow field toward the neighbouring cell nearest the goal.
  let goalCell = ctl.grid.nearestOpenCell(goalX, goalY)
  if goalCell < 0:
    return (0, 0)
  let (gx, gy) = ctl.grid.navCentre(goalCell)
  let field = ctl.fieldFor(tick, goalCell)
  let here = ctl.grid.nearestOpenCell(fromX, fromY)
  if here < 0 or field.len == 0 or field[here] <= 1:
    return (gx - fromX, gy - fromY)
  let
    cx = here mod ctl.grid.w
    cy = here div ctl.grid.w
  var
    best = field[here]
    bestCell = -1
  for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= ctl.grid.w or ny >= ctl.grid.h:
      continue
    let next = ny * ctl.grid.w + nx
    if not ctl.grid.open[next] or field[next] < 0:
      continue
    if dx != 0 and dy != 0:
      # No corner cutting: a diagonal is only taken when both of the cells it
      # squeezes between are open. A cell is barely wider than a cog, so
      # clipping the corner of an obstacle wedges the cog against it and it
      # presses the same direction forever.
      if not ctl.grid.open[cy * ctl.grid.w + nx] or
          not ctl.grid.open[ny * ctl.grid.w + cx]:
        continue
    if field[next] < best:
      best = field[next]
      bestCell = next
  if bestCell < 0:
    return (gx - fromX, gy - fromY)
  let (nxp, nyp) = ctl.grid.navCentre(bestCell)
  (nxp - fromX, nyp - fromY)

proc bradsErr*(desired, current: int): int =
  ## Signed shortest turn from `current` to `desired`, in brads: positive is
  ## counter-clockwise (button B), negative clockwise (button Select).
  var d = (desired - current) mod AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  d

proc initControlState*(sim: SimServer): ControlState =
  result.grid = buildNavGrid(sim)
  result.fields = initTable[int, seq[int]]()
  result.fieldTick = initTable[int, int]()
  result.lastSeenX = newSeq[int](MaxPlayers)
  result.lastSeenY = newSeq[int](MaxPlayers)
  result.lastSeenTick = newSeq[int](MaxPlayers)
  result.lastSeenIndex = newSeq[int](MaxPlayers)
  result.lastX = newSeq[int](MaxPlayers)
  result.lastY = newSeq[int](MaxPlayers)
  result.stuckTicks = newSeq[int](MaxPlayers)
  for i in 0 ..< MaxPlayers:
    result.lastSeenTick[i] = low(int) div 2
    result.lastSeenIndex[i] = -1
    result.lastX[i] = low(int) div 2
    result.lastY[i] = low(int) div 2

proc observeEnemies*(ctl: var ControlState, sim: SimServer) =
  ## The control layer's ONCE-PER-TICK observation: each cog's memory of the
  ## nearest enemy it can currently see, and whether it is making progress.
  ## Vision is the sim's own fog rule, so the control layer never knows more
  ## than the cog does.
  ##
  ## Both are updated here rather than in `compileMask` so that compiling a
  ## mask stays a pure read of this state: the same (state, directive) pair
  ## yields the same byte however many times it is asked.
  while ctl.lastSeenX.len < sim.players.len:
    ctl.lastSeenX.add(0)
    ctl.lastSeenY.add(0)
    ctl.lastSeenTick.add(low(int) div 2)
    ctl.lastSeenIndex.add(-1)
  while ctl.lastX.len < sim.players.len:
    ctl.lastX.add(low(int) div 2)
    ctl.lastY.add(low(int) div 2)
    ctl.stuckTicks.add(0)
  for i in 0 ..< sim.players.len:
    if sim.players[i].x == ctl.lastX[i] and sim.players[i].y == ctl.lastY[i]:
      inc ctl.stuckTicks[i]
    else:
      ctl.stuckTicks[i] = 0
    ctl.lastX[i] = sim.players[i].x
    ctl.lastY[i] = sim.players[i].y
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    var
      bestDist = high(int)
      bestIndex = -1
    for j in 0 ..< sim.players.len:
      if j == i or not sim.players[j].alive:
        continue
      if sim.players[j].team == sim.players[i].team:
        continue
      if not sim.playerVisibleTo(i, j):
        continue
      let d = distSq(sim.players[i].x, sim.players[i].y,
                     sim.players[j].x, sim.players[j].y)
      if d < bestDist:
        bestDist = d
        bestIndex = j
    if bestIndex >= 0:
      ctl.lastSeenX[i] = sim.players[bestIndex].x
      ctl.lastSeenY[i] = sim.players[bestIndex].y
      ctl.lastSeenTick[i] = sim.tickCount
      ctl.lastSeenIndex[i] = bestIndex

proc knownEnemy*(
  ctl: ControlState, sim: SimServer, cogIndex: int
): tuple[known: bool, x, y, index, ticksAgo: int] =
  ## The nearest enemy this cog knows about — seen now, or seen within
  ## HuntMemoryTicks. That memory is intel a commander legitimately has.
  if cogIndex >= ctl.lastSeenTick.len:
    return (false, 0, 0, -1, 0)
  let age = sim.tickCount - ctl.lastSeenTick[cogIndex]
  if age > HuntMemoryTicks or ctl.lastSeenIndex[cogIndex] < 0:
    return (false, 0, 0, -1, 0)
  (true, ctl.lastSeenX[cogIndex], ctl.lastSeenY[cogIndex],
   ctl.lastSeenIndex[cogIndex], age)

proc hillCentre*(sim: SimServer): tuple[x, y: int] =
  (MapWidth div 2, MapHeight div 2)

proc nearestHillTile*(
  sim: SimServer, x, y: int, wantOwner: int, team: Team
): tuple[found: bool, x, y: int] =
  ## The hill tile centre nearest (x, y) whose owner matches `wantOwner`:
  ##  0 = "not this team's" (a tile worth painting),
  ##  1 = "this team's"     (a tile worth standing on).
  result = (false, 0, 0)
  var best = high(int)
  for tile in sim.hillTiles:
    if not sim.paintFloor[tile]:
      continue
    let
      mine = sim.paintOwner[tile] == paintTeamCode(team)
      wanted = if wantOwner == 1: mine else: not mine
    if not wanted:
      continue
    let (cx, cy) = sim.paintTileCentre(tile)
    let d = distSq(x, y, cx, cy)
    if d < best:
      best = d
      result = (true, cx, cy)

proc farthestHillTile*(
  sim: SimServer, x, y: int, team: Team
): tuple[found: bool, x, y: int] =
  ## The hill floor tile FURTHEST from (x, y) that is not this team's colour.
  ##
  ## This is what `paint_hill` walks toward, and the reason is mechanical: the
  ## cone starts AT the cog and reaches forward, so a cog can never paint the
  ## tile it is standing on. Sending it to the NEAREST unpainted tile therefore
  ## parks it on that tile forever — measured, four cogs converged on the
  ## western rim and the squad plateaued at 13 of 21 tiles. Sending it to the
  ## far side instead makes it a paint roller: it crosses the hill, its cone
  ## covers the ground ahead of it, and when it arrives the far side is
  ## whatever it has not covered yet, so it sweeps back.
  result = (false, 0, 0)
  var best = -1
  for tile in sim.hillTiles:
    if not sim.paintFloor[tile]:
      continue
    if sim.paintOwner[tile] == paintTeamCode(team):
      continue
    let (cx, cy) = sim.paintTileCentre(tile)
    let d = distSq(x, y, cx, cy)
    if d > best:
      best = d
      result = (true, cx, cy)

proc livingTeamCentroid*(
  sim: SimServer, cogIndex: int
): tuple[found: bool, x, y: int] =
  ## Where this cog's living teammates are, on average, snapped to the nearest
  ## walkable pixel. `regroup`'s goal.
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return (false, 0, 0)
  let team = sim.players[cogIndex].team
  var
    sx = 0
    sy = 0
    n = 0
  for i in 0 ..< sim.players.len:
    if i == cogIndex or sim.players[i].team != team or not sim.players[i].alive:
      continue
    sx += sim.players[i].x + CollisionW div 2
    sy += sim.players[i].y + CollisionH div 2
    inc n
  if n == 0:
    return (false, 0, 0)
  let spot = sim.nearestWalkable(sx div n, sy div n)
  (true, spot.x, spot.y)

proc flankWaypoint*(
  ctl: ControlState, sim: SimServer, cogIndex, targetX, targetY: int
): tuple[x, y: int] =
  ## `flank` routes THROUGH an empty row: the zone centre of row 1 or row 3 —
  ## whichever has had no enemy contact in the last HuntMemoryTicks; if both
  ## are contested, the one further from the most recent contact — in the
  ## column midway between the cog and the target. The straight line is where
  ## their cone already is, which is the whole reason this intent exists.
  let
    self = sim.players[cogIndex]
    px = self.x + CollisionW div 2
    py = self.y + CollisionH div 2
    cogCol = zoneColOf(zoneAtIndex(px, py))
    targetCol = zoneColOf(zoneAtIndex(targetX, targetY))
    midCol = (cogCol + targetCol) div 2
  var
    topSeen = 0
    bottomSeen = 0
    topDistance = 0
    bottomDistance = 0
  let
    topCentre = zoneCentreOf(zoneIndex(midCol, 0))
    bottomCentre = zoneCentreOf(zoneIndex(midCol, ZoneRows - 1))
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != self.team:
      continue
    let enemy = ctl.knownEnemy(sim, i)
    if not enemy.known:
      continue
    case zoneRowOf(zoneAtIndex(enemy.x, enemy.y))
    of 0:
      inc topSeen
      topDistance = max(
        topDistance, distSq(topCentre.x, topCentre.y, enemy.x, enemy.y))
    of 2:
      inc bottomSeen
      bottomDistance = max(
        bottomDistance,
        distSq(bottomCentre.x, bottomCentre.y, enemy.x, enemy.y))
    else: discard
  let pickTop =
    if topSeen == 0 and bottomSeen > 0: true
    elif bottomSeen == 0 and topSeen > 0: false
    elif topSeen == 0 and bottomSeen == 0: py < MapHeight div 2
    else: topDistance > bottomDistance
  let spot =
    if pickTop: sim.nearestWalkable(topCentre.x, topCentre.y)
    else: sim.nearestWalkable(bottomCentre.x, bottomCentre.y)
  (spot.x, spot.y)

proc goalFor*(
  ctl: ControlState, sim: SimServer, order: CogOrder, cogIndex: int
): tuple[x, y: int] =
  ## The goal point one intent resolves to for one cog. Every branch has a
  ## defined answer, so a cog is never left without somewhere to be — which is
  ## the whole of "no failure mode leaves a cog unactuated".
  let
    player = sim.players[cogIndex]
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    anchor = sim.gameMap.teamAnchor(player.team)
  case order.intent
  of intHunt:
    let enemy = ctl.knownEnemy(sim, cogIndex)
    if enemy.known: (enemy.x, enemy.y)
    else: (order.targetX, order.targetY)
  of intHold, intMoveTo:
    (order.targetX, order.targetY)
  of intFlank:
    let waypoint = ctl.flankWaypoint(sim, cogIndex, order.targetX, order.targetY)
    ## Inside ArriveRadius of the waypoint the goal becomes the target.
    if distSq(px, py, waypoint.x, waypoint.y) <= ArriveRadius * ArriveRadius:
      (order.targetX, order.targetY)
    else:
      waypoint
  of intRetreat:
    (anchor.x, anchor.y)
  of intRegroup:
    let centroid = sim.livingTeamCentroid(cogIndex)
    if centroid.found: (centroid.x, centroid.y) else: (anchor.x, anchor.y)

proc holdsPosition(order: CogOrder): bool {.inline.} =
  order.intent in {intHold, intRetreat, intRegroup}

proc teammateInCorridor*(
  sim: SimServer, cogIndex, targetX, targetY: int
): bool =
  ## Does any TEAMMATE's body box (+/- PlayerHalf) intersect the bullet
  ## corridor between this cog and its target? Friendly fire is on in the sim
  ## — it is a real Doom deathmatch hazard and a team kill costs a frag — but
  ## the DRIVER simply refuses to cause it, so a team kill in a replay is
  ## always an accident of movement (someone stepped into the corridor after
  ## the aim locked), never a bot bug.
  let
    self = sim.players[cogIndex]
    ax = self.x + CollisionW div 2
    ay = self.y + CollisionH div 2
    dx = targetX - ax
    dy = targetY - ay
    lenSq = dx * dx + dy * dy
  if lenSq <= 0:
    return false
  for i in 0 ..< sim.players.len:
    if i == cogIndex or not sim.players[i].alive:
      continue
    if sim.players[i].team != self.team:
      continue
    let
      mx = sim.players[i].x + CollisionW div 2
      my = sim.players[i].y + CollisionH div 2
      dot = (mx - ax) * dx + (my - ay) * dy
    if dot <= 0 or dot >= lenSq:
      continue                      ## behind the shooter, or past the target
    ## Perpendicular distance from the teammate's centre to the beam,
    ## compared squared so this stays integer.
    let cross = (mx - ax) * dy - (my - ay) * dx
    if int64(cross) * int64(cross) <=
        int64(PlayerHalf) * int64(PlayerHalf) * int64(lenSq):
      return true
  false

proc driverResult*(
  ctl: ControlState, sim: SimServer, order: CogOrder, cogIndex: int
): string =
  ## The driver's honest report of how the previous order is going, echoed
  ## into the seat's next observation. It is what lets a seat recover from a
  ## race it could not see.
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return "unknown_target"
  let player = sim.players[cogIndex]
  if not player.alive:
    return "dead"
  if order.unresolved:
    return "unknown_target"
  let
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    goal = ctl.goalFor(sim, order, cogIndex)
    enemy = ctl.knownEnemy(sim, cogIndex)
    arrived = distSq(px, py, goal.x, goal.y) <= ArriveRadius * ArriveRadius
  if enemy.known and enemy.ticksAgo == 0 and
      distSq(px, py, enemy.x, enemy.y) <= sim.config.gunRange * sim.config.gunRange:
    return "firing"
  if order.intent == intHunt and not arrived:
    return "chasing"
  if arrived:
    return (if order.holdsPosition(): "holding" else: "arrived")
  if cogIndex < ctl.stuckTicks.len and ctl.stuckTicks[cogIndex] >= StuckTicks * 4:
    return "no_route"
  "moving"

proc compileMask*(
  ctl: var ControlState,
  sim: SimServer,
  order: CogOrder,
  cogIndex: int
): uint8 =
  ## One cog's Sprite v1 actuator mask for this tick.
  ##
  ## Legality is structural, not checked afterwards: Up and Down are chosen
  ## from one sign so they can never both be set (same for Left/Right), B and
  ## Select come from one signed error, and C — the grenade/barrier button —
  ## is never touched, because deathmatch places neither.
  result = 0
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let player = sim.players[cogIndex]
  if not player.alive:
    return                              ## a dead cog's mask is exactly 0.
  let
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    goal = ctl.goalFor(sim, order, cogIndex)
    anchor = sim.gameMap.teamAnchor(player.team)
    centre = (x: MapWidth div 2, y: MapHeight div 2)

  # --- d-pad: the octant of the steering vector, unless we have arrived ---
  if distSq(px, py, goal.x, goal.y) > ArriveRadius * ArriveRadius:
    var steer = ctl.navSteer(sim.tickCount, px, py, goal.x, goal.y)
    if cogIndex < ctl.stuckTicks.len and ctl.stuckTicks[cogIndex] >= StuckTicks:
      # Wedged: steer a quarter turn clockwise instead, which slides the cog
      # ALONG whatever it is pressed against — another cog, a diamond that has
      # rotated into the lane, a wall the once-built field could not see. One
      # consistent rotation makes this a wall follower, so a convex obstacle is
      # always escaped rather than oscillated against.
      steer = (dx: -steer.dy, dy: steer.dx)
    let
      ax = abs(steer.dx)
      ay = abs(steer.dy)
      major = max(ax, ay)
    if major > 0:
      # Diagonals only when the minor axis is a real share of the major one,
      # so a nearly-straight run does not chatter between two octants.
      if ax * 5 >= major * 2:
        result = result or (if steer.dx > 0: ButtonRight else: ButtonLeft)
      if ay * 5 >= major * 2:
        result = result or (if steer.dy > 0: ButtonDown else: ButtonUp)

  # --- aim: your aim carries your vision, so where you point is where you see.
  let enemy = ctl.knownEnemy(sim, cogIndex)
  var
    aimX = goal.x
    aimY = goal.y
  if enemy.known and enemy.ticksAgo == 0 and
      distSq(px, py, enemy.x, enemy.y) <=
        sim.config.gunRange * sim.config.gunRange:
    aimX = enemy.x
    aimY = enemy.y
  elif order.hasFace:
    aimX = order.faceX
    aimY = order.faceY
  elif order.intent == intRetreat:
    aimX = centre.x
    aimY = centre.y
  elif distSq(px, py, goal.x, goal.y) <= AimMinRangeSq:
    ## Standing ON the goal gives an aim vector too short to mean a direction.
    ## A held cog then sweeps the bearing to the map centre — the fight comes
    ## from the middle — which is also what `hold` without a `face` does.
    aimX = centre.x
    aimY = centre.y
    if order.holdsPosition() and
        distSq(px, py, centre.x, centre.y) <= AimMinRangeSq:
      aimX = anchor.x
      aimY = anchor.y
  let
    desired = bradsOfVector(aimX - px, aimY - py)
    err = bradsErr(desired, player.aimBrads)
  if err > AimDeadBrads:
    result = result or ButtonB          ## counter-clockwise
  elif err < -AimDeadBrads:
    result = result or ButtonSelect     ## clockwise

  # --- THE TRIGGER RULE (the one named edit to compileMask) ----------------
  # `A` is pressed iff ALL of: the cog is alive; the gun is off cooldown and
  # no windup is in flight; a LIVE ENEMY is known with ticks_ago == 0 (seen
  # THIS tick, never a memory); it is inside gunRange; the aim error to it is
  # inside FireAimBrads; the line of sight is clear; and NO TEAMMATE's body
  # box intersects the bullet corridor. There is no suppressive fire and no
  # firing at memories, which bounds shotsFired and makes shotsHit/shotsFired
  # a meaningful accuracy number.
  if player.fireCooldown > 0 or player.fireWindup > 0:
    return
  if not enemy.known or enemy.ticksAgo != 0 or enemy.index < 0:
    return
  if enemy.index >= sim.players.len or not sim.players[enemy.index].alive:
    return
  if distSq(px, py, enemy.x, enemy.y) >
      sim.config.gunRange * sim.config.gunRange:
    return
  ## A retreating marine still defends itself — hold fire only while it is
  ## still a long way from its own anchor and running.
  if order.intent == intRetreat and
      distSq(px, py, anchor.x, anchor.y) > 300 * 300:
    return
  let fireErr = bradsErr(bradsOfVector(enemy.x - px, enemy.y - py), player.aimBrads)
  if abs(fireErr) > FireAimBrads:
    return
  if not sim.lineOfSightClear(px, py, enemy.x, enemy.y):
    return
  if sim.teammateInCorridor(cogIndex, enemy.x, enemy.y):
    return
  result = result or ButtonA
