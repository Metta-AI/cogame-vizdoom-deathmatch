## The engine end to end: a real eight-seat scripted episode, the determinism
## the replay viewer rests on, and the certification seed's own liveness.

import
  std/[json, os, strutils, unittest],
  vzd_helpers

const CertSeats = [blRusher, blRusher, blSentry, blSentry,
                   blRusher, blRusher, blSentry, blSentry]

proc runEpisode(
  maxTicks: int, kinds: openArray[Baseline], seed = 42, mapPath = "arena"
): tuple[sim: SimServer, hashes: seq[uint64], ticks: int] =
  var
    sim = newDeathmatchSim(deathmatchConfigJson(
      maxTicks = maxTicks, mapPath = mapPath, seed = seed))
    ctl = initControlState(sim)
    prev = newSeq[InputState](sim.players.len)
    orders = newSeq[SquadDirective](sim.seatCount())
    hashes: seq[uint64]
    stepped = 0
  sim.collectEvents = true
  for tick in 0 ..< maxTicks + 8:
    if sim.phase != Playing:
      break
    ctl.observeEnemies(sim)
    if sim.gameTicksElapsed() mod max(1, sim.config.turnTicks) == 0:
      for seat in 0 ..< sim.seatCount():
        orders[seat] = scriptedDirective(
          ctl, sim, kinds[seat mod kinds.len], sim.commandedCogs(seat))
    var inputs = newSeq[InputState](sim.players.len)
    for cogIndex in 0 ..< sim.players.len:
      let seat = sim.cogSeat(cogIndex)
      var
        order: CogOrder
        found = false
      for candidate in orders[seat].orders:
        if candidate.cogIndex == cogIndex:
          order = candidate
          found = true
          break
      if not found:
        let scripted = scriptedDirective(ctl, sim, blRusher, @[cogIndex])
        if scripted.orders.len == 0:
          continue
        order = scripted.orders[0]
      inputs[cogIndex] = decodeInputMask(ctl.compileMask(sim, order, cogIndex))
    sim.step(inputs, prev)
    prev = inputs
    hashes.add(sim.gameHash())
    stepped = tick + 1
  (sim, hashes, stepped)

suite "an episode runs to full time and settles":
  test "1080 all-scripted ticks end complete / full_time, exactly zero-sum":
    var run = runEpisode(1080, CertSeats)
    check run.sim.phase == GameOver
    check run.sim.endRule == EndRuleFullTime
    check run.sim.gameTicksElapsed() >= 1080
    let doc = parseJson(run.sim.playerResultsJson())
    check doc["reason"].getStr() == "complete"
    check doc["endRule"].getStr() == "full_time"
    check doc["games"].getInt() == 1
    check doc["names"].len == Seats
    check doc["scores"].len == Seats
    check abs(doc["scores"][0].getFloat() + doc["scores"][1].getFloat() - 1.0) <
      1e-9
    check doc["finalTick"].getInt() > 0
    check doc["map"].getStr() == "arena"
    ## `results.map` is the RESOLVED map, not the config's request: on the
    ## pool variant the same field names the entry the seed drew.
    check run.sim.gameMap.name == "arena"
    check doc["seed"].getInt() == 42

  test "no episode over many seeds ever reports mercy or wipe":
    for seed in [1, 7, 42, 99, 1234]:
      var run = runEpisode(300, CertSeats, seed = seed)
      check run.sim.endRule != "mercy"
      check run.sim.endRule != "wipe"
      check run.sim.endReason in ["", ReasonComplete]

suite "the certification seed is interesting":
  test "seed 42 on arena yields at least 4 kills and 1 respawn in 1080 ticks":
    ## The CI smoke replay always has to exercise the combat path, the kill
    ## feed and the beat markers. Four rushers against four sentries on the
    ## hand-tuned arena guarantees contact.
    var run = runEpisode(1080, CertSeats)
    var kills, respawns = 0
    for event in run.sim.events:
      case event.kind
      of Kill: inc kills
      of Respawn: inc respawns
      else: discard
    checkpoint("kills=" & $kills & " respawns=" & $respawns)
    check kills >= 4
    check respawns >= 1

suite "determinism":
  test "the same seed and the same orders re-derive the same hash chain":
    ## This is the property the wasm replay viewer rests on: it re-steps the
    ## sim from the recorded masks and compares gameHash EVERY tick.
    let a = runEpisode(480, CertSeats)
    let b = runEpisode(480, CertSeats)
    check a.ticks == b.ticks
    check a.hashes.len == b.hashes.len
    for i in 0 ..< a.hashes.len:
      if a.hashes[i] != b.hashes[i]:
        checkpoint("diverged at tick " & $i)
      check a.hashes[i] == b.hashes[i]

  test "the frag counters are IN the hash, so a frag cannot be lost":
    var run = runEpisode(240, CertSeats)
    let before = run.sim.gameHash()
    run.sim.players[0].kills += 1
    check run.sim.gameHash() != before

suite "the pool variant is a pure function of the seed":
  test "results.map names the RESOLVED pool entry, not the pool":
    var sim = newDeathmatchSim(deathmatchConfigJson(
      maxTicks = 120, mapPath = "pool", seed = 4711))
    check sim.config.mapPath == "pool"
    check sim.gameMap.name.len > 0
    check sim.gameMap.name != "pool"
    let doc = parseJson(sim.playerResultsJson())
    check doc["map"].getStr() == sim.gameMap.name

  test "two sims with the same seed install the same map":
    let a = newDeathmatchSim(deathmatchConfigJson(
      maxTicks = 120, mapPath = "pool", seed = 4711))
    let b = newDeathmatchSim(deathmatchConfigJson(
      maxTicks = 120, mapPath = "pool", seed = 4711))
    check a.gameMap.width == b.gameMap.width
    check a.gameMap.height == b.gameMap.height
    check a.config.mapSpec == b.config.mapSpec
    check a.config.mapSpec.len > 0

  test "every shipped variant resolves to 1235 x 659":
    for mapPath in ["arena", "pool"]:
      let sim = newDeathmatchSim(deathmatchConfigJson(
        maxTicks = 120, mapPath = mapPath))
      check MapWidth == 1235
      check MapHeight == 659
      check sim.gameMap.width == 1235
      check sim.gameMap.height == 659
