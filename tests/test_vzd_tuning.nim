## The shipped baseline tunables ARE the grid harness's pick.
##
## The sweep itself lives in `tools/tune_baselines.nim` and runs 216 real
## episodes, so it is a `ci.yml` step (`--check`) rather than a unit test.
## What this file asserts is the cheap half, on every test run: the four
## constants `baselines.nim` ships equal the ones
## `tools/ci/baseline_tuning.json` records, the record's chosen cell is
## actually in the grid it was chosen from, and the recorded head-to-head
## result is the one the design note asks for. A constant edited without
## re-running the sweep fails here, in seconds, instead of in the sweep.

import
  std/[json, os, strutils, unittest],
  vzd_helpers

const
  RepoDir = currentSourcePath.parentDir.parentDir
  RecordPath = RepoDir / "tools" / "ci" / "baseline_tuning.json"

suite "baseline tuning is the swept pick":
  test "the record exists and is the sweep's own output":
    check fileExists(RecordPath)
    let record = parseJson(readFile(RecordPath))
    check record["harness"].getStr() == "tools/tune_baselines.nim"
    check record["ticks"].getInt() == 1080
    check record["seeds"].len == 3
    check record["episodesPerCell"].getInt() == 6
    check record["grid"].len == 36

  test "the four shipped tunables equal the recorded pick":
    let chosen = parseJson(readFile(RecordPath))["chosen"]
    check chosen["rusherHuntPx"].getInt() == DefaultBaselineParams.rusherHuntPx
    check chosen["sentryHuntPx"].getInt() == DefaultBaselineParams.sentryHuntPx
    check chosen["medPx"].getInt() == DefaultBaselineParams.medPx
    check chosen["postRotation"].getInt() ==
      DefaultBaselineParams.postRotation

  test "the pick is a cell of the grid it was chosen from, and it won it":
    let
      record = parseJson(readFile(RecordPath))
      chosen = record["chosen"]
    var
      found = false
      bestWins = -1
      bestMargin = low(int)
    for cell in record["grid"]:
      if cell["wins"].getInt() > bestWins or
          (cell["wins"].getInt() == bestWins and
           cell["margin"].getInt() > bestMargin):
        bestWins = cell["wins"].getInt()
        bestMargin = cell["margin"].getInt()
      if cell["rusherHuntPx"].getInt() == chosen["rusherHuntPx"].getInt() and
          cell["sentryHuntPx"].getInt() == chosen["sentryHuntPx"].getInt() and
          cell["medPx"].getInt() == chosen["medPx"].getInt() and
          cell["postRotation"].getInt() == chosen["postRotation"].getInt():
        found = true
        check cell["wins"].getInt() == chosen["wins"].getInt()
        check cell["margin"].getInt() == chosen["margin"].getInt()
    check found
    ## No other cell in the record beats it under the sweep's own rule.
    check chosen["wins"].getInt() == bestWins
    check chosen["margin"].getInt() == bestMargin

  test "the recorded head-to-head is the design note's target":
    ## `rusher` beats `sentry` by [+2, +10] frags over the six episodes:
    ## clearly ahead — pressure beats posting — without a walkover.
    let chosen = parseJson(readFile(RecordPath))["chosen"]
    check chosen["wins"].getInt() * 2 > chosen["episodes"].getInt()
    check chosen["margin"].getInt() >= 2
    check chosen["margin"].getInt() <= 10

  test "the harness sweeps all four tunables and compiles against src/vzd":
    let harness = readFile(RepoDir / "tools" / "tune_baselines.nim")
    ## It is THIS game's harness, not the starter's: the starter's swept
    ## `holdline`/`sprayer` over `ctf/[sim, control, directives, baselines]`,
    ## which is not even a module path here.
    check "vzd/[sim, control, directives, baselines]" in harness
    check "holdline" notin harness
    check "sprayer" notin harness
    for knob in ["RusherHuntRadii", "SentryHuntRadii", "MedRadii",
                 "PostRotations"]:
      checkpoint(knob)
      check knob in harness
