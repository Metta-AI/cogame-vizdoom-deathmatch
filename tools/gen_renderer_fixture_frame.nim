## Generates the worst-case broadcast frame the renderer fixture drives.
##
##   nim r --hints:off --path:src tools/gen_renderer_fixture_frame.nim \
##     > tools/ci/renderer_fixture_frame.json
##
## `tools/ci/renderer_fixture.html` loads the SHIPPED
## `dist/static-replay-viewer/index.html` in an iframe, shims only the wasm
## entry, and hands the page this frame — so what it measures is the real
## chrome laying out real strings. The frame comes from `buildStateJson`, the
## same proc the live server and the wasm viewer emit, so it cannot drift into
## a shape the page never sees.
##
## "Worst case" is every string at exactly the cap the server enforces:
## `MaxRadioRunes` (96) of radio on ALL EIGHT seats at once, `MaxSayRunes` (10)
## of shout, `MaxNoteRunes` (160) of private note, the widest alias, a fallback
## row, eight live eyes thumbnails, kills and streaks on every seat, and the
## full-timeline momentum series and beat list. The runes are deliberately WIDE
## (`M` and a 4-byte emoji), because a cap counts runes and a layout spends
## pixels.

import
  std/json,
  vzd/[sim, broadcast, directives]

const
  Seats = 8
  Turns = 10

proc configJson(): string =
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
  for i in 0 ..< Seats:
    ## The widest name a policy can put on a plate, so the scorebug is
    ## measured at its worst too.
    players.add(%*{"name": "vzd-pointman-championship-" & $(i + 1)})
    slots.add(%*{"team": (if i mod 2 == 0: "red" else: "blue")})
    tokens.add(%("t" & $i))
  $(%*{
    "seed": 42,
    "num_agents": Seats,
    "minPlayers": Seats,
    "teams": 2,
    "cogsPerTeam": 1,
    "maxTicks": 1080,
    "maxGames": 1,
    "lives": 60,
    "hitPoints": 3,
    "respawnTicks": 48,
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

proc wideRunes(count: int): string =
  ## `count` runes of the widest text a model can actually send: a 4-byte
  ## emoji every eighth rune, capital M otherwise (the widest Latin glyph).
  for i in 0 ..< count:
    if i mod 8 == 7: result.add("\u{1F480}") else: result.add("M")

when isMainModule:
  var config = defaultGameConfig()
  config.update(configJson())
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for order in 0 ..< Seats:
    let name = "vzd-pointman-championship-" & $(order + 1)
    discard game.addPlayer(name, order, "t" & $order)
    game.seatNames[order] = name
    game.seatPolicyKind[order] = "llm"
  game.startGame()
  game.tickCount = 540

  ## Counters at their busiest: every seat scoring, one seat on an announced
  ## streak, one seat down. `net` and the plates read off these.
  for i in 0 ..< game.players.len:
    game.players[i].kills = 3 + i
    game.players[i].deaths = i
    game.players[i].teamKills = i mod 2
    game.players[i].killsThisLife = if i == 0: 8 else: i mod 3
    game.players[i].bestKillsInLife = if i == 0: 8 else: i mod 3
    game.players[i].damageDealt = 12 + i
    game.players[i].shotsFired = 30 + i
    game.players[i].shotsHit = 10 + i
  game.players[3].alive = false
  game.players[3].respawnTimer = 24

  ## The commander lines: every seat, every turn on screen, each carrying a
  ## FULL-CAP radio line and a full-cap shout. This is the state the CI smoke
  ## replay can never reach, because docker_smoke.sh runs with no API key.
  for turn in Turns - 1 .. Turns:
    for seat in 0 ..< Seats:
      let
        team = teamText(game.teamForSlot(seat))
        alias = game.cogAlias(seat)
      var directive = SquadDirective(
        source: (if seat == 5: dsFallback else: dsLlm),
        latencyMs: 900 + seat,
        note: sanitizeNote(wideRunes(MaxNoteRunes)),
        radio: sanitizeRadio(wideRunes(MaxRadioRunes)),
        orders: @[CogOrder(
          cogIndex: seat,
          id: alias,
          intent: intHunt,
          at: "C2",
          targetX: 617,
          targetY: 330,
          say: sanitizeSay(wideRunes(MaxSayRunes)))])
      game.pushFeedDirective(directive.boundedDirectiveRecord(
        1, turn, seat, team, alias))

  ## The full-timeline chrome the momentum graph and the scrubber draw from.
  var
    lead: seq[seq[int]]
    beats = newJArray()
  for step in 0 .. 12:
    lead.add(@[step * 80, step, 12 - step])
    beats.add(%*{
      "k": (if step mod 3 == 0: "kill" else: "lead"),
      "tick": step * 80,
      "team": (if step mod 2 == 0: "red" else: "blue")})
  beats.add(%*{"k": "gameover", "tick": 1080, "team": "red"})

  echo game.buildStateJson(
    newJArray(),
    playing = true,
    speed = 1.0,
    maxTick = 1080,
    looping = true,
    transportEnabled = true,
    mismatchTick = -1,
    povSlot = 0,
    leadSeries = lead,
    startTick = 1,
    endHoldSeconds = 0,
    includeFpMap = true,
    skipLulls = true,
    fastForwarding = false,
    lullSpans = @[[200, 320]],
    beatEvents = beats)
