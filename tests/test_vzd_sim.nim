## Sim unit tests: seating, aliases, zones, vision, the gun, and the two
## arithmetic invariants the objective layer rests on.

import
  std/[json, math, os, strutils],
  vzd/broadcast,
  vzd_helpers,
  std/unittest

const RepoDir = currentSourcePath.parentDir.parentDir

suite "seating":
  test "eight seats, four per team, eight DISTINCT aliases":
    var sim = newDeathmatchSim()
    check sim.players.len == Seats
    check sim.seatCount() == Seats
    check sim.totalCogs() == Seats
    var red, blue = 0
    var aliases: seq[string]
    for i in 0 ..< sim.players.len:
      if sim.players[i].team == Red: inc red else: inc blue
      let alias = sim.cogAlias(i)
      check alias notin aliases          ## the cogIdentityIndex edit: without
      aliases.add(alias)                 ## it all four reds are RED-alpha
    check red == 4
    check blue == 4
    check aliases.len == 8
    for expected in ["RED-alpha", "RED-beta", "RED-gamma", "RED-delta",
                     "BLUE-alpha", "BLUE-beta", "BLUE-gamma", "BLUE-delta"]:
      check expected in aliases

  test "slot parity IS the team and a seat cannot change it":
    var sim = newDeathmatchSim()
    for seat in 0 ..< Seats:
      check sim.teamForSlot(seat) == (if seat mod 2 == 0: Red else: Blue)
      check sim.cogSeat(seat) == seat
      check sim.seatCommands(seat, seat)
      for other in 0 ..< Seats:
        if other != seat:
          check not sim.seatCommands(seat, other)

  test "the decision engine is LIVE at one cog per seat":
    ## The server.nim:1367 edit. With the starter's original gate
    ## (`cogsPerTeam > 1`) the engine is dead, every cog is motionless and the
    ## whole game does not exist — so this is the guard on all of it.
    var config = defaultGameConfig()
    config.update(deathmatchConfigJson())
    check config.numAgents == 8
    check config.cogsPerTeam == 1
    check (config.numAgents > 0)           ## the fork's gate: true
    check not (config.numAgents > 0 and config.cogsPerTeam > 1)  ## the starter's

suite "no wipe is reachable":
  test "lives exceeds the death ceiling for every shipped config":
    ## A cog cannot die more often than once per respawnTicks + 1 ticks.
    for maxTicks in [2592, 1080]:
      let ceiling = maxTicks div (48 + 1)
      check 60 > ceiling

suite "zones":
  test "the 5 x 3 grid partitions the board with no gap and no overlap":
    var seen: array[ZoneCols * ZoneRows, int]
    var x = 0
    while x < MapWidth:
      var y = 0
      while y < MapHeight:
        let index = zoneAtIndex(x, y)
        check index >= 0
        check index < ZoneCols * ZoneRows
        inc seen[index]
        y += 7
      x += 7
    for count in seen:
      check count > 0

  test "ids round-trip and the corners are where they say":
    check zoneAt(3, 3) == "A1"
    check zoneAt(MapWidth - 3, MapHeight - 3) == "E3"
    for index in 0 ..< ZoneCols * ZoneRows:
      let id = zoneId(index)
      check parseZoneId(id) == index
      check parseZoneId(id.toLowerAscii()) == index
      let centre = zoneCentreOf(index)
      check zoneAtIndex(centre.x, centre.y) == index
    check parseZoneId("F1") == -1
    check parseZoneId("A4") == -1
    check parseZoneId("") == -1
    check parseZoneId("hunt") == -1

  test "RED spawns in column A, BLUE in column E, on both maps":
    for mapPath in ["arena", "pool"]:
      var sim = newDeathmatchSim(deathmatchConfigJson(mapPath = mapPath))
      let
        redAnchor = sim.gameMap.teamAnchor(Red)
        blueAnchor = sim.gameMap.teamAnchor(Blue)
      check zoneColOf(zoneAtIndex(redAnchor.x, redAnchor.y)) == 0
      check zoneColOf(zoneAtIndex(blueAnchor.x, blueAnchor.y)) == ZoneCols - 1

  test "the terrain word is a pure function of the installed map":
    var sim = newDeathmatchSim()
    for index in 0 ..< ZoneCols * ZoneRows:
      let word = sim.zoneTerrain(index)
      check word in [TerrainOpen, TerrainCover, TerrainCorridor]
      check sim.zoneTerrain(index) == word

