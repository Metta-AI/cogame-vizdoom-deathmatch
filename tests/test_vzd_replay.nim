## The replay contract: the magic, the game name, the strict-UTF-8 property
## every recorded string has to keep, and the record-then-re-derive proof.
##
## "record then re-derive" is asserted HERE, from the bytes: `recordEpisode`
## writes a real `.replay` through the same `ReplayWriter` calls `server.nim`
## makes, and `rederive` parses those bytes back and re-simulates them through
## `initReplayRuntime` / `stepReplay` — the viewer's own entry point — with
## `checkReplayHash` comparing the recorded chain tick for tick. Every end
## reason is covered, `wall_clock` and `sim_fault` included, because those two
## end the game from a `stop` record rather than from sim state.

import
  std/[json, os, strutils, tables, unicode, unittest],
  vzd/[replay_runtime, replays, wire_constants],
  vzd_helpers

const RepoDir = currentSourcePath.parentDir.parentDir

suite "the replay header":
  test "the magic is this game's, not the starter's":
    check VzdReplayMagic == "COWLDVZD"
    check VzdReplayMagic.len == 8
    check GameName == "vizdoom-deathmatch"
    check GameVersion == "1"

  test "replay_summary.py agrees about the magic and the protocol":
    let summary = readFile(RepoDir / "tools" / "replay_summary.py")
    check "COWLDVZD" in summary
    check "vizdoom-deathmatch/v1" in summary
    check "COWLDCTF" notin summary
    ## It is python3 stdlib ONLY: no Nim, no Docker, no emsdk.
    for banned in ["import requests", "import numpy", "subprocess"]:
      check banned notin summary

suite "every recorded string is rune-truncated":
  test "a record filled to every cap with 4-byte emoji stays valid UTF-8":
    ## Byte truncation is what makes a replay that renders in a browser fail a
    ## strict UTF-8 parser. Every cap is filled to exactly its limit with an
    ## emoji sitting ON the boundary.
    var sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 120))
    let emoji = "\u{1F480}"
    var
      say = ""
      radio = ""
      note = ""
    for _ in 0 ..< MaxSayRunes: say.add(emoji)
    for _ in 0 ..< MaxRadioRunes: radio.add(emoji)
    for _ in 0 ..< MaxNoteRunes: note.add(emoji)
    var directive = SquadDirective(
      source: dsLlm,
      note: sanitizeNote(note),
      radio: sanitizeRadio(radio),
      orders: @[CogOrder(
        cogIndex: 0, id: sim.cogAlias(0), intent: intHunt, at: "C2",
        targetX: 617, targetY: 330, say: sanitizeSay(say))])
    let record = directive.boundedDirectiveRecord(
      1, 4, 0, "red", sim.cogAlias(0))
    check validateUtf8(record) == -1
    check record.runeLen <= MaxDirectiveRunes
    let parsed = parseJson(record)              ## and it is still JSON
    check parsed["k"].getStr() == "directive"
    check parsed["alias"].getStr() == "RED-alpha"
    check parsed["radio"].getStr().runeLen <= MaxRadioRunes
    check parsed["note"].getStr().runeLen <= MaxNoteRunes

  test "the fallback detail and the stop detail are capped too":
    var long = ""
    for _ in 0 ..< MaxFallbackDetailRunes + 40: long.add("\u{1F480}")
    check long.truncateRunes(MaxFallbackDetailRunes).runeLen ==
      MaxFallbackDetailRunes
    check validateUtf8(long.truncateRunes(MaxFallbackDetailRunes)) == -1
    var sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 120))
    sim.endReason = ReasonDeadline
    sim.endRule = EndRuleWallClock
    sim.stopDetail = long
    let doc = parseJson(sim.playerResultsJson())
    check doc["stopDetail"].getStr().runeLen <= MaxFallbackDetailRunes
    check validateUtf8(doc["stopDetail"].getStr()) == -1
    check doc["reason"].getStr() == "deadline"
    check doc["endRule"].getStr() == "wall_clock"

  test "a shout can never open a control record":
    ## The replay chat stream tells a CONTROL record from a cog's shout by a
    ## leading '{', so the shout sanitiser drops braces outright.
    check sanitizeSay("{\"k\":\"x\"}") == "\"k\":\"x\""
    check "{" notin sanitizeSay("{hi}")
    check "}" notin sanitizeSay("{hi}")

