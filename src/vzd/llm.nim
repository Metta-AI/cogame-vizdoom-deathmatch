## Claude-backed squad command. A policy is just a prompt: the game server
## composes the seat's fogged view plus that seat's PLAYER_PROMPT and asks
## Claude what its cogs do for the next 4.5 seconds.
##
## Ported from `cogame-bullwhip/src/bullwhip/llm.nim`, behaviour for
## behaviour — the credential ladder, the Bedrock model rotation, the
## fence-tolerant JSON extraction and the rune-boundary truncation are all
## that file's, because they are all scar tissue from real hosted failures.
##
## Paintball is a SIMULTANEOUS-decision game, so both seats' calls go out as
## ONE parallel batch per turn (`curly.makeRequests`). Seats are never queried
## sequentially: that is what keeps 40 turns inside the wall-clock budget.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT (hosted), or local Bedrock bearer token
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim_types, directives

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again (paintball round 2, 2026-08-25).

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "paintball llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call.
  ##
  ## `us.anthropic.claude-sonnet-4-6` was never a candidate (cogame-raid round
  ## 2, 2026-08-23) and `us.anthropic.claude-sonnet-4-5-20250929-v1:0` is not
  ## one either: it was the ladder fallback for paintball 0.1.2 and the hosted
  ## round-2 game log recorded 133 calls to it, every single one returning
  ## "Timeout was reached" and none returning text. One haiku throttle then
  ## cascaded into a whole episode of scripted fallbacks — the retry is what
  ## burned the turn, not the throttle. With no second candidate a throttle
  ## fails fast (see LlmClient.throttled) and the seat plays the scripted
  ## fallback for that turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "paintball llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "vizdoom-deathmatch llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "vizdoom-deathmatch llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" below: "LLM provider is unavailable".
    echo "vizdoom-deathmatch llm: no credentials — the LLM provider is ",
      "unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string, slot: int
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are ONE marine in an eight-cog team deathmatch: four RED against four BLUE on one
walled arena. You are told which side you are on; you cannot change it. Every 108 ticks
(4.5 seconds) you give your marine ONE order and a deterministic driver carries it out
until you change it: it walks, it turns, and it pulls the trigger by itself whenever a
live enemy is inside your cone, in range, with a clear line and no teammate in the way.

WHAT YOU SEE
You do NOT see the whole board. You see a 90-degree cone along your AIM out to 1575px,
plus a 90px bubble around you. Walls block both; glass windows do not.
- "rays" is your depth strip: 16 distances across the cone, left to right, in your OWN
  bearings (negative = left of your aim). -1 means nothing within sight.
- "contacts" is what your eyes actually resolved: enemies, teammates and med kits, each
  with a bearing relative to your aim, a distance, a zone and (for cogs) hit points.
  An enemy with "ticks_ago" above 0 is a MEMORY, not a sighting - it has moved.
- The map itself is public: 15 lettered zones A1..E3 (A = your left edge on RED,
  E = the right edge), each with a centre and a terrain word.

WEAPONS
Hitscan gun, 1050px range, kills in 3 hits, 0.5s between shots, and a 0.2s wind-up
during which your aim is LOCKED - a target that steps behind cover survives the shot.
Aim is fuzzed: a distant target is hit about 4 times in 5, a near one almost always.
FRIENDLY FIRE IS ON and killing a teammate costs you a frag. Med kits restore health
and respawn 30 seconds after they are taken. You respawn 2 seconds after dying, at your
own spawn, at full health.

SCORING - the only thing that counts
Your team's score is (enemy kills) - (teammate kills) - (deaths), summed over your four
marines, minus the same number for theirs. A 12-frag lead is a maximum win. Trading one
for one is worth nothing. Dying is exactly as expensive as a frag is valuable, so a
fight you are going to lose is worth walking away from.

YOUR ORDER (one per turn; your marine keeps it until you change it)
  {"intent":"hunt","at":"BLUE-alpha"}    go to that contact and kill it
  {"intent":"hold","at":"B2","face":[700,330]}  stand there, watch that bearing, shoot
  {"intent":"move_to","at":"C2"}         walk there, gun up
  {"intent":"flank","at":"D1"}           walk there the long way, through an EMPTY row
  {"intent":"retreat"}                   fall back to your own spawn and hold
  {"intent":"regroup"}                   go to where your living teammates are
"at" takes a zone id (A1..E3) or a contact's alias. "to":[x,y] works too; "at" wins.

TALKING
"say" is at most 10 characters and is SHOUTED OUT LOUD: everybody within 247px hears it
and sees where it came from, INCLUDING THE ENEMY. "radio" is up to 96 characters and
only your three teammates hear it, next turn. "notes" comes back to you and nobody else.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the character {
and end with }. No prose, no markdown, no code fences.
{"intent":"hunt","at":"C2","say":"<=10 chars","radio":"<=96 chars","notes":"<=160 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## view. The view is built server-side from the seat's fog (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson
