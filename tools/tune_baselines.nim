## The baseline parameter grid harness.
##
## `holdline` and `sprayer` have exactly three tunables (`BaselineParams`), and
## the design note asks for the second to LOSE to the first — that ordering is
## what gives a ladder of scripted fillers a spread instead of a coin flip.
## This tool is where those three numbers come from. It plays the head-to-head
## episode over a BOUNDED matrix of them, each cell as a small ladder (three
## seeds, each played BOTH WAYS round so a side bias cannot be mistaken for a
## policy edge), prints one row per cell, and names the cell that wins the most
## episodes (hill-tick margin breaks ties).
##
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim
##
## With `--check` (how ci.yml runs it, in the `test` job) it additionally
## asserts that the sweep's pick is still what `DefaultBaselineParams` ships
## and what `tools/ci/baseline_tuning.json` records, and exits non-zero when it
## is not. A guessed constant drifts silently; a harness in CI does not.
##
## What the sweep found, and why the shipped numbers are not the note's
## first guesses (200 px hunt / 250 px guard): at a 250 px standoff the
## `guard` cog is out of the fight altogether, so `holdline` plays three
## painters against `sprayer`'s four and loses the hill outright; and a wide
## hunt radius pulls its hill cogs off the square to chase. Pulling both in
## flips the ordering the note names.

import
  std/[json, os, strformat, strutils],
  bitworld/spriteprotocol,
  ctf/[sim, control, directives, baselines]

const
  Ticks* = 3000           ## per episode: long enough for the hill to settle
  Record = "tools/ci/baseline_tuning.json"
  Seeds* = [679961, 11, 4242]
    ## The ladder. Exported because tests/test_control.nim measures the
    ## baseline ordering with THIS driver on THESE seeds — one implementation,
    ## so the test can never disagree with the sweep that chose the numbers.

  ## The matrix. Deliberately small — every cell is six real episodes, and the
  ## point is a defensible, reproducible choice, not a search of the whole
  ## space. `holdline`'s hunt radius stays >= `sprayer`'s 120 px (the note's
  ## "the weaker baseline commits later"), and the note's own 200/250 guess is
  ## in the table so the row that lost is on the record.
  HoldlineHuntRadii = [130, 150, 170, 200]
  GuardStandoffs = [110, 120, 130, 250]
  SprayerHuntRadius = 120

proc configJson(seed: int): string =
  $(%*{
    "seed": seed,
    "num_agents": 2,
    "minPlayers": 2,
    "cogsPerTeam": 4,
    "maxTicks": Ticks,
    "maxGames": 1,
    "regimes": ["resident"],
    "lives": 12,
    "hitPoints": 3,
    "sprayDamage": 1,
    "respawnTicks": 48,
    "mapPath": "arena",
    "loadout": "paintball",
    "floorPaint": true,
    "paintBuff": true,
    "hill": true,
    "turnTicks": 108,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 4,
    "lobbyJoinTimeoutTicks": 0,
    "fastMode": true,
    "showPlayerLabels": false,
    "tokens": ["t0", "t1"],
    "players": [{"name": "holdline"}, {"name": "sprayer"}],
    "slots": [{"team": "red"}, {"team": "blue"}]
  })

proc newSim(seed: int): SimServer =
  var config = defaultGameConfig()
  config.update(configJson(seed))
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("holdline", 0, "t0")
  discard result.addPlayer("sprayer", 1, "t1")
  for order in 2 ..< result.totalCogs():
    discard result.addPlayer(
      toUpperAscii(teamText(result.teamForSlot(order))) & "-" &
      IdentityNames[result.slotIdentityIndex(order)],
      order, "", trusted = true)
  result.startGame()

proc playEpisode*(
  seed: int, params: BaselineParams, holdlineOnBlue: bool
): tuple[holdline, sprayer, paintHoldline, paintSprayer, flips: int,
         endReason: string] =
  ## One head-to-head episode through the REAL control layer on the real
  ## 108-tick turn cadence — the same path the server takes. `holdlineOnBlue`
  ## swaps the seats, so each cell is measured from both sides of a
  ## mirror-symmetric arena.
  var sim = newSim(seed)
  var ctl = initControlState(sim)
  var directives = newSeq[SquadDirective](2)
  var prev = newSeq[InputState](sim.players.len)
  var lastOwner = -1
  let kinds =
    if holdlineOnBlue: [blSprayer, blHoldline] else: [blHoldline, blSprayer]
  for tick in 0 ..< Ticks:
    if sim.phase != Playing:
      break
    ctl.observeEnemies(sim)
    if sim.gameTicksElapsed() mod sim.config.turnTicks == 0:
      for seat in 0 .. 1:
        directives[seat] = scriptedDirective(
          ctl, sim, kinds[seat], sim.commandedCogs(seat), params)
    var inputs = newSeq[InputState](sim.players.len)
    for cogIndex in 0 ..< sim.players.len:
      let seat = sim.cogSeat(cogIndex)
      for order in directives[seat].orders:
        if order.cogIndex == cogIndex:
          inputs[cogIndex] = decodeInputMask(
            ctl.compileMask(sim, order, cogIndex))
          break
    sim.step(inputs, prev)
    prev = inputs
    let owner = if sim.hillOwned: ord(sim.hillOwner) else: -1
    if owner != lastOwner:
      if lastOwner >= 0 or owner >= 0:
        inc result.flips
      lastOwner = owner
  let holdlineTeam = if holdlineOnBlue: Blue else: Red
  let sprayerTeam = if holdlineOnBlue: Red else: Blue
  result.holdline = sim.hillTicks[holdlineTeam]
  result.sprayer = sim.hillTicks[sprayerTeam]
  result.paintHoldline = sim.paintCount[holdlineTeam]
  result.paintSprayer = sim.paintCount[sprayerTeam]
  result.endReason = sim.endReason