suite "the replay is self-sufficient":
  test "the config echo carries everything the viewer re-simulates from":
    var sim = newDeathmatchSim(deathmatchConfigJson(mapPath = "pool"))
    let echoed = parseJson(sim.config.configJson())
    for key in ["seed", "mapPath", "num_agents", "cogsPerTeam", "maxTicks",
                "maxGames", "turnTicks", "lives", "hitPoints", "respawnTicks",
                "gunRange", "fireCooldownTicks", "fireWindupTicks",
                "aimTurnRate", "visionConeDeg", "visionBubble", "fastMode",
                "showPlayerLabels", "players", "slots", "loadout"]:
      checkpoint(key)
      check echoed.hasKey(key)
    check echoed["loadout"].getStr() == LoadoutDeathmatch
    check echoed["num_agents"].getInt() == Seats
    check echoed["cogsPerTeam"].getInt() == 1
    ## The map is pinned as a DOCUMENT, not as a name, so a later edit to the
    ## pool cannot change what an old replay renders.
    ## The map is pinned as a JSON OBJECT, not as a string: `mapSpec` in the
    ## echo is the resolved geometry document itself.
    check echoed.hasKey("mapSpec")
    check echoed["mapSpec"].kind == JObject
    check echoed["mapSpec"].len > 0
    ## The token array in the replay echo is the SLOT tokens the sim was
    ## handed; it is never a manifest field (config_schema requires the runner
    ## to inject them, and no game_config carries a literal one).
    check echoed.hasKey("tokens")

# ---------------------------------------------------------------------------
# Record, then re-derive from the bytes (design.md test 26; acceptance
# checklist item 2).
# ---------------------------------------------------------------------------

const CertSeats = [blRusher, blRusher, blSentry, blSentry,
                   blRusher, blRusher, blSentry, blSentry]

type Recorded = object
  path: string
  ticks: int            ## ticks whose hash was written
  stopTick: int         ## the tick the `stop` record names, or -1
  endRule: string       ## the end rule the RECORDING sim reached

