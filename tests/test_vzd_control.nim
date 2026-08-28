## The scripted baselines and the driver: bounded, legal orders, a legal mask
## every tick, and a trigger that cannot cause friendly fire.

import
  std/[json, math, random, unicode, unittest],
  vzd_helpers

const LegalIntents = [intHunt, intHold, intMoveTo, intFlank, intRetreat,
                      intRegroup]

proc atIsLegal(sim: SimServer, at: string): bool =
  ## An `at` is legal when it is a published zone id or a live cog alias.
  if at.len == 0:
    return true
  if parseZoneId(at) >= 0:
    return true
  for i in 0 ..< sim.players.len:
    if sim.cogAlias(i) == at:
      return true
  false

suite "baselines are bounded":
  test "200 pseudo-random worlds, both baselines, every order legal":
    var rng = initRand(4242)
    for mapPath in ["arena", "pool"]:
      var
        sim = newDeathmatchSim(deathmatchConfigJson(mapPath = mapPath))
        ctl = initControlState(sim)
      for round in 0 ..< 100:
        for i in 0 ..< sim.players.len:
          sim.placeCog(i, rng.rand(8 .. MapWidth - 8),
                       rng.rand(8 .. MapHeight - 8), rng.rand(0 .. 255))
          sim.players[i].hp = rng.rand(1 .. 3)
          sim.players[i].alive = rng.rand(0 .. 4) > 0
          sim.players[i].fireCooldown = rng.rand(0 .. 12)
        for k in 0 ..< sim.medKitSpawns.len:
          sim.medKitSpawns[k].present = rng.rand(0 .. 1) == 1
        ctl.observeEnemies(sim)
        for kind in [blRusher, blSentry]:
          for seat in 0 ..< sim.seatCount():
            let directive = scriptedDirective(
              ctl, sim, kind, sim.commandedCogs(seat))
            check directive.radio.len == 0
            check directive.note.len == 0
            check directive.orders.len == 1
            let order = directive.orders[0]
            check order.intent in LegalIntents
            check order.at.runeLen <= MaxIntentRunes
            check sim.atIsLegal(order.at)
            check order.targetX >= 0 and order.targetX < MapWidth
            check order.targetY >= 0 and order.targetY < MapHeight
            check order.say.runeLen <= MaxSayRunes
            let record = directive.boundedDirectiveRecord(
              1, round, seat, teamText(sim.teamForSlot(seat)),
              sim.cogAlias(seat))
            check record.runeLen <= MaxDirectiveRunes

suite "the driver never emits an illegal mask":
  test "only the d-pad, A, B and Select; never C; never both axes":
    var rng = initRand(909)
    var
      sim = newDeathmatchSim()
      ctl = initControlState(sim)
    let legal = ButtonUp or ButtonDown or ButtonLeft or ButtonRight or
      ButtonA or ButtonB or ButtonSelect
    for round in 0 ..< 200:
      for i in 0 ..< sim.players.len:
        sim.placeCog(i, rng.rand(8 .. MapWidth - 8),
                     rng.rand(8 .. MapHeight - 8), rng.rand(0 .. 255))
        sim.players[i].alive = rng.rand(0 .. 3) > 0
      ctl.observeEnemies(sim)
      for kind in [blRusher, blSentry]:
        for cogIndex in 0 ..< sim.players.len:
          let directive = scriptedDirective(ctl, sim, kind, @[cogIndex])
          check directive.orders.len == 1
          let mask = ctl.compileMask(sim, directive.orders[0], cogIndex)
          check (mask and not legal.uint8) == 0'u8
          check (mask and ButtonC) == 0'u8
          check not ((mask and ButtonUp) != 0 and (mask and ButtonDown) != 0)
          check not ((mask and ButtonLeft) != 0 and (mask and ButtonRight) != 0)
          if not sim.players[cogIndex].alive:
            check mask == 0'u8

  test "an out-of-board target degrades, it never wedges":
    var
      sim = newDeathmatchSim()
      ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    var order = CogOrder(
      cogIndex: 0, id: sim.cogAlias(0), intent: intMoveTo,
      targetX: MapWidth - 1, targetY: MapHeight - 1)
    let mask = ctl.compileMask(sim, order, 0)
    check (mask and ButtonC) == 0'u8
    ## And the driver still reports honestly.
    check ctl.driverResult(sim, order, 0) in
      ["moving", "arrived", "holding", "chasing", "firing", "no_route",
       "dead", "unknown_target"]

