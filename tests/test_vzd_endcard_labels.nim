## Endcard and chrome label re-mapping.
##
## A forked ctf/paintbot endcard silently ships the wrong vocabulary, and
## nothing in the sim tests, in viewer_smoke.mjs or in the wire contract covers
## spectator chrome STRINGS. The re-mappings the design note enumerates are
## therefore enforced here, one assertion each.

import
  std/[os, strutils, unittest]

const RepoDir = currentSourcePath.parentDir.parentDir

let page = readFile(RepoDir / "client" / "replay_broadcast.html")

proc occurrences(text, needle: string): int =
  var i = 0
  while true:
    let at = text.find(needle, i)
    if at < 0:
      return
    inc result
    i = at + needle.len

suite "the re-mapped strings are present, exactly once":
  test "the endcard's stat header is the deathmatch one":
    check occurrences(page,
      "<div class=\"ec-thead\"><span>Cog</span><span>Frags</span>" &
      "<span>Deaths</span><span>Net</span><span>Acc</span></div>") == 1

  test "the per-team endcard caption reads Net frags":
    check occurrences(page, "<span class=\"fl-cap\">Net frags</span>") == 1

  test "the momentum graph is labelled FRAG LEAD":
    check occurrences(page,
      "<span class=\"momentum-label\">FRAG LEAD</span>") == 1

  test "the plate label is Frags, on both plate shapes":
    check occurrences(page, "frag-label") >= 2

  test "the locker room loads a map, not a paint hopper":
    check occurrences(page,
      "<div class=\"lk-cap\" id=\"lk-cap\" aria-hidden=\"true\">" &
      "Loading the map&hellip;</div>") == 1
    check occurrences(page, "'Loading the map…',") == 1

  test "the clock caption calls the marines to the deck":
    check occurrences(page,
      "<div class=\"caption\" id=\"clock-caption\">" &
      "Marines to the deck</div>") == 1

  test "the mismatch warning names the tick":
    check occurrences(page,
      "Replay hash mismatch at tick N — showing recorded inputs") == 1

  test "the spoilers title names frags, streaks and lead changes":
    check occurrences(page,
      "Spoilers: frags / streaks / lead changes on the timeline ahead of " &
      "the playhead (o)") == 1

suite "the replaced vocabulary is gone from the places it was replaced":
  test "no endcard column ever says Clstr, Cap or Tags again":
    check "<span>Clstr</span>" notin page
    check "<span>Cap</span>" notin page
    check "<span>Tags</span>" notin page
    check "<span>Out</span>" notin page
    check "<span>Paint</span>" notin page

  test "no scorebug or endcard caption still says Lives or Hill time":
    check "<span class=\"fl-cap\">Lives left</span>" notin page
    check "<span class=\"fl-cap\">Hill time</span>" notin page
    check "<span class=\"lives-label\">Lives</span>" notin page
    check "<span class=\"lives-label pb-lbl\">Hill</span>" notin page
    check "<span class=\"momentum-label\">LIVES LEAD</span>" notin page

  test "no paint, hopper or spray line survives in a rendered string":
    for banned in ["Filling hoppers with fresh paint",
                   "Shaking the paint pods awake",
                   "Topping off the CO",
                   "In the locker room",
                   "TAKES THE HILL",
                   "tagged out"]:
      checkpoint(banned)
      check banned notin page

suite "the game's own vocabulary is what a spectator reads":
  test "the kill feed speaks plain language":
    check "frags</span>" in page
    check "team-kills (−1)" in page
    check "picks up a med kit" in page
    check "respawns" in page
    check "IN A ROW" in page
    check "TAKES THE LEAD" in page
    check "MISSED THE CALL — scripted order" in page

  test "POV, EYES and kill are NOT forbidden — they are live here":
    check "povBadge" in page
    check "beat-marker.kill" in page