proc recordEpisode(
  path: string, maxTicks: int, stopAt = -1, stopRule = ""
): Recorded =
  ## Records one real episode exactly the way `server.nim` records it: eight
  ## joins into the lobby, one input-mask change per cog per tick from the
  ## same control layer, one hash per stepped tick, and — for the two stops
  ## the sim itself cannot reach — the load-bearing `stop` record.
  ##
  ## `stopRule == EndRuleWallClock` is written BEFORE the frame's step, as the
  ## server's wall-clock branch writes it, so the stop tick is hashed too.
  ## `EndRuleSimFault` is written AFTER a step whose hash is never reached,
  ## as the server's fault branch writes it.
  var config = defaultGameConfig()
  config.update(deathmatchConfigJson(maxTicks = maxTicks))
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var writer = openReplayWriter(path, config.configJson())
  for order in 0 ..< Seats:
    let
      name = "Cog" & $(order + 1)
      token = "t" & $order
    discard sim.addPlayer(name, order, token)
    sim.seatNames[order] = name
    writer.writeJoin(tickTime(sim.tickCount), order, name, order, token)
    while writer.lastMasks.len < sim.players.len:
      writer.lastMasks.add(0'u8)
  var
    ctl = initControlState(sim)
    prev = newSeq[InputState](sim.players.len)
    orders = newSeq[SquadDirective](sim.seatCount())
    stopped = false
  result.path = path
  result.stopTick = -1
  for _ in 0 ..< maxTicks + 16:
    if sim.phase == GameOver or stopped:
      break
    if stopAt >= 0 and stopRule == EndRuleWallClock and
        sim.tickCount == stopAt and sim.phase == Playing:
      let record = stopRecordJson(sim.tickCount, EndRuleWallClock)
      writer.writeChat(tickTime(sim.tickCount), 0, record)
      sim.applyStopRecord(record)
      result.stopTick = stopAt
      stopped = true
    var inputs = newSeq[InputState](sim.players.len)
    if sim.phase == Playing:
      ctl.observeEnemies(sim)
      if sim.gameTicksElapsed() mod max(1, sim.config.turnTicks) == 0:
        for seat in 0 ..< sim.seatCount():
          orders[seat] = scriptedDirective(
            ctl, sim, CertSeats[seat mod CertSeats.len],
            sim.commandedCogs(seat))
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
        let mask = ctl.compileMask(sim, order, cogIndex)
        inputs[cogIndex] = decodeInputMask(mask)
        writer.writeInputMaskChange(tickTime(sim.tickCount), cogIndex, mask)
    else:
      ## Not Playing: the server tells the replay the masks are zero, or
      ## playback keeps re-applying the last ones.
      for cogIndex in 0 ..< sim.players.len:
        writer.writeInputMaskChange(tickTime(sim.tickCount), cogIndex, 0'u8)
    sim.step(inputs, prev)
    prev = inputs
    if stopAt >= 0 and stopRule != EndRuleWallClock and
        sim.tickCount >= stopAt:
      ## The fault branch: the tick that raised writes NO hash, and the stop
      ## record carries the tick the exception left behind.
      let record = stopRecordJson(sim.tickCount, stopRule)
      writer.writeChat(tickTime(sim.tickCount), 0, record)
      sim.applyStopRecord(record)
      result.stopTick = sim.tickCount
      break
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc result.ticks
  writer.closeReplayWriter()
  result.endRule = sim.endRule

type Rederived = object
  matched: int          ## recorded hashes consumed and matched
  recorded: int         ## recorded hashes in the file
  mismatchTick: int
  failed: bool
  phase: GamePhase
  endRule: string
  finalTick: int

proc rederive(path: string): Rederived =
  ## Re-simulates the recorded bytes through the runtime the wasm viewer uses.
  ## `checkReplayHash` compares the re-derived `gameHash` against the recorded
  ## one at EVERY tick; the per-tick table below re-asserts it independently
  ## so a silently skipped tick cannot pass.
  let data = parseReplayBytes(readFile(path))
  var runtime = initReplayRuntime(
    data, mismatchQuit = false, gameEventLoggingEnabled = false)
  var
    derived = initTable[int, uint64]()
    first = runtime.sim.tickCount
    guard = 0
  derived[runtime.sim.tickCount] = runtime.sim.gameHash()
  while runtime.player.hashIndex < data.hashes.len and
      not runtime.player.hashValidationFailed and
      guard < data.hashes.len + 64:
    runtime.player.stepReplay(runtime.sim)
    derived[runtime.sim.tickCount] = runtime.sim.gameHash()
    inc guard
  ## Nothing is stepped past the end of the chain: this is exactly where the
  ## viewer's presentation loop stops (`checkReplayHash` clears `playing`), so
  ## the state asserted below is the state a spectator is left looking at —
  ## including the trailing `stop`, which `advanceReplayPlayback` applies on
  ## the frame the chain runs out, through this same proc.
  runtime.player.applyTrailingStop(runtime.sim)
  result.recorded = data.hashes.len
  result.mismatchTick = runtime.player.hashMismatchTick
  result.failed = runtime.player.hashValidationFailed
  result.phase = runtime.sim.phase
  result.endRule = runtime.sim.endRule
  result.finalTick = runtime.sim.tickCount
  for entry in data.hashes:
    let tick = int(entry.tick)
    if tick < first:
      continue
    if derived.getOrDefault(tick, 0'u64) == entry.hash:
      inc result.matched

suite "record then re-derive, every end reason":
  ## The property the whole static-viewer story rests on: the RECORDED BYTES,
  ## re-simulated, reproduce the recorded per-tick state frame by frame.

  setup:
    let workDir = getTempDir() / "vzd-rederive"
    createDir(workDir)

  test "full_time: every recorded hash re-derives from the bytes":
    let path = workDir / "full_time.replay"
    let recorded = recordEpisode(path, maxTicks = 240)
    check recorded.endRule == EndRuleFullTime
    check recorded.ticks > 200
    let back = rederive(path)
    checkpoint("mismatch at tick " & $back.mismatchTick)
    check not back.failed
    check back.mismatchTick < 0
    check back.recorded == recorded.ticks
    check back.matched == back.recorded      ## frame by frame, all of them
    check back.phase == GameOver
    check back.endRule == EndRuleFullTime
    removeFile(path)

  test "wall_clock: the stop tick re-derives too":
    ## The wall clock is a fact the sim cannot re-derive, so it rides the
    ## chat stream as a `stop` record and BOTH sides end the game through
    ## `applyStopRecord`. Without that, playback's hash at the stop tick
    ## disagrees with the recorded one.
    let path = workDir / "wall_clock.replay"
    let recorded = recordEpisode(
      path, maxTicks = 240, stopAt = 120, stopRule = EndRuleWallClock)
    check recorded.stopTick == 120
    check recorded.endRule == EndRuleWallClock
    let back = rederive(path)
    checkpoint("mismatch at tick " & $back.mismatchTick)
    check not back.failed
    check back.mismatchTick < 0
    check back.matched == back.recorded
    check back.phase == GameOver
    check back.endRule == EndRuleWallClock
    check back.finalTick <= 130              ## it stopped where it was told
    removeFile(path)

  test "sim_fault: the stop record ends playback at the fault tick":
    let path = workDir / "sim_fault.replay"
    let recorded = recordEpisode(
      path, maxTicks = 240, stopAt = 96, stopRule = EndRuleSimFault)
    check recorded.stopTick >= 96
    check recorded.endRule == EndRuleSimFault
    let back = rederive(path)
    checkpoint("mismatch at tick " & $back.mismatchTick)
    check not back.failed
    check back.mismatchTick < 0
    check back.matched == back.recorded
    check back.phase == GameOver
    check back.endRule == EndRuleSimFault
    removeFile(path)

suite "the 1/2x playback speed":
  ## The fleet-wide half speed: command '5' selects ReplayHalfSpeedIndex, the
  ## chrome shows 0.5, and the step budget spends one sim tick every OTHER
  ## frame (halfPhase parity) outside a fast-forwarded lull.
  test "'5' selects a crawl the chrome reports as 0.5":
    var replay = ReplayPlayer()
    replay.speedIndex = 0
    applySpeedCommand(replay.speedIndex, '5')
    check replay.speedIndex == ReplayHalfSpeedIndex
    check replay.replayDisplaySpeed() == 0.5
    ## The integer speed clamps to 1x, which is what the live loop and the
    ## board's transport sprite read.
    check replay.replaySpeed() == 1

  test "a tick is spent every other frame":
    var replay = ReplayPlayer()
    replay.speedIndex = ReplayHalfSpeedIndex
    replay.skipLulls = false
    replay.halfPhase = false
    check replay.replayStepBudget(0) == 0
    replay.halfPhase = true
    check replay.replayStepBudget(0) == 1

  test "'-' floors at 1/2x and '+' climbs back out of it":
    var speedIndex = 0
    applySpeedCommand(speedIndex, '-')
    check speedIndex == ReplayHalfSpeedIndex
    applySpeedCommand(speedIndex, '-')
    check speedIndex == ReplayHalfSpeedIndex
    applySpeedCommand(speedIndex, '+')
    check speedIndex == 0

  test "the wire constants offer 0.5 ahead of the engine's speeds":
    check WireConstantsJs.startsWith("window.VZD_WIRE={speeds:[0.5,1,")
