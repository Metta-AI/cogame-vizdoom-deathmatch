## The baseline parameter grid harness.
##
## `rusher` and `sentry` have exactly four tunables (`BaselineParams`), and the
## design note asks for the first to BEAT the second — that ordering is what
## gives a ladder of scripted fillers a spread instead of a coin flip, and it
## is why the degraded (no-API-key) episode is still a legible deathmatch.
## This tool is where those four numbers come from. It plays the 4v4
## head-to-head over a BOUNDED matrix of them, each cell as a small ladder
## (three seeds, each played BOTH WAYS so a side bias on a mirror-symmetric
## arena cannot be mistaken for a policy edge), prints one row per cell, and
## names the cell that wins the most episodes (team frag margin breaks ties).
##
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim --write
##
## With `--check` (how ci.yml runs it, in the `test` job) it re-runs the sweep
## and asserts that its pick is still what `DefaultBaselineParams` ships and
## what `tools/ci/baseline_tuning.json` records, exiting non-zero when it is
## not. A guessed constant drifts silently; a harness in CI does not.
##
## Cost: 16 cells x 3 seeds x 2 sides = 96 episodes of `Ticks` ticks with
## eight cogs on the real turn cadence, through the real control layer.

import
  std/[json, os, strformat, strutils],
  bitworld/spriteprotocol,
  vzd/[sim, control, directives, baselines]

const
  Ticks* = 1080
    ## Per episode. Long enough for four full turns of orders and for the
    ## contested-zone rule to pull `rusher` into contact; short enough that
    ## the whole grid is minutes, not hours. The pick's ordering is the same
    ## at 1080 (the shipped length) — the margin simply scales.
  Seats = 8
  Record = "tools/ci/baseline_tuning.json"
  Seeds* = [42, 7, 4711]
    ## The ladder. Exported so a test can measure the shipped ordering with
    ## THIS driver on THESE seeds — one implementation, so a test can never
    ## disagree with the sweep that chose the numbers.

  ## The matrix: 3 x 3 x 2 x 2 = 36 cells, every one of them six real
  ## episodes. Deliberately bounded — the point is a defensible, reproducible
  ## choice, not a search of the whole space. The note's own first guesses
  ## (520 px hunt, postRotation 2) are IN the table, so the rows they lost
  ## are on the record.
  RusherHuntRadii = [120, 200, 360]
  SentryHuntRadii = [100, 180, 260]
  MedRadii = [240, 360]
  PostRotations = [1, 2]

proc configJson(seed: int): string =
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
  for i in 0 ..< Seats:
    players.add(%*{"name": "Cog" & $(i + 1)})
    slots.add(%*{"team": (if i mod 2 == 0: "red" else: "blue")})
    tokens.add(%("t" & $i))
  $(%*{
    "seed": seed,
    "num_agents": Seats,
    "minPlayers": Seats,
    "teams": 2,
    "cogsPerTeam": 1,
    "maxTicks": Ticks,
    "maxGames": 1,
    "lives": 60,
    "hitPoints": 3,
    "respawnTicks": 48,
    "gunRange": 1050,
    "fireCooldownTicks": 12,
    "fireWindupTicks": 5,
    "aimTurnRate": 5,
    "visionConeDeg": 45,
    "visionBubble": 90,
    "mapPath": "arena",
    "turnTicks": 108,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 4,
    "lobbyJoinTimeoutTicks": 0,
    "fastMode": true,
    "showPlayerLabels": false,
    "tokens": tokens,
    "players": players,
    "slots": slots
  })

proc newSim(seed: int): SimServer =
  var config = defaultGameConfig()
  config.update(configJson(seed))
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for order in 0 ..< Seats:
    discard result.addPlayer("Cog" & $(order + 1), order, "t" & $order)
  result.startGame()

