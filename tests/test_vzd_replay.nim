## The replay contract: the magic, the game name, and the strict-UTF-8
## property every recorded string has to keep.
##
## The record-then-re-derive proof is the hash chain, and it is asserted two
## ways: `tests/test_vzd_engine.nim` re-runs the episode in process and
## compares `gameHash` at every tick, and CI's `docker-smoke` job writes a real
## `.replay` from the production binary which the `wasm-viewer` job then
## re-simulates in a browser, where `checkReplayHash` compares the same chain
## against the recorded one.

import
  std/[json, os, strutils, unicode, unittest],
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
    check echoed.hasKey("mapSpec")
    check echoed["mapSpec"].getStr().len > 0
    ## The token array in the replay echo is the SLOT tokens the sim was
    ## handed; it is never a manifest field (config_schema requires the runner
    ## to inject them, and no game_config carries a literal one).
    check echoed.hasKey("tokens")
