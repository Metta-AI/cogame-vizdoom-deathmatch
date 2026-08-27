## The egocentric observation: what ONE cog's eyes see, written as text.
##
## Structurally this is ViZDoom's depth buffer plus its labels buffer: sixteen
## ray distances across the 90-degree cone, and one labelled row per thing the
## cone or the 90 px bubble actually contains. The idea's own note says "LLM
## needs the labels buffer"; this is that buffer, in JSON.
##
## `marchRays` is the SINGLE ray march in this repo. The seat's 16-ray depth
## strip and `broadcast.nim`'s `firstPersonJson` (96 columns for the big `#fpv`
## inset, 32 for each `#eyes` thumbnail) are the same proc at different
## resolutions, so the wall a model reads about and the wall a spectator sees
## can never disagree — `tests/test_vzd_sim.nim` asserts exactly that.
##
## FLOATS ARE FINE HERE and nowhere else in the fork's new code: this module
## produces TEXT for a model and PIXELS for a spectator, never a hashed value.
## `tests/test_vzd_determinism.nim` whitelists it by name for that reason and
## asserts nothing it returns reaches `gameHash`.

import
  std/[json, math, strutils],
  sim, zones

type
  RayHit* = object
    ## One marched column of the cone.
    bearingBrads*: float       ## the column's WORLD aim, in brads.
    offsetBrads*: float        ## the column's bearing relative to the cog's
                               ## own aim; negative is left.
    wall*: int                 ## perpendicular distance to the first opaque
                               ## wall, in px; -1 = nothing within range.
    glass*: int                ## perpendicular distance to the nearest glass
                               ## pane in front of it; -1 = none.

  ContactLabel* = enum
    clEnemy = "enemy"
    clAlly = "ally"
    clMedkit = "medkit"

  Contact* = object
    ## One row of the labels buffer.
    label*: ContactLabel
    id*: string                ## the cog's anonymous alias; empty for an item.
    bearing*: int              ## DEGREES relative to this cog's own aim.
    dist*: int                 ## px.
    zone*: string
    hp*: int                   ## -1 when the row is not a cog.
    ticksAgo*: int             ## 0 = seen this tick; > 0 = a MEMORY.

const
  MarchStep = 2.0             ## px per wall-march step (fine at 1235 px).

proc coneHalfBrads*(sim: SimServer): float {.inline.} =
  float(sim.config.visionConeDeg) * float(AimBradsTurn) / 360.0

proc marchRays*(
  sim: SimServer, cogIndex, columns: int, maxRange: int
): seq[RayHit] =
  ## The ONE ray march. Column 0 is the LEFT edge of the cone (counter-
  ## clockwise, i.e. the negative bearing) and column `columns-1` the right.
  ##
  ## Two distances per column: `wall` is the first OPAQUE pixel, which stops
  ## the view like stone, and `glass` the nearest window pane in front of it —
  ## glass is solid to bullets but transparent to vision (the starter's
  ## GV15/16 windows), so the march passes straight through it. Both are
  ## fisheye-corrected onto the central view axis, so a flat wall reads flat.
  if cogIndex < 0 or cogIndex >= sim.players.len or columns <= 0:
    return @[]
  let
    self = sim.players[cogIndex]
    px = float(self.x + CollisionW div 2)
    py = float(self.y + CollisionH div 2)
    aim = float(self.aimBrads)
    halfFov = sim.coneHalfBrads()
    reach = float(max(1, maxRange))
    radPerBrad = PI / float(AimBradsTurn div 2)
    mcx = sim.gameMap.center.x
    mcy = sim.gameMap.center.y
  for i in 0 ..< columns:
    let
      frac = (if columns == 1: 0.5 else: float(i) / float(columns - 1))
      offset = -halfFov + frac * 2.0 * halfFov
      colBrad = aim - offset
      rad = colBrad * radPerBrad
      dx = cos(rad)
      dy = -sin(rad)
      fish = cos(offset * radPerBrad)
    var
      t = MarchStep
      hit = -1
      glass = -1
    while t <= reach:
      let
        mx = int(px + dx * t)
        my = int(py + dy * t)
      if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
        break
      if sim.isWall(mx, my):
        if isArenaWindowPixel(mx, my, mcx, mcy):
          if glass < 0:
            glass = int(t * fish)
        else:
          hit = int(t * fish)
          break
      t += MarchStep
    result.add(RayHit(
      bearingBrads: colBrad, offsetBrads: offset, wall: hit, glass: glass))