proc playEpisode*(
  seed: int, params: BaselineParams, rusherOnBlue: bool
): tuple[rusher, sentry, kills: int] =
  ## One 4v4 head-to-head through the REAL control layer on the real 108-tick
  ## turn cadence — the same path the server takes. `rusherOnBlue` swaps the
  ## sides, so each cell is measured from both halves of a mirror-symmetric
  ## arena.
  var
    sim = newSim(seed)
    ctl = initControlState(sim)
    directives = newSeq[SquadDirective](sim.seatCount())
    prev = newSeq[InputState](sim.players.len)
  for tick in 0 ..< Ticks:
    if sim.phase != Playing:
      break
    ctl.observeEnemies(sim)
    if sim.gameTicksElapsed() mod max(1, sim.config.turnTicks) == 0:
      for seat in 0 ..< sim.seatCount():
        let kind =
          if (sim.teamForSlot(seat) == Red) xor rusherOnBlue: blRusher
          else: blSentry
        directives[seat] = scriptedDirective(
          ctl, sim, kind, sim.commandedCogs(seat), params)
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
  let
    rusherTeam = if rusherOnBlue: Blue else: Red
    sentryTeam = if rusherOnBlue: Red else: Blue
  result.rusher = sim.teamNet(rusherTeam)
  result.sentry = sim.teamNet(sentryTeam)
  for player in sim.players:
    result.kills += player.kills

when isMainModule:
  let
    check = "--check" in commandLineParams()
    write = "--write" in commandLineParams()
  var
    best = DefaultBaselineParams
    bestWins = -1
    bestMargin = low(int)
    rows = newJArray()
  echo "baseline grid harness: rusher vs sentry, ", Ticks,
    " ticks, seeds ", Seeds, ", each seed played from both sides"
  echo "  rusherHuntPx  sentryHuntPx  medPx  postRotation |  wins  margin " &
    " kills | per-episode rusher:sentry"
  for rusherHuntPx in RusherHuntRadii:
    for sentryHuntPx in SentryHuntRadii:
      for medPx in MedRadii:
        for postRotation in PostRotations:
          let params = BaselineParams(
            rusherHuntPx: rusherHuntPx,
            sentryHuntPx: sentryHuntPx,
            medPx: medPx,
            postRotation: postRotation)
          var
            wins = 0
            margin = 0
            kills = 0
            detail = ""
          for seed in Seeds:
            for rusherOnBlue in [false, true]:
              let outcome = playEpisode(seed, params, rusherOnBlue)
              if outcome.rusher > outcome.sentry:
                inc wins
              margin += outcome.rusher - outcome.sentry
              kills += outcome.kills
              detail.add &" {outcome.rusher}:{outcome.sentry}"
          echo &"  {rusherHuntPx:>12}  {sentryHuntPx:>12}  {medPx:>5} " &
            &" {postRotation:>12} | {wins:>2}/6 {margin:>7} {kills:>6} |" &
            detail
          rows.add(%*{
            "rusherHuntPx": rusherHuntPx,
            "sentryHuntPx": sentryHuntPx,
            "medPx": medPx,
            "postRotation": postRotation,
            "wins": wins,
            "episodes": Seeds.len * 2,
            "margin": margin,
            "kills": kills
          })
          if wins > bestWins or (wins == bestWins and margin > bestMargin):
            bestWins = wins
            bestMargin = margin
            best = params
  echo "sweep pick: rusherHuntPx=", best.rusherHuntPx,
    " sentryHuntPx=", best.sentryHuntPx,
    " medPx=", best.medPx,
    " postRotation=", best.postRotation,
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
      "note": "each cell is one rusher-vs-sentry 4v4 episode per seed from " &
        "both sides; the pick wins the most episodes, team frag margin " &
        "breaks ties. The target is the design note's: rusher ahead by " &
        "[+2, +10] frags over the six episodes.",
      "chosen": {
        "rusherHuntPx": best.rusherHuntPx,
        "sentryHuntPx": best.sentryHuntPx,
        "medPx": best.medPx,
        "postRotation": best.postRotation,
        "wins": bestWins,
        "episodes": Seeds.len * 2,
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
    fail("the pick does not win a majority of the ladder: rusher is " &
      "supposed to beat sentry")
  if bestMargin <= 0:
    fail("the pick's team frag margin over the ladder is not positive")
  if not fileExists(Record):
    fail(Record & " is missing: the harness's recorded pick is the evidence " &
      "that these numbers were tuned rather than guessed")
  else:
    let recorded = parseJson(readFile(Record))
    let chosen = recorded["chosen"]
    if chosen["rusherHuntPx"].getInt != best.rusherHuntPx or
        chosen["sentryHuntPx"].getInt != best.sentryHuntPx or
        chosen["medPx"].getInt != best.medPx or
        chosen["postRotation"].getInt != best.postRotation:
      fail(Record & " records a different config than this sweep picked")
    if recorded["grid"].len != rows.len:
      fail(Record & " records a different grid than this sweep ran")
  if failures > 0:
    quit(1)
  echo "tune_baselines: OK — the shipped defaults are this sweep's pick"
