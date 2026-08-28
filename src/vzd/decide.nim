## The decision layer: the per-turn loop that asks both commanders what their
## squads do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (108 ticks = 4.5 s of sim time), 20
## turns per game, 40 per episode. At each turn the server builds BOTH seats'
## request bodies and issues them as ONE parallel batch — paintball is a
## simultaneous-decision game, so querying seats one after another would
## double the wall clock for no gain. One call per seat per turn covers all of
## that seat's commanded cogs.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `holdline` scripted directive for that turn and a `fallback`
## record names the cause. No failure mode leaves a cog unactuated: the
## control layer always has a directive — this turn's, else last turn's, else
## `holdline`'s.

import
  std/[json, math, monotimes, os, strutils, tables, times],
  curly,
  sim, control, directives, baselines, llm, egoview

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `holdline`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer
    lastResult*: seq[string]   ## per seat: how the driver says the previous
                               ## order went (`moving`, `holding`, `firing`,
                               ## `no_route`, `dead`, `unknown_target`, ...).
    notes*: seq[string]        ## per seat: its own private note, echoed back.
    radio*: seq[string]        ## per COG: its last team-channel line, read by
                               ## its three teammates' next observation.
    mapSent*: seq[bool]        ## per seat: the map has been published once.
    rejected*: seq[int]        ## per seat: replies whose `at` resolved to
                               ## nothing; mirrored into results.ordersRejected.
    requestTicks*: seq[MonoTime]
                               ## a rolling 60 s request log. If issuing the
                               ## next batch would push the trailing minute
                               ## past RateCapPerMin, the seats that would
                               ## exceed it skip the call and take the rusher
                               ## order with cause `rate_guard`. Bounded,
                               ## logged, never a sleep on the critical path.

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  result.lastResult = newSeq[string](sim.seatCount())
  result.notes = newSeq[string](sim.seatCount())
  result.radio = newSeq[string](max(sim.seatCount(), sim.players.len))
  result.mapSent = newSeq[bool](sim.seatCount())
  result.rejected = newSeq[int](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blRusher
    result.seats[i].label = "rusher"
    result.lastResult[i] = "unknown"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc seatViewNode*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerGame: int
): JsonNode =
  ## EVERYTHING this seat may legitimately know, and nothing else.
  ##
  ## The guiding line is "a seat sees what its cog's eyes see, plus what its
  ## team says." There is no free-cam and no map-wide enemy list — the fog IS
  ## the game. Structurally it is ViZDoom's depth buffer plus its labels
  ## buffer: sixteen ray distances across the cone (`rays`) and one labelled
  ## row per thing the cone or the bubble actually contains (`contacts`).
  ##
  ## HIDDEN, deliberately: every other seat's order, notes, radio and prompt;
  ## every seat's real player name, policy name and kind; the ENEMY team's
  ## per-cog frag/death breakdown (only its team total is public); enemy
  ## positions outside this cog's cone, bubble and 72-tick memory; enemy aim
  ## and intent; the seed; the unselected pool entries; and the map's own
  ## `mapSpec` document — a seat gets zones, not wall rectangles.
  let
    cogIndex = seat                 ## one cog per seat: the seat IS the body.
    team = sim.teamForSlot(seat)
    other = if team == Red: Blue else: Red
    played = sim.gameTicksElapsed() div TargetFps
    total = (if sim.config.maxTicks > 0: sim.config.maxTicks div TargetFps
             else: 0)
    memory =
      if cogIndex < sim.players.len: engine.ctl.knownEnemy(sim, cogIndex)
      else: (known: false, x: 0, y: 0, index: -1, ticksAgo: 0)

  var contacts = newJArray()
  for contact in sim.contactsFor(
      cogIndex, memory.x, memory.y,
      (if memory.known: memory.index else: -1),
      (if memory.known: memory.ticksAgo else: 0)):
    contacts.add(contact.contactJson())

  ## Your three teammates: alias, position, hp, alive, zone and their last
  ## radio line. A DOCUMENTED DIVERGENCE from the starter, whose cogs cannot
  ## see their own team — four independent policies on one team, each driving
  ## one body at a 4.5 s cadence, cannot play team deathmatch blind, and the
  ## idea's integrity note requires team DM. Enemies stay fogged exactly as
  ## the starter fogs them.
  var mates = newJArray()
  for i in 0 ..< sim.players.len:
    if i == cogIndex or sim.players[i].team != team:
      continue
    let p = sim.players[i]
    mates.add(%*{
      "id": sim.cogAlias(i),
      "pos": [p.x + CollisionW div 2, p.y + CollisionH div 2],
      "hp": max(0, p.hp),
      "alive": p.alive,
      "zone": zoneAt(p.x + CollisionW div 2, p.y + CollisionH div 2),
      "radio": (if i < engine.radio.len: engine.radio[i] else: "")
    })

  ## The scoreboard is public for TEAM totals; the per-alias breakdown is your
  ## own team's only.
  var mine = newJArray()
  var yours = 0
  var theirs = 0
  for i in 0 ..< sim.players.len:
    let net = sim.netFor(i)
    if sim.players[i].team == team:
      yours += net
      mine.add(%*{
        "id": sim.cogAlias(i),
        "f": sim.players[i].kills,
        "d": sim.players[i].deaths})
    elif sim.players[i].team == other:
      theirs += net

  result = %*{
    "you": sim.cogAlias(cogIndex),
    "team": toUpperAscii(teamText(team)),
    "turn": turnIndex,
    "turns": turnsPerGame,
    "clock": {"played_s": played, "left_s": max(0, total - played)},
    "you_at": sim.selfJson(cogIndex),
    "rays": raysJson(
      sim.marchRays(cogIndex, EgoRayColumns, sim.visionRange())),
    "contacts": contacts,
    "team_net": mates,
    "heard": sim.heardJson(cogIndex),
    "score": {
      "you": yours, "them": theirs, "margin": yours - theirs,
      "your_team": mine
    }
  }
  ## The map is published ONCE, at this seat's first turn: fifteen zones is
  ## a lot of tokens to resend twenty-four times for a board that cannot move.
  if seat >= engine.mapSent.len or not engine.mapSent[seat]:
    result["map"] = sim.mapJson(cogIndex)
  if seat < engine.haveDirective.len and engine.haveDirective[seat] and
      engine.directives[seat].orders.len > 0:
    let last = engine.directives[seat].orders[0]
    result["your_last_order"] = %*{
      "intent": $last.intent,
      "at": last.at,
      "result": (if seat < engine.lastResult.len: engine.lastResult[seat]
                 else: "unknown")
    }
  else:
    result["your_last_order"] = newJNull()
  result["your_notes"] =
    %(if seat < engine.notes.len: engine.notes[seat] else: "")

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerGame: int
): string =
  $engine.seatViewNode(sim, seat, turnIndex, turnsPerGame)


# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(
  game, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "game": game,
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  seat: int, team, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "team": team,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end (design §Record
  ## vocabulary, docs/PROTOCOL.md §The replay). It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc standingDirective(engine: DecisionEngine, seat: int): SquadDirective =
  ## The seat's directive from the previous turn, or an empty one. The
  ## baselines use it to shout only when an intent CHANGES.
  if seat >= 0 and seat < engine.directives.len and
      seat < engine.haveDirective.len and engine.haveDirective[seat]:
    engine.directives[seat]
  else:
    SquadDirective()

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): SquadDirective =
  scriptedDirective(engine.ctl, sim, kind, sim.commandedCogs(seat),
    DefaultBaselineParams, engine.standingDirective(seat))

proc rusherFor*(
  engine: DecisionEngine, sim: SimServer, cogs: seq[int],
  seat = -1
): SquadDirective =
  ## The published `rusher` order for an arbitrary cog set. THE SAME PROC the
  ## `rusher` baseline uses — imported, never duplicated — so the fallback and
  ## the published baseline cannot drift; tests/test_vzd_control.nim asserts
  ## they resolve to the same order for the same world.
  scriptedDirective(engine.ctl, sim, blRusher, cogs,
    DefaultBaselineParams, engine.standingDirective(seat))

proc effectiveSpacingMs*(configured, llmSeats: int): int =
  ## THE NAMED EDIT to the rate floor. The Bedrock sidecar caps 30 requests a
  ## minute PER EPISODE and eight seats in one batch is eight requests, so a
  ## FLAT floor between batch starts is not enough on its own: the floor
  ## actually used is derived from the number of seats being called.
  ##
  ##   effectiveSpacingMs(n) = max(turnSpacingMs, ceil(60000 * n / RateCap))
  ##
  ## so n = 2 gives the configured 5 s (the league shape: two prompt champions
  ## among six scripted fillers) and n = 8 gives 17_143 ms — 24 turns of which
  ## is 411 s, still inside the 660 s engine stop.
  if llmSeats <= 0:
    return max(0, configured)
  max(max(0, configured),
      (60_000 * llmSeats + RateCapPerMin - 1) div RateCapPerMin)