proc bradsToDegrees(brads: float): int {.inline.} =
  int(round(brads * 360.0 / float(AimBradsTurn)))

proc compassOf*(brads: int): string =
  ## The nearest of the eight compass points. A model reasons better about
  ## "NE" than about "32". 0 brads is EAST and the angle grows anticlockwise.
  const points = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
  let wrapped = ((brads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
  points[((wrapped + AimBradsTurn div 16) div (AimBradsTurn div 8)) mod 8]

proc relativeBearing*(sim: SimServer, cogIndex, x, y: int): int =
  ## The bearing of a map point relative to this cog's own AIM, in degrees,
  ## negative to the left. An egocentric quantity, never a world angle.
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return 0
  let
    self = sim.players[cogIndex]
    world = bradsOfVector(
      x - (self.x + CollisionW div 2), y - (self.y + CollisionH div 2))
  var delta = self.aimBrads - world
  while delta < -(AimBradsTurn div 2): delta += AimBradsTurn
  while delta >= AimBradsTurn div 2: delta -= AimBradsTurn
  bradsToDegrees(float(-delta))

proc distanceTo(sim: SimServer, cogIndex, x, y: int): int =
  let self = sim.players[cogIndex]
  int(sqrt(float(distSq(
    self.x + CollisionW div 2, self.y + CollisionH div 2, x, y))))

proc contactsFor*(
  sim: SimServer,
  cogIndex: int,
  memoryX, memoryY, memoryIndex, memoryAge: int
): seq[Contact] =
  ## One row per entity this cog may legitimately see RIGHT NOW — inside the
  ## cone with a clear line, or inside the 90 px bubble — plus the control
  ## layer's own 72-tick enemy memory, tagged `ticks_ago` and positioned where
  ## the enemy WAS when it was seen. Filtered through `playerVisibleTo`, which
  ## is the sim's own fog rule, so the observation never knows more than the
  ## cog does.
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return @[]
  var seenEnemy = -1
  for other in 0 ..< sim.players.len:
    if other == cogIndex:
      continue
    let target = sim.players[other]
    if not target.alive:
      continue
    let sameTeam = target.team == sim.players[cogIndex].team
    if not sameTeam and not sim.playerVisibleTo(cogIndex, other):
      continue
    let
      tx = target.x + CollisionW div 2
      ty = target.y + CollisionH div 2
    if not sameTeam:
      seenEnemy = other
    result.add(Contact(
      label: (if sameTeam: clAlly else: clEnemy),
      id: sim.cogAlias(other),
      bearing: sim.relativeBearing(cogIndex, tx, ty),
      dist: sim.distanceTo(cogIndex, tx, ty),
      zone: zoneAt(tx, ty),
      hp: target.hp,
      ticksAgo: 0))
  ## The intel window: an enemy this cog saw within HuntMemoryTicks but cannot
  ## see now. It is a MEMORY and the row says so — it has moved since.
  if memoryIndex >= 0 and memoryAge > 0 and memoryIndex != seenEnemy:
    result.add(Contact(
      label: clEnemy,
      id: sim.cogAlias(memoryIndex),
      bearing: sim.relativeBearing(cogIndex, memoryX, memoryY),
      dist: sim.distanceTo(cogIndex, memoryX, memoryY),
      zone: zoneAt(memoryX, memoryY),
      hp: -1,
      ticksAgo: memoryAge))
  for spawn in sim.medKitSpawns:
    if not spawn.present:
      continue
    if not sim.fovVisibleAt(cogIndex, spawn.x, spawn.y):
      continue
    result.add(Contact(
      label: clMedkit,
      id: "",
      bearing: sim.relativeBearing(cogIndex, spawn.x, spawn.y),
      dist: sim.distanceTo(cogIndex, spawn.x, spawn.y),
      zone: zoneAt(spawn.x, spawn.y),
      hp: -1,
      ticksAgo: 0))

proc contactJson*(contact: Contact): JsonNode =
  %*{
    "label": $contact.label,
    "id": (if contact.id.len > 0: %contact.id else: newJNull()),
    "bearing": contact.bearing,
    "dist": contact.dist,
    "zone": contact.zone,
    "hp": (if contact.hp >= 0: %contact.hp else: newJNull()),
    "ticks_ago": contact.ticksAgo
  }

proc mapJson*(sim: SimServer, cogIndex: int): JsonNode =
  ## The map, published ONCE at a seat's first turn: the board box, all
  ## fifteen zones with their centres and terrain word, the two spawn-pocket
  ## anchors and the med-kit spawn points. Terrain is public knowledge here
  ## exactly as it is in the starter — only BODIES are fogged — because a seat
  ## that cannot navigate cannot play, and the driver's flow field would be
  ## lying to it.
  var zonesArr = newJArray()
  for i in 0 ..< ZoneCount:
    let centre = zoneCentreOf(i)
    zonesArr.add(%*{
      "id": zoneId(i), "c": [centre.x, centre.y], "t": sim.zoneTerrain(i)})
  var kits = newJArray()
  for spawn in sim.medKitSpawns:
    kits.add(%*{"at": [spawn.x, spawn.y], "zone": zoneAt(spawn.x, spawn.y)})
  let
    team =
      if cogIndex >= 0 and cogIndex < sim.players.len: sim.players[cogIndex].team
      else: Red
    other = if team == Red: Blue else: Red
    mine = sim.gameMap.teamAnchor(team)
    theirs = sim.gameMap.teamAnchor(other)
  %*{
    "w": MapWidth, "h": MapHeight,
    "zones": zonesArr,
    "your_spawn": zoneAt(mine.x, mine.y),
    "their_spawn": zoneAt(theirs.x, theirs.y),
    "medkits": kits
  }

proc heardJson*(sim: SimServer, cogIndex: int): JsonNode =
  ## Every shout within ShoutRange of this cog in the last ShoutTicks: who
  ## shouted, what they said, where it came from and how long ago. This is how
  ## a careless enemy gets found — a shout is heard by BOTH teams.
  result = newJArray()
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let
    self = sim.players[cogIndex]
    cx = self.x + CollisionW div 2
    cy = self.y + CollisionH div 2
  for shout in sim.recentShouts:
    if distSq(cx, cy, shout.x, shout.y) > ShoutRange * ShoutRange:
      continue
    result.add(%*{
      "team": toUpperAscii(teamText(shout.team)),
      "text": shout.text,
      "at": [shout.x, shout.y],
      "ticks_ago": sim.tickCount - shout.tick
    })

proc selfJson*(sim: SimServer, cogIndex: int): JsonNode =
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return newJNull()
  let
    self = sim.players[cogIndex]
    cx = self.x + CollisionW div 2
    cy = self.y + CollisionH div 2
  %*{
    "pos": [cx, cy],
    "aim": self.aimBrads,
    "facing": compassOf(self.aimBrads),
    "zone": zoneAt(cx, cy),
    "hp": self.hp,
    "alive": self.alive,
    "respawn_in_ticks": max(0, self.respawnTimer),
    "fire_ready": self.alive and self.fireCooldown == 0 and self.fireWindup == 0,
    "frags": self.kills,
    "deaths": self.deaths,
    "streak": self.killsThisLife
  }

proc raysJson*(rays: seq[RayHit]): JsonNode =
  result = newJArray()
  for ray in rays:
    result.add(%*[bradsToDegrees(ray.offsetBrads), ray.wall, ray.glass])
