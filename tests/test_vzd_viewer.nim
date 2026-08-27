## The viewer chrome. Nothing else in this repo covers spectator chrome — not
## the sim tests, not viewer_smoke.mjs, not the label manifest — so the
## provenance rules, the transport rules, the 360 px rules and the removed
## #viewpanel are asserted here, against the shipped files.

import
  std/[os, strutils, unittest],
  std/sha1

const RepoDir = currentSourcePath.parentDir.parentDir

let
  chromeCommon = readFile(RepoDir / "client" / "chrome_common.js")
  page = readFile(RepoDir / "client" / "replay_broadcast.html")
  core = readFile(RepoDir / "client" / "broadcast_core.js")
  banner = "<!-- ============================================================\n" &
    "     VIZDOOM-DEATHMATCH additions to the inherited coworld-ctf chrome"

suite "chrome provenance":
  test "chrome_common.js is the starter's file, at its exact byte length":
    ## coworld-ctf ships 40 022 bytes. This fork copies it and changes exactly
    ## TWO lines — the module-path comment and `window.CTF_WIRE` ->
    ## `window.VZD_WIRE`, which is the identifier tools/gen_wire_constants.nim
    ## actually emits — so the length is unchanged and the sha is pinned here.
    check chromeCommon.len == 40022
    check ($secureHash(chromeCommon)).toLowerAscii() ==
      "833a6d61b0785241feb5cbb22372d106fe8d9295"
    check "window.VZD_WIRE" in chromeCommon
    check "window.CTF_WIRE" notin chromeCommon
    ## The alias block is untouched, which is what the dm- prefix protects.
    check "var markBeat = C.markBeat" in chromeCommon or
      "markBeat" in chromeCommon

  test "the page is the starter's page PLUS an appended block":
    let at = page.find(banner)
    check at > 200000            ## the whole inherited page comes first
    check at < page.len
    ## Nothing after the banner re-opens the inherited chrome: the block is a
    ## <style> and a <script> and then the document closes.
    let tail = page[at .. ^1]
    check tail.count("<style>") == 1
    check tail.count("<script>") == 1
    check tail.endsWith("</html>\n")
    ## And the inherited splice hook is still the starter's, renamed only.
    check "window.VzdChrome = {" in page
    check "VzdChrome.install(PB_CTX)" in page
    check "window.PaintballChrome" notin page

  test "the block never shadows the shared chrome's hoisted beat builder":
    ## The cogame-tandem 2026-08-23 hoisting trap: a game-block function named
    ## markBeat is silently swallowed by chrome_common's `var markBeat` alias
    ## and the scrubber ends up with unlabelled div markers that never seek.
    let at = page.find(banner)
    let tail = page[at .. ^1]
    check "function dmBeat(" in tail
    check "function markBeat(" notin tail
    check "markBeat(" notin tail

suite "the transport band is inviolate":
  test "relayout() sets --band, --topband and --hudscale on :root":
    check "--band" in page
    check "--topband" in page
    check "--hudscale" in page
    check "document.documentElement.style.setProperty('--band'" in page or
      "root.style.setProperty('--band'" in page or
      "setProperty('--band'" in page
    check "setProperty('--hudscale'" in page

  test "the endcard stops at the band and every seek dismisses it":
    check "#endcard {" in page
    check "bottom: var(--band, 0px)" in page
    check "endcard').classList.remove('on')" in page or
      "$('endcard').classList.remove('on')" in page

  test "no game-block element is positioned inside the transport band":
    ## Everything this block adds lives inside #chrome, whose own box is
    ## inset: var(--topband) 0 var(--band) 0, so nothing can reach below it.
    let at = page.find(banner)
    let tail = page[at .. ^1]
    check "chrome.appendChild(el)" in tail          ## #eyes
    check "clock.appendChild(el)" in tail           ## #fragbug
    check "bottom: 0" notin tail
    check "#transport" notin tail

  test "scrubber beats are labelled, clickable BUTTONS":
    let at = page.find(banner)
    let tail = page[at .. ^1]
    check "createElement('button')" in tail
    check "el.setAttribute('aria-label', label)" in tail
    check "CTX.send('s:' + tick)" in tail
    check "button.beat-marker" in tail

  test "beat CSS exists for every kind emitted and NO others":
    let at = page.find(banner)
    let tail = page[at .. ^1]
    for kind in ["gamestart", "kill", "streak", "lead", "fallback",
                 "gameover"]:
      checkpoint(kind)
      check (".beat-marker." & kind) in tail
    for gone in ["steal", "return", "capture", "hillflip", "tagout"]:
      checkpoint(gone)
      check (".beat-marker." & gone) notin page

suite "#viewpanel is gone: this is a FIXED arena":
  test "the zoom bar, the minimap and their wiring are removed":
    for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-in",
               "zoom-out", "zoom-slider", "zoom-read"]:
      checkpoint(id)
      check ("id=\"" & id & "\"") notin page
      check ("$('" & id & "')") notin page
    check "attachMinimap" notin page
    check "ZOOM_STEP" notin page
    check "panCellBoardPx" notin page

  test "broadcast_core.js tolerates never being attached":
    check "attachMinimap" in core          ## the entry point survives, unused
    check "minimapCtx" in core

suite "the inherited chrome this game KEEPS":
  test "the first-person inset and its whole family are still there":
    for id in ["viewport", "stage", "board", "chrome", "scorebug", "plates-l",
               "plates-r", "clock", "clock-time", "clock-caption", "povBadge",
               "fpv", "fpv-canvas", "fpv-hud", "fpv-name", "fpv-hp",
               "fpv-gear", "fpv-map", "fpv-map-canvas", "fpv-cap", "fpv-grip",
               "bannerlane", "killfeed", "mmwarn", "transport", "btn-restart",
               "btn-back", "btn-play", "btn-fwd", "btn-end", "btn-loop",
               "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip",
               "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill",
               "lulls", "scrub-head", "endcard", "ec-headline", "ec-wincond",
               "ec-how", "ec-teams", "ec-replay", "status", "lockerroom"]:
      checkpoint(id)
      check ("id=\"" & id & "\"") in page

  test "the game block's own ids are present":
    check "id = 'eyes'" in page
    check "id = 'fragbug'" in page
    check "#eyes" in page
    check "#fragbug" in page

suite "legible at 360 px":
  test "the plate name never collapses to a bare ellipsis":
    check ".plate-name {" in page
    check "flex: 1 1 auto;" in page
    check "min-width: 3.2em;" in page
    check "text-overflow: ellipsis;" in page

  test "labels are hidden under 640 px of board":
    check "#stage.tiny" in page
    check "#stage.tiny .plate .frag-label" in page
    check "#stage.tiny #eyes .dm-eye canvas { display: none; }" in page
    check "#stage.tiny #fragbug" in page

  test "every added size derives from --hudscale through --u":
    let at = page.find(banner)
    let tail = page[at .. ^1]
    check "var(--u)" in tail

suite "no root-absolute asset reference":
  test "every asset the page loads goes through a derived base":
    ## The starter's own test_first_person_pip scan, kept and extended to the
    ## nano-banana art: this page is served from three different roots and a
    ## leading slash is only correct at one of them.
    check "COG_BASE + '/soldier_" in page
    check "DM_BASE + '/glyph_frag.png'" in page
    check "DM_BASE + '/helm_'" in page
    check "src=\"/" notin page
    check "src='/" notin page

  test "only the two shipped team kits are requested":
    check "['red', 'blue'].forEach(function (team) {" in page
    check "'green', 'yellow'" notin page
