# Metta post-training data

The native simulator and published `rusher` policy can export supervised
examples for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/vizdoom-arena 10 1 arena
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/vizdoom-pool 10 1 pool
```

Each run reads its manifest variant config, adds the per-seat tokens supplied
by the hosted platform, and plays complete seeded, eight-seat matches. The
exporter records the hosted system prompt, each seat's sensor-limited view,
and a `rusher` action accepted by the game's reply parser. Parsed actions and
shouts drive the simulator. Splits are by match seed. The manifest records
source revision, variant, scores, wins, and row counts. Existing output
directories are never overwritten.

Train either output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/vizdoom-arena \
  --output /tmp/vizdoom-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The local 10-match arena and pool exports each contained 1,536 training and
384 validation examples. All 3,840 examples fit a 4096-token model context.
One CPU optimizer update reduced held-out loss from 5.6277 to 5.5317
(arena) and 5.5492 to 5.4544 (pool). This distills the scripted teacher; it
does not establish stronger league play.
