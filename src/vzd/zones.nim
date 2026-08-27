## The 5 x 3 lettered zone grid: the only place names in this game.
##
## Columns A..E run left to right, rows 1..3 top to bottom, so `A1` is the
## top-left corner and `E3` the bottom-right. RED spawns in column A and BLUE
## in column E (the starter's Red-left / Blue-right contract). Zone centres are
## published to every seat in its first observation; the prompt, the LLM's
## `at` field and both scripted baselines all speak this vocabulary, so an
## order and a bot mean the same thing by "C2".
##
## INTEGER ONLY. `zoneAt` feeds nothing hashed today, but it is the vocabulary
## the driver resolves targets through, and `tests/test_vzd_sim.nim` greps this
## file for float literals, `/` and `sqrt` and requires none.

import
  std/strutils,
  sim_types

const
  ZoneCount* = ZoneCols * ZoneRows
  ZoneColLetters* = "ABCDE"
  TerrainOpen* = "open"
  TerrainCover* = "cover"
  TerrainCorridor* = "corridor"

proc zoneIndex*(col, row: int): int {.inline.} =
  ## The flat index of a (column, row) cell, clamped onto the board.
  clamp(row, 0, ZoneRows - 1) * ZoneCols + clamp(col, 0, ZoneCols - 1)

proc zoneId*(index: int): string =
  ## "A1" .. "E3", in id order.
  let i = clamp(index, 0, ZoneCount - 1)
  $ZoneColLetters[i mod ZoneCols] & $(i div ZoneCols + 1)

proc zoneColOf*(index: int): int {.inline.} = index mod ZoneCols
proc zoneRowOf*(index: int): int {.inline.} = index div ZoneCols

proc zoneColBounds*(col: int): tuple[lo, hi: int] =
  ## The half-open pixel column span of one grid column. The last column
  ## absorbs the remainder, so the fifteen zones partition the whole board
  ## with no gap and no overlap.
  let width = MapWidth div ZoneCols
  if col >= ZoneCols - 1: (col * width, MapWidth)
  else: (col * width, (col + 1) * width)

proc zoneRowBounds*(row: int): tuple[lo, hi: int] =
  ## The half-open pixel row span of one grid row.
  let height = MapHeight div ZoneRows
  if row >= ZoneRows - 1: (row * height, MapHeight)
  else: (row * height, (row + 1) * height)

proc zoneAtIndex*(x, y: int): int =
  ## Which zone contains a map pixel. Off-board pixels clamp onto the edge
  ## zone rather than reporting "nowhere": every position in this game has a
  ## name.
  let
    width = max(1, MapWidth div ZoneCols)
    height = max(1, MapHeight div ZoneRows)
    col = clamp(clamp(x, 0, MapWidth - 1) div width, 0, ZoneCols - 1)
    row = clamp(clamp(y, 0, MapHeight - 1) div height, 0, ZoneRows - 1)
  row * ZoneCols + col

proc zoneAt*(x, y: int): string {.inline.} =
  ## Which zone contains a map pixel, as its published id.
  zoneId(zoneAtIndex(x, y))

proc zoneCentreOf*(index: int): tuple[x, y: int] =
  ## The centre pixel of one zone.
  let
    cols = zoneColBounds(zoneColOf(index))
    rows = zoneRowBounds(zoneRowOf(index))
  ((cols.lo + cols.hi) div 2, (rows.lo + rows.hi) div 2)

proc parseZoneId*(text: string): int =
  ## "c2", "C2", " C2 " -> the flat index, or -1 if it is not a zone id.
  let key = text.strip().toUpperAscii()
  if key.len != 2:
    return -1
  let col = ZoneColLetters.find(key[0])
  if col < 0:
    return -1
  if key[1] < '1' or key[1] >= char(ord('1') + ZoneRows):
    return -1
  (ord(key[1]) - ord('1')) * ZoneCols + col

proc zoneCentre*(text: string): tuple[found: bool, x, y: int] =
  ## The centre of a named zone.
  let index = parseZoneId(text)
  if index < 0:
    return (false, 0, 0)
  let centre = zoneCentreOf(index)
  (true, centre.x, centre.y)

proc zoneWallPermille*(sim: SimServer, index: int): int =
  ## What fraction of one zone is wall, in permille, sampled on an 8 px
  ## lattice. Integer only, and a pure function of the installed map.
  let
    cols = zoneColBounds(zoneColOf(index))
    rows = zoneRowBounds(zoneRowOf(index))
  var
    seen = 0
    walls = 0
  var y = rows.lo
  while y < rows.hi:
    var x = cols.lo
    while x < cols.hi:
      inc seen
      let at = y * MapWidth + x
      if at >= 0 and at < sim.wallMask.len and sim.wallMask[at]:
        inc walls
      x += 8
    y += 8
  if seen == 0: 0 else: walls * 1000 div seen

proc zoneTerrain*(sim: SimServer, index: int): string =
  ## The zone's one-word terrain, derived at load from its wall fraction:
  ## under 8 % is `open`, over 22 % is `corridor`, everything between is
  ## `cover`.
  let permille = sim.zoneWallPermille(index)
  if permille < 80: TerrainOpen
  elif permille > 220: TerrainCorridor
  else: TerrainCover