suite "the trigger never causes friendly fire":
  test "A only fires at a live, visible, in-range enemy with a clear corridor":
    var rng = initRand(77)
    var
      sim = newDeathmatchSim()
      ctl = initControlState(sim)
    for _ in 0 ..< 500:
      for i in 0 ..< sim.players.len:
        sim.placeCog(i, rng.rand(40 .. MapWidth - 40),
                     rng.rand(40 .. MapHeight - 40), rng.rand(0 .. 255))
        sim.players[i].hp = 3
        sim.players[i].fireCooldown = 0
        sim.players[i].fireWindup = 0
      ctl.observeEnemies(sim)
      for cogIndex in 0 ..< sim.players.len:
        let directive = scriptedDirective(ctl, sim, blRusher, @[cogIndex])
        let mask = ctl.compileMask(sim, directive.orders[0], cogIndex)
        if (mask and ButtonA) == 0'u8:
          continue
        let enemy = ctl.knownEnemy(sim, cogIndex)
        ## Never at nothing, and NEVER at a memory.
        check enemy.known
        check enemy.ticksAgo == 0
        check enemy.index >= 0
        check sim.players[enemy.index].alive
        check sim.players[enemy.index].team != sim.players[cogIndex].team
        let
          px = sim.players[cogIndex].x + CollisionW div 2
          py = sim.players[cogIndex].y + CollisionH div 2
        check distSq(px, py, enemy.x, enemy.y) <=
          sim.config.gunRange * sim.config.gunRange
        check sim.lineOfSightClear(px, py, enemy.x, enemy.y)
        check not sim.teammateInCorridor(cogIndex, enemy.x, enemy.y)

suite "the fallback IS the rusher proc":
  test "the decision engine's fallback and the baseline agree exactly":
    var
      sim = newDeathmatchSim()
      engine = initDecisionEngine(sim)
    engine.ctl.observeEnemies(sim)
    for seat in 0 ..< sim.seatCount():
      let
        fallback = engine.rusherFor(sim, sim.commandedCogs(seat))
        baseline = scriptedDirective(
          engine.ctl, sim, blRusher, sim.commandedCogs(seat))
      check fallback.orders.len == baseline.orders.len
      for i in 0 ..< fallback.orders.len:
        check fallback.orders[i].intent == baseline.orders[i].intent
        check fallback.orders[i].targetX == baseline.orders[i].targetX
        check fallback.orders[i].targetY == baseline.orders[i].targetY

  test "an unrecognised PLAYER_SCRIPTED value is rusher, not sentry":
    check parseBaseline("") == blRusher
    check parseBaseline("nonsense") == blRusher
    check parseBaseline("RUSHER") == blRusher
    check parseBaseline(" sentry ") == blSentry