when isMainModule:
  let
    check = "--check" in commandLineParams()
    write = "--write" in commandLineParams()
  var
    best = DefaultBaselineParams
    bestWins = -1
    bestMargin = low(int)
    rows = newJArray()
  echo "baseline grid harness: holdline vs sprayer, ", Ticks,
    " ticks, seeds ", Seeds, ", each seed played from both sides"
  echo "  huntHoldline  guardStandoff |  wins  margin  flips | per-episode " &
    "holdline:sprayer"
  for holdlineRadius in HoldlineHuntRadii:
    for standoff in GuardStandoffs:
      let params = BaselineParams(
        huntRadiusHoldline: holdlineRadius,
        huntRadiusSprayer: SprayerHuntRadius,
        guardStandoff: standoff)
      var
        wins = 0
        margin = 0
        flips = 0
        detail = ""
      for seed in Seeds:
        for holdlineOnBlue in [false, true]:
          let outcome = playEpisode(seed, params, holdlineOnBlue)
          if outcome.holdline > outcome.sprayer:
            inc wins
          margin += outcome.holdline - outcome.sprayer
          flips += outcome.flips
          detail.add &" {outcome.holdline}:{outcome.sprayer}"
      echo &"  {holdlineRadius:>12}  {standoff:>13} | {wins:>2}/6 " &
        &"{margin:>7} {flips:>6} |{detail}"
      rows.add(%*{
        "huntRadiusHoldline": holdlineRadius,
        "huntRadiusSprayer": SprayerHuntRadius,
        "guardStandoff": standoff,
        "wins": wins,
        "episodes": Seeds.len * 2,
        "margin": margin,
        "hillFlips": flips
      })
      if wins > bestWins or (wins == bestWins and margin > bestMargin):
        bestWins = wins
        bestMargin = margin
        best = params
  echo "sweep pick: huntRadiusHoldline=", best.huntRadiusHoldline,
    " huntRadiusSprayer=", best.huntRadiusSprayer,
    " guardStandoff=", best.guardStandoff,
    " (", bestWins, "/", Seeds.len * 2, " episodes, margin ", bestMargin, ")"

  if write:
    ## Regenerate the committed record from this run. Run it whenever a
    ## baseline's SHAPE changes — the numbers are only meaningful next to the
    ## grid they won.
    let record = %*{
      "harness": "tools/tune_baselines.nim",
      "ticks": Ticks,
      "seeds": Seeds,
      "episodesPerCell": Seeds.len * 2,
      "note": "each cell is one holdline-vs-sprayer episode per seed from " &
        "both sides; the pick wins the most episodes, hill-tick margin " &
        "breaks ties. holdline's hunt radius stays >= sprayer's 120 px.",
      "chosen": {
        "huntRadiusHoldline": best.huntRadiusHoldline,
        "huntRadiusSprayer": best.huntRadiusSprayer,
        "guardStandoff": best.guardStandoff,
        "wins": bestWins,
        "margin": bestMargin
      },
      "grid": rows
    }
    writeFile(Record, record.pretty() & "\n")
    echo "wrote ", Record

  if not check:
    quit(0)

  var failures = 0
  proc fail(message: string) =
    echo "tune_baselines: FAIL: ", message
    inc failures

  if best != DefaultBaselineParams:
    fail("the sweep's pick is not what baselines.nim ships (" &
      $DefaultBaselineParams & ")")
  if bestWins * 2 <= Seeds.len * 2:
    fail("the pick does not win a majority of the ladder: holdline is " &
      "supposed to beat sprayer")
  if bestMargin <= 0:
    fail("the pick's hill-tick margin over the ladder is not positive")
  if not fileExists(Record):
    fail(Record & " is missing: the harness's recorded pick is the evidence " &
      "that these numbers were tuned rather than guessed")
  else:
    let recorded = parseJson(readFile(Record))
    let chosen = recorded["chosen"]
    if chosen["huntRadiusHoldline"].getInt != best.huntRadiusHoldline or
        chosen["huntRadiusSprayer"].getInt != best.huntRadiusSprayer or
        chosen["guardStandoff"].getInt != best.guardStandoff:
      fail(Record & " records a different config than this sweep picked")
    if recorded["grid"].len != rows.len:
      fail(Record & " records a different grid than this sweep ran")
  if failures > 0:
    quit(1)
  echo "tune_baselines: OK — the shipped defaults are this sweep's pick"
