## Scoring: the antisymmetry and the exact zero sum the league ranks on.

import
  std/[algorithm, json, math, os, random, unittest],
  vzd_helpers

suite "scoring":
  test "500 randomised end states are exactly zero-sum":
    var rng = initRand(20260827)
    for _ in 0 ..< 500:
      let margin = rng.rand(-40 .. 40)
      let
        red = gameScorePermille(margin, DecisiveMargin)
        blue = gameScorePermille(-margin, DecisiveMargin)
      check red + blue == 1000
      check red >= 0 and red <= 1000
      check blue >= 0 and blue <= 1000
      check (red.float / 1000.0) >= 0.0
      check (red.float / 1000.0) <= 1.0

  test "the formula is the design note's":
    for margin in -20 .. 20:
      let expected = 500 + clamp(margin * 500 div DecisiveMargin, -500, 500)
      check gameScorePermille(margin, DecisiveMargin) == expected

  test "a 12-frag lead is the maximum win and 0 is a draw":
    check gameScorePermille(12, DecisiveMargin) == 1000
    check gameScorePermille(-12, DecisiveMargin) == 0
    check gameScorePermille(99, DecisiveMargin) == 1000
    check gameScorePermille(0, DecisiveMargin) == 500

  test "a zero margin leaves every win false and every score 0.500":
    let permille = gameScorePermille(0, DecisiveMargin)
    check permille == 500
    check not (permille > 500)
    check permille.float / 1000.0 == 0.5

suite "the results document":
  test "every seat-indexed array is 8 long and the scores sum to 1.0":
    var
      sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 240))
      ctl = initControlState(sim)
    discard sim.scriptedEpisode(ctl, [blRusher, blSentry], 240)
    sim.endReason = ReasonComplete
    sim.endRule = EndRuleFullTime
    let doc = parseJson(sim.playerResultsJson())
    for key in ["names", "aliases", "team", "scores", "win", "frags",
                "teamFrags", "deaths", "net", "damageDealt", "damageTaken",
                "shotsFired", "shotsHit", "medkits", "longestStreak",
                "policyKinds", "llmTurns", "fallbackTurns", "ordersRejected",
                "deadSeats"]:
      check doc.hasKey(key)
      check doc[key].len == Seats
    check doc["teamNet"].len == 2
    check doc["reason"].getStr() == "complete"
    check doc["endRule"].getStr() == "full_time"
    check abs(doc["scores"][0].getFloat() + doc["scores"][1].getFloat() - 1.0) <
      1e-9
    check doc["margin"].getInt() ==
      doc["teamNet"][0].getInt() - doc["teamNet"][1].getInt()
    for seat in 0 ..< Seats:
      check doc["net"][seat].getInt() ==
        doc["frags"][seat].getInt() - doc["teamFrags"][seat].getInt() -
        doc["deaths"][seat].getInt()
      check doc["win"][seat].getBool() ==
        (doc["scores"][seat].getFloat() > 0.5)

  test "the results key set equals the manifest's results_schema key set":
    var
      sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 120))
      ctl = initControlState(sim)
    discard sim.scriptedEpisode(ctl, [blRusher, blSentry], 120)
    let
      doc = parseJson(sim.playerResultsJson())
      manifest = parseJson(readFile(
        currentSourcePath.parentDir.parentDir / "coworld_manifest_template.json"))
      schema = manifest["game"]["results_schema"]["properties"]
    var docKeys, schemaKeys: seq[string]
    for key, _ in doc: docKeys.add(key)
    for key, _ in schema: schemaKeys.add(key)
    docKeys.sort()
    schemaKeys.sort()
    check docKeys == schemaKeys

  test "a fault episode is 0.500 / 0.500 and nobody wins":
    var sim = newDeathmatchSim(deathmatchConfigJson(maxTicks = 120))
    sim.endReason = ReasonFault
    sim.endRule = EndRuleSimFault
    sim.stopDetail = "forced"
    let doc = parseJson(sim.playerResultsJson())
    for seat in 0 ..< Seats:
      check doc["scores"][seat].getFloat() == 0.5
      check not doc["win"][seat].getBool()
    check doc["reason"].getStr() == "fault"
    check doc["endRule"].getStr() == "sim_fault"
    check doc["stopDetail"].getStr() == "forced"
