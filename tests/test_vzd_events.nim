## The derived broadcast event vocabulary is a CLOSED enum, and the appended
## game block may only consume kinds the sim can actually emit. Both halves
## are read out of the shipped sources, so a kind added on one side without
## the other fails the build.

import
  std/[os, sets, strutils, unittest]

const RepoDir = currentSourcePath.parentDir.parentDir

let
  broadcast = readFile(RepoDir / "src" / "vzd" / "broadcast.nim")
  page = readFile(RepoDir / "client" / "replay_broadcast.html")

const Emitted = [
  "phase", "gamestart", "gameover", "kill", "respawn", "hit", "pickup",
  "streak", "lead"]
  ## Everything `stepEvents` can produce in a DEATHMATCH episode. The
  ## paintball/ctf kinds (`hillflip`, `hillhold`, `paint`, `spray`, `tag`,
  ## `heal`, `tagout`, `steal`, `return`, `capture`) are behind a loadout
  ## branch that this game can never take.

const Beats = ["gamestart", "kill", "streak", "lead", "fallback", "gameover"]
  ## And these — and only these — become scrubber markers. At ~30 frags and
  ## ~250 shots an episode, a beat per shot would be an unreadable scrubber.

suite "the emitted set":
  test "every kind this game emits really is emitted by stepEvents":
    for kind in Emitted:
      checkpoint(kind)
      check ("\"k\": \"" & kind & "\"") in broadcast or
        ("\"k\": (if sim.deathmatchLoadout(): \"" & kind & "\"") in broadcast

  test "the deleted mechanics' kinds are all behind a loadout branch":
    ## They still exist in the inherited source (this is a fork, not a
    ## rewrite), but every one of them is unreachable here.
    check "if sim.config.hill:" in broadcast
    check "if sim.config.floorPaint:" in broadcast
    check "not sim.deathmatchLoadout()" in broadcast
    check "elif sim.config.numAgents > 0:" in broadcast

suite "the game block consumes only kinds the sim emits":
  test "every case label in dmEvent is an emitted kind or an ignored one":
    let at = page.find("function dmEvent(e, s, ctx) {")
    check at > 0
    let body = page[at ..< page.find("// ---- the commander lines", at)]
    var consumed = initHashSet[string]()
    var i = 0
    while true:
      let mark = body.find("case '", i)
      if mark < 0:
        break
      let close = body.find("'", mark + 6)
      consumed.incl(body[mark + 6 ..< close])
      i = close + 1
    check consumed.len > 0
    for kind in consumed:
      checkpoint(kind)
      ## Either the sim emits it here, or it is one of the deleted mechanics'
      ## kinds the block explicitly swallows so the inherited switch cannot
      ## draw it.
      check kind in Emitted or kind in [
        "tagout", "hillflip", "hillhold", "paint", "spray", "tag", "heal",
        "steal", "return", "capture"]

suite "beats":
  test "the beat kinds are exactly the six the design note names":
    let at = page.find("VIZDOOM-DEATHMATCH additions")
    let tail = page[at .. ^1]
    var found = initHashSet[string]()
    var i = 0
    while true:
      let mark = tail.find(".beat-marker.", i)
      if mark < 0:
        break
      var j = mark + len(".beat-marker.")
      var kind = ""
      while j < tail.len and (tail[j].isAlphaNumeric()):
        kind.add(tail[j])
        inc j
      if kind.len > 0:
        found.incl(kind)
      i = j
    var expected = initHashSet[string]()
    for kind in Beats:
      expected.incl(kind)
    ## The team suffixes are modifiers on `kill` and `lead`, not kinds.
    found.excl("red")
    found.excl("blue")
    check found == expected

  test "every dmBeat call names one of those six":
    let at = page.find("VIZDOOM-DEATHMATCH additions")
    let tail = page[at .. ^1]
    var i = 0
    var seen = 0
    while true:
      let mark = tail.find("dmBeat(s, ", i)
      if mark < 0:
        break
      let rest = tail[mark ..< min(tail.len, mark + 160)]
      var named = false
      for kind in Beats:
        if ("'" & kind & "'") in rest:
          named = true
      if named:
        inc seen
      i = mark + 10
    check seen >= 6
