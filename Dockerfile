# Build Docker. ONE image, TWO entrypoints: /bin/vizdoom-deathmatch (the game
# server, which also makes every LLM call — the anthropic key is injected into
# the GAME pod, not the player pod) and /bin/vizdoom-deathmatch-player (the
# thin seat registrar). The whole policy set is env-switched inside this same
# image (PLAYER_PROMPT vs PLAYER_SCRIPTED=rusher|sentry), which is what keeps
# a champion and a scripted filler byte-identical apart from their
# environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/vzd
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="src/vizdoom_deathmatch.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/vizdoom-deathmatch-nimcache \
  --out:vizdoom-deathmatch \
  $NimMain && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/vizdoom-deathmatch-player-nimcache \
  --out:vizdoom-deathmatch-player \
  src/vizdoom_deathmatch_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/vzd
COPY --from=build /workspace/vzd/vizdoom-deathmatch /bin/vizdoom-deathmatch
COPY --from=build /workspace/vzd/vizdoom-deathmatch-player \
  /bin/vizdoom-deathmatch-player
COPY --from=build /workspace/vzd/*.json ./
COPY --from=build /workspace/vzd/data ./data
# The starter's Dockerfile omits client/; this fork copies it so /client/player
# and /client/global serve REAL pages for the certifier's browser probes
# (the cogame-lantern 0.1.1 scar).
COPY --from=build /workspace/vzd/client ./client

CMD ["/bin/vizdoom-deathmatch"]
