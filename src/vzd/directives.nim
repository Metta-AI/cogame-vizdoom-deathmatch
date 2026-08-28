## The directive schema: what a commander (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is repaired instead of
## rejected.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in tests/test_control.nim meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser, which is exactly the class of
## bug that makes a replay unreadable to everything except the one viewer that
## happened to be lenient.

import
  std/[json, strutils, unicode],
  sim_types, zones

type
  Intent* = enum
    ## What a marine is being told to do for the next turn. A closed enum: an
    ## unrecognised intent is repaired to `intHunt`, never dropped, so a cog
    ## is never left unactuated. `hunt` is the repair target because it is
    ## always actuatable and always has something to do.
    intHunt = "hunt"
    intHold = "hold"
    intMoveTo = "move_to"
    intFlank = "flank"
    intRetreat = "retreat"
    intRegroup = "regroup"

  CogOrder* = object
    ## One commanded cog's orders for the next turn.
    cogIndex*: int             ## the live cog this order drives.
    id*: string                ## the cog's anonymous alias, e.g. "RED-alpha".
    intent*: Intent
    at*: string                ## the reply's own `at`: a zone id (A1..E3) or a
                               ## contact alias. Empty when it named none.
                               ## <= MaxIntentRunes.
    targetX*, targetY*: int    ## clamped into the map box.
    hasFace*: bool
    faceX*, faceY*: int
    say*: string               ## <= MaxSayRunes, sanitized; becomes a SHOUT.
    unresolved*: bool          ## the reply named an `at` nothing resolves to;
                               ## the order fell back to `to` and the turn
                               ## counts in `ordersRejected`.
    fromReply*: bool           ## a reply entry really named this cog. False
                               ## means the parser filled it in, and the
                               ## caller repairs it from last turn's directive
                               ## (else holdline's) — never from a default.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SquadDirective* = object
    ## One seat's whole order set for one turn.
    note*: string              ## <= MaxNoteRunes; private, echoed back to
                               ## this seat only, next turn.
    radio*: string             ## <= MaxRadioRunes; the TEAM channel, delivered
                               ## to the three teammates' next observation and
                               ## drawn in the spectator feed. Never audible
                               ## in-world — that is what `say` is for.
    orders*: seq[CogOrder]
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc truncateBytes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` BYTES, backing up to a rune boundary.
  ##
  ## This is the cap on the PROVIDER'S REPLY (`MaxReplyBytes`), which the
  ## design note states in bytes: a rune cap of 4096 would admit 16 KiB of
  ## 4-byte code points. Backing up off a continuation byte (`10xxxxxx`) is
  ## what keeps the cut from splitting a code point, so what reaches
  ## `extractJsonObject` is always valid UTF-8.
  if limit <= 0:
    return ""
  if text.len <= limit:
    return text
  var cut = limit
  while cut > 0 and (uint8(text[cut]) and 0b1100_0000'u8) == 0b1000_0000'u8:
    dec cut
  text[0 ..< cut]

proc sanitizeSay*(text: string): string =
  ## A cog's shout: capped at MaxSayRunes on a rune boundary FIRST, then run
  ## through the starter's printable-ASCII shout sanitiser. Doing it in that
  ## order means the rune cut never leaves half a codepoint for the ASCII
  ## filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # paintball CONTROL records as JSON objects and tells them apart from a
    # cog's shout by a leading '{'. A shout that could start with one would
    # make that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The commander's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc sanitizeRadio*(text: string): string =
  ## The team channel, as it reaches the three teammates and the replay.
  ## Newlines collapse to spaces so one record stays one line; the cut lands
  ## on a RUNE boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(
    MaxRadioRunes)

proc parseIntent*(text: string): Intent =
  ## Tolerant: case-insensitive, hyphens and spaces normalised to
  ## underscores. A few natural synonyms a model actually emits are mapped
  ## rather than punished. Anything still unknown becomes `hunt` — the intent
  ## that always has something useful to do.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  for intent in Intent:
    if $intent == key:
      return intent
  case key
  of "attack", "push", "engage", "kill", "chase": intHunt
  of "defend", "guard", "camp", "hold_position", "post": intHold
  of "move", "goto", "go_to", "walk", "advance": intMoveTo
  of "flank_to", "outflank", "around": intFlank
  of "fall_back", "retreat_to", "back_off", "withdraw": intRetreat
  of "group", "rally", "regroup_with_team": intRegroup
  else: intHunt

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readCoord(node: JsonNode): tuple[ok: bool, value: int] =
  ## One target/face coordinate: an int, a float, or a numeric string.
  ## Anything non-finite or unparseable reports `ok = false` so the caller
  ## can apply its own default rather than inventing a position.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else:
    (false, 0)

proc readPoint(
  node: JsonNode, defaultX, defaultY, maxX, maxY: int
): tuple[given: bool, x, y: int] =
  ## A `[x, y]` pair (an object with x/y keys is accepted too), clamped into
  ## the map box. A missing or non-finite pair reports `given = false` and
  ## returns the caller's default.
  result = (false, defaultX, defaultY)
  if node.isNil or node.kind == JNull:
    return
  var
    rx = (ok: false, value: 0)
    ry = (ok: false, value: 0)
  if node.kind == JArray and node.len >= 2:
    rx = readCoord(node[0])
    ry = readCoord(node[1])
  elif node.kind == JObject:
    rx = readCoord(node{"x"})
    ry = readCoord(node{"y"})
  if not rx.ok or not ry.ok:
    return
  result = (
    true,
    clamp(rx.value, 0, max(0, maxX)),
    clamp(ry.value, 0, max(0, maxY))
  )

proc flatOrderNode(payload: JsonNode): JsonNode =
  ## THIS game's reply is FLAT — one marine, one order — but the starter's
  ## `cogs: [...]` array (and its object-keyed form) is still accepted with a
  ## single entry read as the flat order, so a model that copies paintbot's
  ## shape is not punished. Everything else falls through to the payload
  ## itself.
  let node = payload{"cogs"}
  if node.isNil:
    return payload
  if node.kind == JArray:
    for item in node:
      if item.kind == JObject:
        return item
    return payload
  if node.kind == JObject:
    for _, item in node:
      if item.kind == JObject:
        return item
  payload

proc resolveTarget*(
  at: string, aliases: openArray[string], aliasX, aliasY: openArray[int]
): tuple[found: bool, x, y: int] =
  ## `at` resolution, in the design note's order: a published ZONE ID first
  ## (`A1`..`E3`), then a CONTACT ALIAS (`BLUE-delta`) matched
  ## case-insensitively against what this seat can actually see. Anything else
  ## is unresolvable and the caller repairs to `to`.
  let key = at.strip()
  if key.len == 0:
    return (false, 0, 0)
  let zone = zoneCentre(key)
  if zone.found:
    return (true, zone.x, zone.y)
  let wanted = key.toLowerAscii()
  for i, alias in aliases:
    let mine = alias.toLowerAscii()
    if mine == wanted or mine.endsWith(wanted) or wanted.endsWith(mine):
      if i < aliasX.len and i < aliasY.len:
        return (true, aliasX[i], aliasY[i])
  (false, 0, 0)

proc parseSeatDirective*(
  payload: JsonNode,
  cogIndex: int,
  selfId: string,
  aliases: openArray[string],
  aliasX, aliasY: openArray[int],
  defaultX, defaultY, maxX, maxY: int
): SquadDirective =
  ## Turns one parsed reply into a legal order, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * `intent`  unknown -> `hunt`;
  ## * `at`      a zone id or a visible contact alias; it WINS over `to`.
  ##             Unresolvable -> fall back to `to`, flag `unresolved` so the
  ##             caller counts `ordersRejected` and reports `unknown_target`;
  ## * `to`      missing / non-finite -> the caller's default; otherwise
  ##             clamped into the board box;
  ## * `face`    same clamp, absent -> none;
  ## * `say`     truncated to MaxSayRunes on a rune boundary, then the
  ##             starter's printable-ASCII shout filter;
  ## * `radio`   truncated to MaxRadioRunes on a rune boundary;
  ## * `notes`   truncated to MaxNoteRunes on a rune boundary.
  ##
  ## A reply with a valid `say`/`radio` but NO intent is usable: the cog keeps
  ## its standing order and the line is delivered. Raises DirectiveError only
  ## when the payload is not a JSON object at all — that is the one condition
  ## the retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  let node = flatOrderNode(payload)
  result.source = dsLlm
  ## `notes` is the design's name; `note` is the starter's. Accept both.
  var noteText = node{"notes"}.getStr()
  if noteText.len == 0: noteText = payload{"notes"}.getStr()
  if noteText.len == 0: noteText = node{"note"}.getStr()
  if noteText.len == 0: noteText = payload{"note"}.getStr()
  result.note = sanitizeNote(noteText)
  var radioText = node{"radio"}.getStr()
  if radioText.len == 0: radioText = payload{"radio"}.getStr()
  result.radio = sanitizeRadio(radioText)

  var order = CogOrder(
    cogIndex: cogIndex,
    id: selfId,
    intent: intHunt,
    targetX: defaultX,
    targetY: defaultY
  )
  let intentText = node{"intent"}.getStr()
  order.fromReply = intentText.len > 0
  order.intent = parseIntent(intentText)
  let target = readPoint(node{"to"}, defaultX, defaultY, maxX, maxY)
  var placed = target.given
  order.targetX = target.x
  order.targetY = target.y
  ## The starter's key name, still accepted.
  if not placed:
    let legacy = readPoint(node{"target"}, defaultX, defaultY, maxX, maxY)
    if legacy.given:
      placed = true
      order.targetX = legacy.x
      order.targetY = legacy.y
  order.at = node{"at"}.getStr().strip().truncateRunes(MaxIntentRunes)
  if order.at.len > 0:
    let resolved = resolveTarget(order.at, aliases, aliasX, aliasY)
    if resolved.found:
      order.fromReply = true
      placed = true
      order.targetX = clamp(resolved.x, 0, max(0, maxX))
      order.targetY = clamp(resolved.y, 0, max(0, maxY))
    else:
      ## Unresolvable: keep `to` if the reply gave one, else the caller's
      ## default, and tell the caller so the seat's next observation reports
      ## `unknown_target`.
      order.unresolved = true
  if placed:
    order.fromReply = true
  let face = readPoint(node{"face"}, 0, 0, maxX, maxY)
  order.hasFace = face.given
  order.faceX = face.x
  order.faceY = face.y
  var sayText = node{"say"}.getStr()
  if sayText.len == 0: sayText = payload{"say"}.getStr()
  order.say = sanitizeSay(sayText)
  ## `retreat` and `regroup` name no point at all — the driver derives one —
  ## so a reply carrying only one of those is complete.
  if order.intent in {intRetreat, intRegroup} and intentText.len > 0:
    order.fromReply = true
  result.orders = @[order]

proc directiveRecord*(
  directive: SquadDirective,
  game, turn, seat: int,
  team, alias: string,
  view: JsonNode = nil
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED sim fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  let order =
    if directive.orders.len > 0: directive.orders[0] else: CogOrder()
  result = %*{
    "k": "directive",
    "game": game,
    "turn": turn,
    "seat": seat,
    "team": team,
    "alias": alias,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "intent": $order.intent,
    "at": order.at,
    "target": [order.targetX, order.targetY],
    "say": order.say,
    "radio": directive.radio,
    "note": directive.note
  }
  if order.hasFace:
    result["face"] = %[order.faceX, order.faceY]
  else:
    result["face"] = newJNull()
  if not view.isNil and view.kind != JNull:
    result["view"] = view


proc boundedDirectiveRecord*(
  directive: SquadDirective,
  game, turn, seat: int,
  team, alias: string,
  view: JsonNode = nil
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes.
  ##
  ## It shrinks NOTE FIRST, then radio, then the view block, then say — the
  ## order of least to most load-bearing for a spectator — and every cut lands
  ## on a RUNE boundary. Never cut the SERIALIZED string: that would emit
  ## broken JSON, which is the exact failure the rune rule exists to prevent.
  var
    trimmed = directive
    carried = view
  result = $trimmed.directiveRecord(game, turn, seat, team, alias, carried)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 16:
    inc guard
    if trimmed.note.len > 0:
      let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
      trimmed.note = trimmed.note.truncateRunes(keep)
    elif not carried.isNil and carried.kind != JNull:
      carried = nil
    elif trimmed.radio.len > 0:
      let keep = max(0, trimmed.radio.runeLen - max(8, trimmed.radio.runeLen div 2))
      trimmed.radio = trimmed.radio.truncateRunes(keep)
    else:
      for i in 0 ..< trimmed.orders.len:
        trimmed.orders[i].say = trimmed.orders[i].say.truncateRunes(
          max(0, trimmed.orders[i].say.runeLen - 2))
    result = $trimmed.directiveRecord(game, turn, seat, team, alias, carried)
  # The loop always converges: with an empty note, no view, no radio and empty
  # says the record is a couple of hundred runes of fixed structure.
