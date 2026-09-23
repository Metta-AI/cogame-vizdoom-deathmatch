## Export complete deathmatches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [arena|pool]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import vzd/[sim, roster, control, baselines, directives, decide, llm]

const OperatorPrompt = "Coordinate your squad using only your own sensor view."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [arena|pool]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "arena"
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin ["arena", "pool"]:
    quit("variant must be arena or pool", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    config.update($runtimeConfig)
    config.seed = seed
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    for seat in 0 ..< config.numAgents:
      let name = "policy-" & $seat
      discard sim.addPlayer(name, seat, "", trusted = true)
      sim.seatNames[seat] = name
    sim.startGame()
    var
      engine = initDecisionEngine(sim)
      previous = newSeq[InputState](sim.players.len)
      rows: seq[string]
      lastTurn = -1
    while sim.phase != GameOver:
      engine.ctl.observeEnemies(sim)
      let turn = sim.gameTicksElapsed() div config.turnTicks
      if sim.gameTicksElapsed() mod config.turnTicks == 0 and turn != lastTurn:
        lastTurn = turn
        for seat in 0 ..< config.numAgents:
          if engine.haveDirective[seat] and engine.directives[seat].orders.len > 0:
            engine.lastResult[seat] = engine.ctl.driverResult(sim,
              engine.directives[seat].orders[0], seat)
          let view = engine.seatViewJson(sim, seat, turn,
            config.maxTicks div config.turnTicks)
          engine.mapSent[seat] = true
          let teacher = scriptedDirective(engine.ctl, sim, blRusher,
            sim.commandedCogs(seat), previous = engine.directives[seat])
          let order = teacher.orders[0]
          let completion = %*{
            "intent": $order.intent,
            "to": [order.targetX, order.targetY],
            "face": (if order.hasFace: %[order.faceX, order.faceY]
                     else: newJNull()),
            "say": order.say,
            "radio": teacher.radio,
            "notes": teacher.note
          }
          let parsed = parseSeatDirective(completion, seat,
            sim.cogAlias(seat), newSeq[string](), newSeq[int](),
            newSeq[int](), order.targetX, order.targetY,
            MapWidth - 1, MapHeight - 1)
          doAssert parsed.orders.len == 1
          doAssert parsed.orders[0].fromReply
          doAssert parsed.orders[0].intent == order.intent
          doAssert parsed.orders[0].targetX == order.targetX
          doAssert parsed.orders[0].targetY == order.targetY
          doAssert parsed.orders[0].hasFace == order.hasFace
          doAssert parsed.orders[0].say == order.say
          rows.add($(%*{
            "episode_id": "vizdoom-deathmatch-" & variant & "-" & $seed,
            "seed": "vizdoom-deathmatch-" & variant & "-" & $seed,
            "decision_id": turn * config.numAgents + seat,
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": userMessage(OperatorPrompt, view)}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "vizdoom-deathmatch",
            "action_schema_revision": "deathmatch-directive-v1"
          }))
          engine.directives[seat] = parsed
          engine.haveDirective[seat] = true
          engine.notes[seat] = parsed.note
          engine.radio[seat] = parsed.radio
        for seat in 0 ..< config.numAgents:
          for order in engine.directives[seat].orders:
            if order.say.len > 0:
              discard sim.applyShout(order.cogIndex, order.say)
      var inputs = newSeq[InputState](sim.players.len)
      for seat in 0 ..< config.numAgents:
        let mask = engine.ctl.compileMask(sim,
          engine.directives[seat].orders[0], seat)
        inputs[seat] = decodeInputMask(mask)
      sim.step(inputs, previous)
      previous = inputs
    doAssert rows.len > 0
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "win": outcome["win"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "vizdoom-deathmatch",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-rusher",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
