## The objective layer: frags minus deaths, team-summed, zero-sum.
##
## This is the whole of what this coworld scores. Everything in here is
## INTEGER ONLY — no float literal, no `/`, no `sqrt` — because `netFor`,
## `teamNet` and `leadTeam` feed `gameHash` and are therefore re-derived tick
## for tick by the wasm replay viewer, where Nim's `int` is 32 bits.
## `tests/test_vzd_sim.nim` greps this file for exactly those three things.
##
## Sign: HIGHER IS BETTER. `margin(T)` is `teamNet[T] - teamNet[other]`, which
## is exactly antisymmetric, so a red seat's `scorePermille` and a blue seat's
## sum to exactly 1000 for every legal outcome. There is deliberately NO
## tiebreak: margin 0 is a draw at 0.500 and every `win` is false.

import
  sim_types, sim_state, paint

proc netFor*(sim: SimServer, cogIndex: int): int =
  ## One cog's score contribution: enemy kills, minus teammate kills, minus
  ## every death whatever the cause. Literally the idea's "frags - deaths",
  ## with a team kill charged to the killer as a lost frag — the Quake /
  ## ViZDoom convention, and the only thing that stops friendly fire from
  ## being a free way to deny an enemy a frag.
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return 0
  let player = sim.players[cogIndex]
  player.kills - player.teamKills - player.deaths

proc teamNet*(sim: SimServer, team: Team): int =
  ## The team total: the sum of `netFor` over every cog on that team.
  for i in 0 ..< sim.players.len:
    if sim.players[i].team == team:
      result += sim.netFor(i)

proc marginFor*(sim: SimServer, team: Team): int =
  ## `teamNet[T] - teamNet[other(T)]`, exactly antisymmetric.
  let other = if team == Red: Blue else: Red
  sim.teamNet(team) - sim.teamNet(other)

proc redMargin*(sim: SimServer): int {.inline.} =
  ## The canonical margin: from RED's point of view. `results.margin`.
  sim.marginFor(Red)

proc deathmatchLeader*(sim: SimServer): tuple[team: Team, draw: bool] =
  ## Who is ahead on net frags right now, and whether it is level.
  let margin = sim.redMargin()
  if margin > 0: (Red, false)
  elif margin < 0: (Blue, false)
  else: (Red, true)

proc scorePermilleFor*(sim: SimServer, team: Team): int {.inline.} =
  ## The league's ranked number, in permille:
  ## `500 + clamp(margin * 500 div DecisiveMargin, -500, +500)`.
  ## `gameScorePermille` is the starter's own antisymmetric helper, reused
  ## unchanged, which is what guarantees the exact 1000 sum.
  gameScorePermille(sim.marginFor(team), DecisiveMargin)

proc longestStreak*(sim: SimServer, cogIndex: int): int {.inline.} =
  ## The most frags this cog took between two deaths. `bestKillsInLife` is
  ## the starter's own counter; a deathmatch calls it a streak.
  if cogIndex < 0 or cogIndex >= sim.players.len: 0
  else: sim.players[cogIndex].bestKillsInLife

proc updateDeathmatchLead*(sim: var SimServer) =
  ## Recomputes the lead from the per-cog counters (pure derivation, no
  ## separate state) and emits ONE throttled `lead` event when it changes
  ## hands. Hashed through `leadTeam` / `lastLeadTick` so a replay re-derives
  ## the same announcements at the same ticks.
  let
    margin = sim.redMargin()
    leader =
      if margin > 0: ord(Red)
      elif margin < 0: ord(Blue)
      else: -1
  if leader == sim.leadTeam:
    return
  let previous = sim.leadTeam
  sim.leadTeam = leader
  if leader < 0:
    return
  if previous >= 0 and sim.tickCount - sim.lastLeadTick < LeadThrottleTicks:
    return
  sim.lastLeadTick = sim.tickCount
  sim.emitEvent(
    Lead, weapon = teamText(Team(leader)),
    amount = (if leader == ord(Red): margin else: -margin))

proc streakMilestone*(n: int): bool {.inline.} =
  ## 3, 5 and 8 frags without dying are the announced streaks.
  n == 3 or n == 5 or n == 8
