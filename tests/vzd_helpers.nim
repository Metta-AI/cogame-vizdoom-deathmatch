## Shared fixtures for the deathmatch suite.
##
## Every test builds its sim through `newDeathmatchSim` so one place owns the
## "what a shipped config looks like" knowledge, and so a config field that
## grows a validation rule breaks one line rather than fourteen files.

import
  std/[json, strutils],
  bitworld/spriteprotocol,
  vzd/[sim, control, directives, baselines, llm, decide, egoview, zones,
       deathmatch]

export sim, control, directives, baselines, llm, decide, egoview, zones,
  deathmatch, spriteprotocol

const Seats* = 8

proc deathmatchConfigJson*(
  maxTicks = 1080,
  mapPath = "arena",
  seed = 42,
  turnTicks = 108
): string =
  ## The config every fixture starts from, and it is the SHIPPED shape: eight
  ## seats, one cog each, slots alternating red/blue so slot parity is the
  ## team, on the hand-tuned arena.
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
    "closedRoster": true,
    "teams": 2,
    "cogsPerTeam": 1,
    "maxTicks": maxTicks,
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
    "mapPath": mapPath,
    "turnTicks": turnTicks,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 4,
    "lobbyJoinTimeoutTicks": 0,
    "wallClockBudgetSeconds": 240,
    "fastMode": true,
    "showPlayerLabels": false,
    "tokens": tokens,
    "players": players,
    "slots": slots
  })

proc cogAliasFor*(sim: SimServer, order: int): string =
  toUpperAscii(teamText(sim.teamForSlot(order))) & "-" &
    IdentityNames[sim.slotIdentityIndex(order)]

proc newDeathmatchSim*(configJson: string): SimServer =
  ## A sim with all eight seats taken and the game started, exactly as the
  ## server builds it.
  var config = defaultGameConfig()
  config.update(configJson)
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for order in 0 ..< Seats:
    discard result.addPlayer("policy" & $order, order, "t" & $order)
    result.seatNames[order] = "policy" & $order
  result.startGame()

proc newDeathmatchSim*(): SimServer =
  newDeathmatchSim(deathmatchConfigJson())

proc placeCog*(sim: var SimServer, index, x, y, aim: int) =
  ## Pins one cog with its motion state zeroed, centred on a map point.
  sim.players[index].x = x - CollisionW div 2
  sim.players[index].y = y - CollisionH div 2
  sim.players[index].velX = 0
  sim.players[index].velY = 0
  sim.players[index].aimBrads = aim
  sim.players[index].alive = true
  sim.players[index].respawnTimer = 0

proc none*(sim: SimServer): seq[InputState] =
  newSeq[InputState](sim.players.len)

proc scriptedEpisode*(
  sim: var SimServer, ctl: var ControlState, kinds: openArray[Baseline],
  ticks: int
): int =
  ## A scripted-vs-scripted run: each seat re-issues its baseline's order on
  ## the real turn cadence and the control layer compiles it every tick,
  ## exactly as the server does. Returns the number of ticks actually stepped.
  var
    prev = newSeq[InputState](sim.players.len)
    orders = newSeq[SquadDirective](sim.seatCount())
  for tick in 0 ..< ticks:
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
    result = tick + 1

proc alternating*(a, b: Baseline): array[2, Baseline] = [a, b]