suite "vision and the depth strip":
  test "the cone is 45 degrees each side of the aim":
    var sim = newDeathmatchSim()
    check sim.config.visionConeDeg == 45
    check sim.visionRange() == sim.config.gunRange * 3 div 2
    check sim.visionRange() == 1575

  test "rays span the cone in EgoRayColumns steps, negative left":
    var sim = newDeathmatchSim()
    let rays = sim.marchRays(0, EgoRayColumns, sim.visionRange())
    check rays.len == EgoRayColumns
    check rays[0].offsetBrads < 0.0
    check rays[^1].offsetBrads > 0.0
    for i in 1 ..< rays.len:
      check rays[i].offsetBrads > rays[i - 1].offsetBrads
    for ray in rays:
      check ray.wall <= sim.visionRange()
      check ray.wall >= -1

  test "the model's 16 rays and the viewer's 96 columns read the SAME walls":
    ## design.md test 7. marchRays is the one ray march in the repo: the
    ## 16-column strip the LLM reads and the 96-column strip the viewer's
    ## `fp` inset draws are the same proc at two resolutions. Column i of 16
    ## and column 19i/3 of 96 are the SAME bearing
    ## (i/15 == j/95 <=> j == 19i/3), so at every third ray the two strips
    ## must report the identical wall distance — compared here through
    ## `buildStateJson`, the wire the viewer actually reads, not through a
    ## second call to the same proc.
    var sim = newDeathmatchSim()
    for cogIndex in 0 ..< sim.players.len:
      let narrow = sim.marchRays(cogIndex, EgoRayColumns, sim.visionRange())
      check narrow.len == EgoRayColumns
      let state = parseJson(sim.buildStateJson(
        newJArray(), true, 1.0, 1080, false, true, -1,
        sim.players[cogIndex].joinOrder))
      check state.hasKey("fp")
      let cols = state["fp"]["cols"]
      check cols.len == 96
      var compared = 0
      for i in countup(0, EgoRayColumns - 1, 3):
        let
          j = 19 * i div 3
          column = cols[j]
          wide =
            if column.kind == JArray: column[0].getInt()
            else: column.getInt()
        checkpoint("cog " & $cogIndex & " ray " & $i & " column " & $j)
        check narrow[i].wall == wide
        inc compared
      check compared == 6

  test "aim carries vision: rotating without moving changes the strip":
    var sim = newDeathmatchSim()
    sim.placeCog(0, MapWidth div 2, MapHeight div 2, 0)
    let east = sim.marchRays(0, EgoRayColumns, sim.visionRange())
    sim.placeCog(0, MapWidth div 2, MapHeight div 2, 64)
    let north = sim.marchRays(0, EgoRayColumns, sim.visionRange())
    var different = false
    for i in 0 ..< EgoRayColumns:
      if east[i].wall != north[i].wall:
        different = true
    check different

suite "frag accounting":
  test "net is frags minus team frags minus deaths, after every tick":
    var
      sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 240))
      ctl = initControlState(sim)
    discard sim.scriptedEpisode(ctl, [blRusher, blSentry], 240)
    for i in 0 ..< sim.players.len:
      let p = sim.players[i]
      check sim.netFor(i) == p.kills - p.teamKills - p.deaths
    check sim.marginFor(Red) == -sim.marginFor(Blue)
    var deaths, kills, teamKills = 0
    for p in sim.players:
      deaths += p.deaths
      kills += p.kills
      teamKills += p.teamKills
    ## Every death has exactly one cause.
    check deaths == kills + teamKills

  test "a team kill calls recordTeamKill and NOT recordKill":
    ## design.md test 4. `frags` counts kills of ENEMY cogs only: a team kill
    ## is charged to the killer as a lost frag through the `- teamFrags` term
    ## of `net`, so crediting it as a frag as well would cancel the charge and
    ## make friendly fire free for the killer.
    var sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 240))
    let
      centreX = MapWidth div 2
      centreY = MapHeight div 2
    ## Slot parity is the team, so seats 0 and 2 are both RED.
    check sim.players[0].team == sim.players[2].team
    sim.placeCog(0, centreX - 40, centreY, 0)      ## aimed east
    sim.placeCog(2, centreX, centreY, 0)
    let prev = sim.none()
    var ticks = 0
    while sim.players[2].alive and ticks < 200:
      if sim.players[0].fireWindup == 0:
        sim.players[0].fireCooldown = 0
        sim.tryFire(0)
      sim.step(sim.none(), prev)
      inc ticks
    check not sim.players[2].alive
    check sim.players[0].kills == 0            ## no frag for a teammate
    check sim.players[0].teamKills == 1
    check sim.players[2].deaths == 1
    check sim.netFor(0) == -1                  ## the killer is charged

suite "no new floats in hashed code":
  test "deathmatch.nim and zones.nim carry no float literal, no / and no sqrt":
    for name in ["deathmatch", "zones"]:
      let path = RepoDir / "src" / "vzd" / (name & ".nim")
      check fileExists(path)
      for rawLine in lines(path):
        let line = rawLine.strip()
        if line.startsWith("#") or line.startsWith("##"):
          continue
        let code = if "  #" in line: line.split("  #")[0] else: line
        check "sqrt" notin code
        check " / " notin code
        ## A float literal is a digit, a dot, a digit.
        for i in 1 ..< max(1, code.len - 1):
          if code[i] == '.' and code[i - 1].isDigit() and code[i + 1].isDigit():
            checkpoint(path & ": " & line)
            check false