suite "reply validation":
  setup:
    var sim = newDeathmatchSim()
    let aliases = @[sim.cogAlias(1)]
    let xs = @[600]
    let ys = @[300]

  test "the schema is accepted and `at` wins over `to`":
    let directive = parseSeatDirective(
      extractJsonObject("""{"intent":"hold","at":"C2","to":[10,10],
        "face":[700,330],"say":"mid","radio":"north door","notes":"stay"}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.orders.len == 1
    check directive.orders[0].intent == intHold
    check directive.orders[0].at == "C2"
    let centre = zoneCentre("C2")
    check centre.found
    check directive.orders[0].targetX == centre.x
    check directive.orders[0].targetY == centre.y
    check directive.orders[0].hasFace
    check directive.orders[0].say == "mid"
    check directive.radio == "north door"
    check directive.note == "stay"
    check not directive.orders[0].unresolved

  test "an unknown intent is repaired to hunt, never dropped":
    let directive = parseSeatDirective(
      extractJsonObject("""{"intent":"nuke-them","to":[300,300]}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.orders[0].intent == intHunt

  test "an unresolvable `at` falls back to `to` and is flagged":
    let directive = parseSeatDirective(
      extractJsonObject("""{"intent":"hunt","at":"Z9","to":[300,300]}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.orders[0].unresolved
    check directive.orders[0].targetX == 300
    check directive.orders[0].targetY == 300

  test "`to` is clamped into the board box":
    let directive = parseSeatDirective(
      extractJsonObject("""{"intent":"move_to","to":[99999,-40]}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.orders[0].targetX == MapWidth - 1
    check directive.orders[0].targetY == 0

  test "a contact alias resolves to that contact's last known position":
    let directive = parseSeatDirective(
      extractJsonObject("""{"intent":"hunt","at":"""" & sim.cogAlias(1) &
        """"}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.orders[0].targetX == 600
    check directive.orders[0].targetY == 300
    check not directive.orders[0].unresolved

  test "a say-only reply is USABLE: the cog keeps its standing order":
    let directive = parseSeatDirective(
      extractJsonObject("""{"say":"mid","radio":"pushing"}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 40, 50, MapWidth - 1, MapHeight - 1)
    check directive.orders.len == 1
    check not directive.orders[0].fromReply     ## the caller repairs it
    check directive.orders[0].say == "mid"
    check directive.radio == "pushing"

  test "the starter's cogs:[...] single-entry form is still accepted":
    let directive = parseSeatDirective(
      extractJsonObject(
        """{"cogs":[{"id":"RED-alpha","intent":"flank","at":"D1"}]}"""),
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.orders[0].intent == intFlank
    check directive.orders[0].at == "D1"

  test "a non-object is a parse failure, which is what the retry is for":
    expect DirectiveError:
      discard parseSeatDirective(
        newJArray(), 0, "RED-alpha", aliases, xs, ys, 1, 1, 100, 100)
    expect DirectiveError:
      discard parseSeatDirective(
        extractJsonObject("nothing here at all"), 0, "RED-alpha",
        aliases, xs, ys, 1, 1, 100, 100)

  test "say / radio / notes truncate on RUNE boundaries with 4-byte emoji":
    ## A 4-byte emoji sitting exactly on every cap: byte truncation would cut
    ## one in half and the replay would fail a strict UTF-8 parser.
    let emoji = "\u{1F480}"                     ## U+1F480, four UTF-8 bytes
    var
      longSay = ""
      longRadio = ""
      longNote = ""
    for _ in 0 ..< MaxSayRunes + 5: longSay.add(emoji)
    for _ in 0 ..< MaxRadioRunes + 5: longRadio.add(emoji)
    for _ in 0 ..< MaxNoteRunes + 5: longNote.add(emoji)
    check longSay.truncateRunes(MaxSayRunes).runeLen == MaxSayRunes
    check longRadio.truncateRunes(MaxRadioRunes).runeLen == MaxRadioRunes
    check longNote.truncateRunes(MaxNoteRunes).runeLen == MaxNoteRunes
    check validateUtf8(longSay.truncateRunes(MaxSayRunes)) == -1
    check validateUtf8(longRadio.truncateRunes(MaxRadioRunes)) == -1
    check validateUtf8(longNote.truncateRunes(MaxNoteRunes)) == -1
    let directive = parseSeatDirective(
      %*{"intent": "hold", "say": longSay, "radio": longRadio,
         "notes": longNote},
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    check directive.radio.runeLen <= MaxRadioRunes
    check directive.note.runeLen <= MaxNoteRunes
    check directive.orders[0].say.runeLen <= MaxSayRunes
    check validateUtf8(directive.radio) == -1
    check validateUtf8(directive.note) == -1

  test "the provider's reply is capped in BYTES, on a rune boundary":
    ## design.md's table says "whole reply | BYTES | <= 4096 read from the
    ## provider before parsing". A RUNE cap of 4096 would admit 16 KiB of
    ## 4-byte code points, so the cut is by byte and then backed up off any
    ## continuation byte.
    let emoji = "\u{1F480}"                     ## four UTF-8 bytes each
    var huge = ""
    for _ in 0 ..< MaxReplyBytes: huge.add(emoji)
    check huge.len == MaxReplyBytes * 4
    let capped = huge.truncateBytes(MaxReplyBytes)
    check capped.len <= MaxReplyBytes
    check capped.len > MaxReplyBytes - 4       ## and it does not under-cut
    check validateUtf8(capped) == -1           ## never half a code point
    check capped.runeLen == MaxReplyBytes div 4
    ## An ASCII reply inside the cap is passed through untouched, so the
    ## parser sees exactly what the model sent.
    let small = "{\"intent\": \"hunt\", \"at\": \"C2\"}"
    check small.truncateBytes(MaxReplyBytes) == small

  test "the whole directive record stays inside MaxDirectiveRunes":
    var padding = ""
    for _ in 0 ..< 400: padding.add("\u{1F480}")
    var directive = parseSeatDirective(
      %*{"intent": "hunt", "at": "C2", "radio": padding, "notes": padding},
      0, sim.cogAlias(0), aliases, xs, ys, 1, 1, MapWidth - 1, MapHeight - 1)
    let record = directive.boundedDirectiveRecord(
      1, 3, 0, "red", sim.cogAlias(0), %*{"you": "RED-alpha"})
    check record.runeLen <= MaxDirectiveRunes
    check validateUtf8(record) == -1
    discard parseJson(record)                   ## and it is still valid JSON

suite "the rusher shouts on the change, not every turn":
  test "\"on it\" is emitted once, on the turn the intent becomes hunt":
    ## design.md's baseline table: `say` = "on it" ON THE TURN THE INTENT
    ## CHANGES to `hunt`. Emitting it every hunting turn filled the replay's
    ## directive records with 21 identical shouts in the certification
    ## episode.
    var sim = newDeathmatchSim()
    var ctl = initControlState(sim)
    sim.placeCog(0, MapWidth div 2, MapHeight div 2, 0)
    sim.placeCog(1, MapWidth div 2 + 60, MapHeight div 2, 0)
    ctl.observeEnemies(sim)
    let first = scriptedDirective(ctl, sim, blRusher, @[0])
    check first.orders[0].intent == intHunt
    check first.orders[0].say == "on it"
    ## Same world, but the cog was ALREADY hunting: it says nothing.
    let again = scriptedDirective(
      ctl, sim, blRusher, @[0], DefaultBaselineParams, first)
    check again.orders[0].intent == intHunt
    check again.orders[0].say == ""
    ## A cog that was holding and now hunts shouts again.
    var held = SquadDirective(orders: @[CogOrder(
      cogIndex: 0, intent: intHold)])
    let resumed = scriptedDirective(
      ctl, sim, blRusher, @[0], DefaultBaselineParams, held)
    check resumed.orders[0].say == "on it"

suite "the derived rate floor and the budget guard":
  test "effectiveSpacingMs is 5000 at 2 seats and 17143 at 8":
    check effectiveSpacingMs(5000, 0) == 5000
    check effectiveSpacingMs(5000, 1) == 5000
    check effectiveSpacingMs(5000, 2) == 5000
    check effectiveSpacingMs(5000, 8) == 17_143
    check effectiveSpacingMs(0, 8) == 17_143
    ## 24 turns at the worst-case floor still fits inside the engine stop.
    check 24 * effectiveSpacingMs(5000, 8) div 1000 + 134 <= 660

  test "the guard compares against the LARGER of the budget and the floor":
    ## The named edit: the starter compared against turnBudgetMs alone, which
    ## under-counts whenever the rate floor is bigger.
    check effectiveSpacingMs(5000, 8) > 12_000
    check max(12_000, effectiveSpacingMs(5000, 8)) == 17_143
