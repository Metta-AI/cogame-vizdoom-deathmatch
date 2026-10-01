## The manifest pins. Every one of these is a hosted-upload failure or a
## league scheduling failure if it drifts, and none of them is caught anywhere
## else in this repo.

import
  std/[json, os, strutils, unittest],
  vzd_helpers

const RepoDir = currentSourcePath.parentDir.parentDir

let manifest = parseJson(readFile(RepoDir / "coworld_manifest_template.json"))

proc allGameConfigs(): seq[JsonNode] =
  for variant in manifest["variants"]:
    result.add(variant["game_config"])
  result.add(manifest["certification"]["game_config"])

suite "manifest pins":
  test "num_agents is 8 in every variant's game_config AND the cert fixture":
    var seen = 0
    for config in allGameConfigs():
      check config.hasKey("num_agents")
      check config["num_agents"].getInt() == 8
      inc seen
    check seen == 3

  test "num_agents is absent at every variant TOP level":
    ## CoworldVariant is additionalProperties: false and the platform reads
    ## only game_config.num_agents (goofspiel-oshi-zumo 0.1.0).
    for variant in manifest["variants"]:
      check not variant.hasKey("num_agents")

  test "no game_config carries a literal tokens array":
    ## matriculate rejects "game_config must not include runner-managed
    ## tokens" (knights-archers 0.1.0), while config_schema keeps REQUIRING it
    ## because the runner injects it.
    for config in allGameConfigs():
      check not config.hasKey("tokens")
    check "tokens" in manifest["game"]["config_schema"]["required"].to(seq[string])
    check manifest["game"]["config_schema"]["properties"].hasKey("tokens")

  test "players and slots are 8 long everywhere and slots alternate red/blue":
    for config in allGameConfigs():
      check config["players"].len == 8
      check config["slots"].len == 8
      for i in 0 ..< 8:
        check config["slots"][i]["team"].getStr() ==
          (if i mod 2 == 0: "red" else: "blue")

  test "the four SEAT-COUNT invariants docker_smoke.sh cross-checks":
    let cert = manifest["certification"]
    check cert["game_config"]["num_agents"].getInt() == 8
    check cert["players"].len == 8
    check cert["game_config"]["players"].len == 8

  test "every declared player occupies a certification slot":
    ## The raid 0.1.2 scar: a declared player that never plays fails certify.
    var declared, seated: seq[string]
    for player in manifest["player"]:
      declared.add(player["id"].getStr())
    for row in manifest["certification"]["players"]:
      let id = row["player_id"].getStr()
      if id notin seated:
        seated.add(id)
    check declared.len == 2
    for id in declared:
      check id in seated
    for id in seated:
      check id in declared

  test "every config_schema array carries minItems and maxItems":
    ## The tandem 0.1.0 scar.
    for name, prop in manifest["game"]["config_schema"]["properties"]:
      if prop{"type"}.getStr() == "array":
        checkpoint(name)
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "episode_timeout_minutes is TOP level and game.tags does not exist":
    check manifest.hasKey("episode_timeout_minutes")
    check manifest["episode_timeout_minutes"].getInt() == 20
    check not manifest["game"].hasKey("tags")          ## pistonball 0.1.0
    check manifest["tags"].len >= 3

  test "the replay viewer is the STATIC bundle, declared under game":
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")

  test "both protocols are present as {type, value} OBJECTS":
    ## The garble v0.1.0 scar: bare strings are rejected.
    for key in ["player", "global"]:
      let node = manifest["game"]["protocols"][key]
      check node.kind == JObject
      check node["value"].getStr().startsWith("https://")

  test "game.docs carries a readme and three non-empty pages":
    let docs = manifest["game"]["docs"]
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 400
    check docs["pages"].len == 3
    var ids: seq[string]
    for page in docs["pages"]:
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 400
      ids.add(page["id"].getStr())
    check ids == @["rules.md", "observation.md", "protocol.md"]

  test "the game is named, owned, described and points at ONE image":
    check manifest["game"]["name"].getStr() == "vizdoom-deathmatch"
    check manifest["game"]["owner"].getStr().len > 0
    check manifest["game"]["description"].getStr().len > 400
    check manifest["game"]["runnable"]["type"].getStr() == "game"
    check manifest["game"]["runnable"]["image"].getStr() ==
      "{{VIZDOOM_DEATHMATCH_IMAGE}}"
    check manifest["game"]["runnable"]["run"].to(seq[string]) ==
      @["/bin/vizdoom-deathmatch"]
    doAssert manifest{"game"}{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.isNil,
      "hosted LLM uses the platform sidecar without provider secrets"

  test "the compose service name derives the image placeholder":
    let compose = readFile(RepoDir / "compose.yaml")
    check "  vizdoom-deathmatch:" in compose
    check "image: coworld-vizdoom-deathmatch:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose

  test "player resources: limits.cpu is at least 1":
    ## The pistonball 0.1.1 scar.
    for player in manifest["player"]:
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["run"].to(seq[string]) ==
        @["/bin/vizdoom-deathmatch-player"]
      check player["image"].getStr() == "{{VIZDOOM_DEATHMATCH_IMAGE}}"

suite "the wall clock fits inside 60% of the episode timeout":
  test "every wallClockBudgetSeconds is at most 660":
    for config in allGameConfigs():
      check config["wallClockBudgetSeconds"].getInt() <= 660

  test "24 turns at the worst-case rate floor still fits every VARIANT":
    ## The certification fixture is excluded on purpose: it runs offline, with
    ## no API key and every seat scripted, which is why it sets
    ## turnSpacingMs to 0 — there is no batch to space out and no rate floor
    ## to pay. The league variants are the ones that must fit.
    for variant in manifest["variants"]:
      let
        config = variant["game_config"]
        turnTicks = config["turnTicks"].getInt()
        turns = max(1, config["maxTicks"].getInt() div turnTicks)
        floorMs = effectiveSpacingMs(
          config["turnSpacingMs"].getInt(), config["num_agents"].getInt())
      checkpoint(variant["id"].getStr())
      check turns * floorMs div 1000 + 134 <=
        config["wallClockBudgetSeconds"].getInt()

  test "the certification fixture finishes offline in seconds":
    let cert = manifest["certification"]["game_config"]
    check cert["turnSpacingMs"].getInt() == 0
    check cert["maxTicks"].getInt() == 1080
    check cert["wallClockBudgetSeconds"].getInt() <= 660

suite "the shipped config actually constructs":
  test "every variant's game_config builds a valid GameConfig":
    for config in allGameConfigs():
      var node = copy(config)
      var tokens = newJArray()
      for i in 0 ..< 8:
        tokens.add(%("token-" & $i))
      node["tokens"] = tokens
      var built = defaultGameConfig()
      built.update($node)
      check built.numAgents == 8
      check built.cogsPerTeam == 1
      check built.teams == 2
      check built.slots.len == 8
      check built.loadout == LoadoutDeathmatch
      check built.lives > built.maxTicks div (built.respawnTicks + 1)

suite "the CI policy set":
  test "two prompt champions, two scripted baselines, one image":
    let policies = parseJson(readFile(RepoDir / "tools" / "ci" / "policies.json"))
    check policies.len == 4
    var prompts, scripted = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/vizdoom-deathmatch-player"
      check policy["name"].getStr().startsWith("vzd-")
      check policy["env"].hasKey("PLAYER_POLICY_LABEL")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in ["rusher", "sentry"]
    check prompts == 2
    check scripted == 2
    ## The two champions must be DIFFERENT prompts.
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()
    ## Champion #2 is owned by daveey-1.
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[0].hasKey("player")

  test "no unsubstituted scaffold placeholder survives":
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh",
                 "tools/ci/policies.json"]:
      let text = readFile(RepoDir / path)
      checkpoint(path)
      check "<slug>" notin text
      check "<IMAGE>" notin text
      check "<SEATS>" notin text