proc repairMissingOrder*(
  engine: DecisionEngine, sim: SimServer, seat: int,
  directive: var SquadDirective
) =
  ## Design §Reply schema: "a reply that names no order at all keeps LAST
  ## turn's order (else `rusher`'s)". A reply with a valid `say`/`radio` but
  ## no intent is USABLE — the cog carries on and the line is delivered — so
  ## repairing to a default here rather than to the standing order would
  ## abandon a held post every time a commander only talked.
  if directive.orders.len == 0:
    directive.orders = engine.rusherFor(sim, sim.commandedCogs(seat), seat).orders
    return
  if directive.orders[0].fromReply:
    return
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    for old in engine.directives[seat].orders:
      if old.cogIndex == directive.orders[0].cogIndex:
        let keptSay = directive.orders[0].say
        directive.orders[0] = old
        directive.orders[0].say = keptSay
        return
  let fallback = engine.rusherFor(sim, sim.commandedCogs(seat), seat)
  if fallback.orders.len > 0:
    let keptSay = directive.orders[0].say
    directive.orders[0] = fallback.orders[0]
    directive.orders[0].say = keptSay

proc visibleAliases(
  sim: SimServer, engine: DecisionEngine, cogIndex: int
): tuple[ids: seq[string], xs, ys: seq[int]] =
  ## Every alias this seat may legitimately resolve an `at` against: the cogs
  ## its contact list actually names. Resolving against an unseen enemy would
  ## hand the seat a map-wide enemy list through the back door.
  let memory =
    if cogIndex < sim.players.len: engine.ctl.knownEnemy(sim, cogIndex)
    else: (known: false, x: 0, y: 0, index: -1, ticksAgo: 0)
  for contact in sim.contactsFor(
      cogIndex, memory.x, memory.y,
      (if memory.known: memory.index else: -1),
      (if memory.known: memory.ticksAgo else: 0)):
    if contact.id.len == 0:
      continue
    ## `contactsFor` reports bearings, not positions; recover the world point
    ## from the alias so `at` resolves to somewhere real.
    for i in 0 ..< sim.players.len:
      if sim.cogAlias(i) == contact.id:
        result.ids.add(contact.id)
        if contact.ticksAgo > 0 and memory.index == i:
          result.xs.add(memory.x)
          result.ys.add(memory.y)
        else:
          result.xs.add(sim.players[i].x + CollisionW div 2)
          result.ys.add(sim.players[i].y + CollisionH div 2)
        break

proc noteRequests(engine: var DecisionEngine, count: int) =
  ## Logs `count` requests into the rolling 60 s window and drops the rows
  ## that have aged out.
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTicks:
    if (now - stamp).inMilliseconds.int < 60_000:
      kept.add(stamp)
  for _ in 0 ..< count:
    kept.add(now)
  engine.requestTicks = kept

proc trailingRequests(engine: DecisionEngine): int =
  let now = getMonoTime()
  for stamp in engine.requestTicks:
    if (now - stamp).inMilliseconds.int < 60_000:
      inc result

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex, turnsPerGame: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's order. Returns the replay
  ## chat records this turn produced. Never raises: every failure path ends in
  ## a legal order.
  ##
  ## This is a SIMULTANEOUS-DECISION game, so every LLM seat's request goes
  ## out in ONE PARALLEL BATCH (`curly.makeRequests`) — eight serial calls
  ## would multiply the episode's wall clock by eight for nothing.
  let
    game = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a daily-token 429 on turn k says nothing
  ## about turn k+1 (the sidecar's window may have rolled), so the flag is
  ## cleared here and only suppresses this turn's retry.
  engine.client.throttled = false
  sim.emitEvent(TurnStart, amount = turnIndex)

  ## Record how the PREVIOUS order actually went, before it is replaced: the
  ## driver's honest report is what lets a seat recover from a race it could
  ## not see.
  for seat in 0 ..< engine.seats.len:
    if seat < engine.haveDirective.len and engine.haveDirective[seat] and
        engine.directives[seat].orders.len > 0:
      engine.lastResult[seat] = engine.ctl.driverResult(
        sim, engine.directives[seat].orders[0],
        engine.directives[seat].orders[0].cogIndex)

  # --- how many seats want a call, and therefore what the rate floor is ----
  var llmSeats = 0
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.client.disabled:
      inc llmSeats
  let spacingMs = effectiveSpacingMs(sim.config.turnSpacingMs, llmSeats)

  # --- budget guard: settle EARLY rather than overrun -----------------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, switch the LLM off for the rest of the episode and finish on the
  # scripted layer (microseconds per turn), so the episode ends
  # complete/full_time instead of deadline.
  #
  # THE NAMED EDIT (design §End conditions, budget guard): the starter
  # compared against `turnBudgetMs` ALONE, which under-counts whenever the
  # rate floor is larger than the turn budget — at eight LLM seats the floor
  # is 17.1 s against a 12 s budget, so the starter's guard would let the
  # episode overrun by 5 s a turn. It compares against the LARGER of the two.
  if not engine.llmOff:
    let turnSeconds =
      (max(sim.config.turnBudgetMs, spacingMs) + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "vizdoom-deathmatch: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var
    open: seq[int]
    rateBlocked: seq[int]
  let headroom = max(0, RateCapPerMin - engine.trailingRequests())
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      if open.len < headroom:
        open.add(seat)
      else:
        ## THE RATE GUARD. Issuing this call would push the trailing 60 s
        ## count past the sidecar's cap, so the seat skips it for this turn
        ## and takes the rusher order. Bounded, logged, and never a sleep on
        ## the critical path.
        rateBlocked.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens (`no_credentials`, `budget_guard`). Recording it is
      # what makes the two countable.
      var directive = engine.rusherFor(sim, sim.commandedCogs(seat), seat)
      directive.source = dsFallback
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(game, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing rusher"))
      sim.emitEvent(Fallback, source = seat, weapon = cause)
      echo "vizdoom-deathmatch llm: seat ", seat,
        " falling back to rusher (", cause, ") on turn ", turnIndex
    else:
      var directive = engine.scriptedFor(
        sim, seat, engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true

  for seat in rateBlocked:
    var directive = engine.rusherFor(sim, sim.commandedCogs(seat), seat)
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    result.add(fallbackRecord(game, turnIndex, seat, 1, "rate_guard",
      "the trailing-minute request cap would be exceeded; playing rusher"))
    sim.emitEvent(Fallback, source = seat, weapon = "rate_guard")
    echo "vizdoom-deathmatch llm: seat ", seat,
      " falling back to rusher (rate_guard) on turn ", turnIndex

  # --- the rate floor -------------------------------------------------------
  # Hold the START of consecutive batches `spacingMs` apart. The cert fixture
  # sets turnSpacingMs to 0 and runs with no key at all, so offline runs pay
  # nothing.
  if open.len > 0 and engine.batchStarted and spacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < spacingMs:
      sleep(min(spacingMs, spacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  ## Build every open seat's observation ONCE, before the batch: it is also
  ## what the replay's `directive` record carries, so the replay explains
  ## every decision.
  var views = initTable[int, JsonNode]()
  for seat in open:
    views[seat] = engine.seatViewNode(sim, seat, turnIndex, turnsPerGame)
    ## The map rides this seat's FIRST prompt and never again. `mapSent`
    ## records that it was SENT, which is what the design note pins ("the map,
    ## once, at its first turn"); marking it on a successful PARSE instead
    ## meant a seat whose reply timed out re-sent fifteen zones on every turn
    ## for the rest of the episode.
    if seat < engine.mapSent.len:
      engine.mapSent[seat] = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = $views[seat]
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    engine.noteRequests(open.len)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — and a config that is not a whole
    # number of seconds is therefore not the deadline it claims to be.
    # sim_config REJECTS a sub-second value, so the floor below is an
    # identity: 8000 -> 8 s, 3000 -> 3 s, worst case 11 s inside the 12 s
    # turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        let
          cogIndex = seat
          seen = visibleAliases(sim, engine, cogIndex)
          self =
            if cogIndex < sim.players.len: sim.players[cogIndex]
            else: Player()
        var directive = parseSeatDirective(
          extractJsonObject(text.truncateBytes(MaxReplyBytes)),
          cogIndex, sim.cogAlias(cogIndex), seen.ids, seen.xs, seen.ys,
          self.x + CollisionW div 2, self.y + CollisionH div 2,
          MapWidth - 1, MapHeight - 1)
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.repairMissingOrder(sim, seat, directive)
        if directive.orders.len > 0 and directive.orders[0].unresolved:
          inc engine.rejected[seat]
          if seat < sim.ordersRejected.len:
            inc sim.ordersRejected[seat]
        engine.directives[seat] = directive
        engine.haveDirective[seat] = true
        engine.notes[seat] = directive.note
        if cogIndex < engine.radio.len:
          engine.radio[cogIndex] = directive.radio
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made the hosted log unreadable.
          cause = "throttled"
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "vizdoom-deathmatch llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land.
      echo "vizdoom-deathmatch llm: provider throttled with no other ",
        "candidate; ", open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays rusher for this turn -----------------------
  for seat in open:
    var directive = engine.rusherFor(sim, sim.commandedCogs(seat), seat)
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(game, turnIndex, seat, 2, cause,
      "seat fell back to the rusher order"))
    sim.emitEvent(Fallback, source = seat, weapon = cause)
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "vizdoom-deathmatch llm: seat ", seat, " falling back to rusher (",
      cause, ") on turn ", turnIndex
