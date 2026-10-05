#!/usr/bin/env bash
# tools/inference.sh — vLLM inference endpoints on an AWS GPU instance, in
# one command each: stand a box up, watch it boot, test it, reach it through
# an SSH tunnel, reconfigure it in place, extend its life, tear it down. The
# `test` half also works on any OpenAI-compatible endpoint (a local
# llama-server, Bedrock, an old box).
#
#   tools/inference.sh up      [--type g6e.xlarge] [--days 1] [--model REPO] [--bulk-model REPO]
#                              [--decide-gguf PATH] [--decide-served NAME]
#                              [--regions a,b,c] [--profile P] [--account ID] [--spot] [--mtp N] [--name NAME] …
#   tools/inference.sh restart [--name NAME] [the same model options]   push a new configuration to a running box
#                            (models not given are kept from the box; --bulk-model none and
#                            --decide-gguf none drop those slots)
#   tools/inference.sh status  [--name NAME]              every box this script manages
#   tools/inference.sh test    [--name NAME | --url URL --model NAME [--decide] [--bearer-file FILE | --bearer KEY]]
#   tools/inference.sh tunnel  [--name NAME] [--port N]   local URLs for PROSE_URL / BENCH_URL
#   tools/inference.sh extend  --days D [--name NAME]     move the self-termination timer
#   tools/inference.sh down    [--name NAME] [--keep-ip]   terminate; the key pair and SG stay
#   tools/inference.sh persist --domain HOST --api-key-file FILE [--route53-zone ZONE]
#                              [--acme-email YOU] [--name NAME] [--force]
#                            turn a running box into an always-on keyed HTTPS endpoint
#
# A box serves up to three SLOTS. `prose` (--model, the 27B, the box's :8000)
# is the app's Generative model. `bulk` (--bulk-model, the 4B, :8001) is
# optional; the app no longer uses it, but the benches may, so it stays
# exactly as it was. Each is its own vLLM container with its own share of the
# GPU (--mem / --bulk-mem); the shares are chosen so the pair fits one L40S.
# `decide` (--decide-gguf PATH, :8002) is the app's Decision model: the
# fine-tuned ModernBERT classifier as a GGUF, served as mean-pooled embeddings
# by a llama.cpp container (llama-decide); the app applies the heads (the
# nine message fields and the three storyline questions) itself, so the heads file stays on the Mac and is never uploaded. PATH has
# no default; the usual value is the v3 swap file the app downloaded from the
# model registry (or `make decide-fetch` fetched) into
# "$HOME/Library/Application Support/com.bondinbox.app/models/artifactory_bond-decide-mbl-v3swap/
# bond-decide-mbl-v3-f16.gguf". Serve that v3 swap file and no other: raw v3
# carries the same served name, and nothing catches raw-v3 vectors under the
# app's v3 swap heads. It is copied up from this machine and its
# sha256 checked on the box before the slot starts. It is served under the
# file's name less its -<quant>.gguf (bond-decide-mbl-v3-f16.gguf serves as
# bond-decide-mbl-v3), which the app's heads pairing reads against the heads
# file's model; --decide-served overrides it. The slot is off unless --decide-gguf
# is given; `restart` keeps it from the box like the other models.
# --decide-image pins another llama.cpp CUDA image. The app's Your server
# decision address for such a box is https://HOST/decide/v1/embeddings.
# Why a third slot and not the bulk slot repurposed (the round's plan said
# repurpose): the benches still drive bulk, and a slot that changes meaning
# under the same flag would break them silently. The decide slot starts
# AFTER the vLLM slots, because vLLM checks free GPU memory at start; it
# needs about 1.5 GB, which fits beside prose alone (0.92) and is tight beside
# prose + bulk (0.80 + 0.16).
#
# PERSISTENT MODE. `up --domain HOST …` builds an always-on box, and `persist`
# converts a running one in place. Either way Caddy takes 443 on one hostname
# and forwards /prose/, /bulk/ and /decide/ to the slots on the box's
# loopback, every slot checks an api-key (llama-server reads it with
# --api-key-file /opt/bond/api.key), and an Elastic IP keeps the name pointing
# at the box across a stop and start. A hostname implies --persistent, because a box
# the app points at must not walk away mid-session: a persistent box has no
# self-termination timer, so `down` is what ends it, and `extend` refuses.
# Its options: --persistent, --domain HOST, --api-key KEY or --api-key-file
# FILE, --route53-zone ZONE to write the A record, --acme-email YOU for the
# certificate notices, --keep-ip to keep the address after the box goes down.
# Give the key as --api-key-file FILE. That is the recommended form, because
# --api-key KEY puts the key on this command's argv, where anyone with an
# account on this machine can read it out of the process table, and where the
# shell history keeps it. A key file is read once and never logged.
# `persist` on a box that already holds this key and is serving does nothing
# to the slots; --force restarts them anyway.
# On a persistent box the access key is the credential for the app and for the
# bench recipes. Port 22 stays open to the operator's IP alone and `tunnel` is
# still the operator's own path to the slots.
#
# Why a script and not the Makefile: the Makefile drives the local servers
# from one process; this drives AWS across regions and sessions, and it must
# run from a checkout that has no Flutter. It needs aws (v2), jq, ssh, curl.
#
# How a box is shaped — the recipe the 2026-09-16 spike measured
# (docs/model-bakeoff.md, run matrix row 7): a Deep Learning Base AMI (Ubuntu
# 24.04, NVIDIA driver, Docker), the vllm/vllm-openai image, the weights
# cached on the root volume, vLLM bound to the box's loopback ONLY, and SSH
# open to the caller's IP alone. Nothing else listens, so by default the
# endpoint needs no API key: the SSH tunnel is the credential. A persistent
# box adds Caddy on 443 and an api-key on every slot, and then the key is the
# credential. The box terminates itself
# when its timer runs out (--days), whether or not anyone remembers it —
# `extend` moves the timer, `down` ends it early.
#
# State: tmp/inference/<name>.env (git-ignored) caches region, instance id,
# tunnel, hostname and Elastic IP allocation; the tag `bond-inference=<name>`
# on the instance is the source
# of truth, so a fresh clone can still `status`, `test` and `down`.
set -u

# ── defaults ────────────────────────────────────────────────────────────
NAME=default
TYPE=g6e.xlarge
DAYS=1
# The prose slot.
MODEL=Qwen/Qwen3.8-27B-FP8
# The alias the Makefile's PROSE_MODEL / BENCH_MODEL default to; the repo id
# is served too, so a wrong alias costs nothing but convenience.
SERVED=qwen3.8
MAXLEN=
MEM=
# The model's own MTP head: 2 drafted tokens measured 2× per stream on the
# 27B with no accuracy change (docs/model-bakeoff.md). 0 turns it off, which
# a model without an MTP head needs.
MTP=2
# Flags the default prose model needs; another model may want different ones.
VLLM_ARGS="--reasoning-parser qwen3 --limit-mm-per-prompt '{\"image\":0,\"video\":0}' --enable-prefix-caching"
EXTRA_ARGS=
# The bulk slot, off unless --bulk-model is given. Its defaults are sized to
# sit beside the 27B on one 48 GB card: FP8 KV, 8K context, 8 sequences. CUDA
# graphs stay ON: --enforce-eager saved ~1 GB and cost 3.5× per stream on the
# 4B (37 against 128 tok/s), measured 2026-09-17.
BULK_MODEL=
BULK_SERVED=qwen3-4b
BULK_MAXLEN=8192
BULK_MEM=0.16
BULK_ARGS="--enable-prefix-caching --kv-cache-dtype fp8 --max-num-seqs 8"
IMAGE=vllm/vllm-openai:v0.29.0
# The decide slot, off unless --decide-gguf is given (or kept from the box on
# `restart`). DECIDE_GGUF is the local file to upload; DECIDE_FILE its name on
# the box, under /opt/bond/decide/. The served name is the one the app asks a
# box for (boxDecideModel in app/lib/services/llm/model_slots.dart); empty
# means the file's own name less its -<quant>.gguf (served_from_file), so a
# v3 file serves as bond-decide-mbl-v3 with no flag. --decide-served sets it.
DECIDE_GGUF=
DECIDE_FILE=
DECIDE_SET=
DECIDE_SERVED=
DECIDE_SERVED_SET=
# The llama.cpp build pinned like the vLLM image: b10896 is the bundled
# sidecar build that matched PyTorch in the round's parity check
# (docs/model-bakeoff.md, "Decision model ledger"). --decide-image overrides.
DECIDE_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda-b10896
# Context, micro-batch and batch in one number: llama-server refuses an input
# longer than the micro-batch, and the app truncates to exactly this many
# tokens ([CLS] + 2046 + [SEP]) when it does, so the two must agree.
DECIDE_CTX=2048
# `test --url … --decide` runs the embedding checks instead of the chat ones.
TEST_DECIDE=0
DISK=200
REGIONS=us-west-2,us-east-2,us-east-1
PROFILE=
ACCOUNT=
SPOT=0
SSH_KEY=$HOME/.ssh/id_ed25519
PORT=
URL=
BEARER=
BEARER_FILE=
SSH_USER=ubuntu
MODEL_SET=
BULK_MODEL_SET=
# Never 8000: the local llama servers and MCPs live in that range.
PORT_FROM=18100
POLL=15
BOOT_TIMEOUT_MIN=45
# Persistent mode: an always-on box reached over TLS at one hostname, with an
# api-key in place of the SSH tunnel. Off unless --persistent or --domain.
PERSISTENT=0
API_KEY=
API_KEY_FILE=
DOMAIN=
ROUTE53_ZONE=
ACME_EMAIL=
KEEP_IP=0
# persist skips the slot restart when the box already holds the key it was
# given; --force restarts them regardless.
FORCE=0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR=$ROOT/tmp/inference

# ── plumbing ────────────────────────────────────────────────────────────
log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'inference: %s\n' "$*" >&2; exit 1; }
need() { for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "needs $b on PATH"; done; }
aws()  { command aws --no-cli-pager ${PROFILE:+--profile "$PROFILE"} "$@"; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

state_file() { echo "$STATE_DIR/$NAME.env"; }
save_state() {  # save_state KEY VALUE — one line per key, sourceable
  mkdir -p "$STATE_DIR"
  local f; f=$(state_file)
  { [ -f "$f" ] && grep -v "^$1=" "$f"; printf '%s=%q\n' "$1" "$2"; } > "$f.tmp" && mv "$f.tmp" "$f"
}
load_state() { [ -f "$(state_file)" ] && . "$(state_file)"; :; }

my_ip() { curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]'; }

# The digest of stdin, with the tool this machine has: sha256sum where there
# is one, shasum on a Mac.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

ssh_box() {  # ssh_box IP CMD…
  local ip=$1; shift
  ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
      -o LogLevel=ERROR -i "$SSH_KEY" "$SSH_USER@$ip" "$@"
}

whoami_aws() {
  local acct; acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || die "no AWS credentials${PROFILE:+ for profile $PROFILE}"
  [ -n "$ACCOUNT" ] && [ "$acct" != "$ACCOUNT" ] && die "signed in to account $acct, not $ACCOUNT"
  log "aws account $acct${PROFILE:+ (profile $PROFILE)}"
}

# On-demand $/h from the pricing API (us-east-1 hosts it for every region);
# "?" when the call is not permitted or the type is unlisted.
price_for() {  # price_for TYPE REGION
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$1" "Type=TERM_MATCH,Field=regionCode,Value=$2" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --query 'PriceList[0]' --output text 2>/dev/null \
    | jq -r '.terms.OnDemand[]?.priceDimensions[]?.pricePerUnit.USD' 2>/dev/null | head -1 | grep . | awk '{printf "%.2f", $1}' || echo "?"
}

# The key pair and the SSH-only security group in a region, created once and
# re-used by every box launched there.
ensure_key() {  # ensure_key REGION
  aws ec2 describe-key-pairs --region "$1" --key-names bond-inference >/dev/null 2>&1 && return
  [ -f "$SSH_KEY.pub" ] || die "no public key at $SSH_KEY.pub (--ssh-key)"
  aws ec2 import-key-pair --region "$1" --key-name bond-inference \
    --public-key-material "fileb://$SSH_KEY.pub" >/dev/null || die "key import failed in $1"
  log "$1: imported key pair bond-inference from $SSH_KEY.pub"
}
ensure_sg() {  # ensure_sg REGION → sets SG
  local r=$1 vpc
  vpc=$(aws ec2 describe-vpcs --region "$r" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  [ "$vpc" = None ] && die "$r has no default VPC; pick another region (--regions)"
  SG=$(aws ec2 describe-security-groups --region "$r" --filters Name=group-name,Values=bond-inference-ssh "Name=vpc-id,Values=$vpc" \
         --query 'SecurityGroups[0].GroupId' --output text)
  [ "$SG" != None ] && return
  SG=$(aws ec2 create-security-group --region "$r" --group-name bond-inference-ssh \
         --description "SSH to the bond inference box, from the operator IP only" --vpc-id "$vpc" --query GroupId --output text) \
    || die "could not create the security group in $r"
  aws ec2 create-tags --region "$r" --resources "$SG" --tags Key=Name,Value=bond-inference-ssh Key=project,Value=bond-desktop
  log "$r: created security group $SG"
}
# authorize-security-group-ingress fails when the rule is already there, which
# is the normal case on every call after the first. That one error is swallowed
# and every other one is fatal, so a permissions problem cannot be mistaken for
# a rule that is already in place.
allow_ingress() {  # allow_ingress REGION SG PORT CIDR
  local err
  err=$(aws ec2 authorize-security-group-ingress --region "$1" --group-id "$2" \
          --protocol tcp --port "$3" --cidr "$4" 2>&1 >/dev/null) \
    && { log "$1: port $3 now open to $4 on $2"; return 0; }
  case "$err" in
    *InvalidPermission.Duplicate*) return 0 ;;
    *) die "$1: could not open port $3 on $2: $err" ;;
  esac
}

# The caller's current IP, allowed on port 22 of a group. Called before every
# SSH because home IPs move: the spike's box went unreachable overnight for
# exactly that reason. For an existing instance the group is ITS group, which
# may predate this script.
allow_my_ip() {  # allow_my_ip REGION [INSTANCE_ID]
  local r=$1 sg=${SG:-} ip ids n
  if [ -n "${2:-}" ]; then
    # A converted box carries the web group as well, and SecurityGroups[0] is
    # then whichever the API lists first, so port 22 would land on the group
    # that is open to the world. Port 22 belongs to bond-inference-ssh, and the
    # group is chosen by that name.
    ids=$(aws ec2 describe-instances --region "$r" --instance-ids "$2" \
            --query 'Reservations[0].Instances[0].SecurityGroups[?GroupName==`bond-inference-ssh`].GroupId' --output text) \
      || die "could not read the security groups of $2"
    sg=$(echo $ids)
    if [ -z "$sg" ]; then
      # A box that predates this script has one group of its own name; that is
      # the only case where a group not called bond-inference-ssh is taken.
      ids=$(aws ec2 describe-instances --region "$r" --instance-ids "$2" \
              --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text) \
        || die "could not read the security groups of $2"
      n=$(echo $ids | wc -w | tr -d ' ')
      [ "$n" = 1 ] || die "$2 has $n security groups and none named bond-inference-ssh; open port 22 by hand"
      sg=$(echo $ids)
    fi
  fi
  [ -n "$sg" ] && [ "$sg" != None ] || die "no security group to open port 22 on in $r"
  ip=$(my_ip); [ -n "$ip" ] || die "could not learn this machine's public IP"
  allow_ingress "$r" "$sg" 22 "$ip/32"
}

# The instance behind NAME: the state file first (fast), then a tag scan of
# every region in --regions. Sets REGION INSTANCE_ID IP ITYPE STATE IMODEL IBULK
# IDECIDE IDECIDEFILE.
find_instance() {
  load_state
  local r q; q='Reservations[].Instances[?State.Name!=`terminated`&&State.Name!=`shutting-down`][].[InstanceId,PublicIpAddress,InstanceType,State.Name,Tags[?Key==`model`].Value|[0],Tags[?Key==`bulk-model`].Value|[0],Tags[?Key==`decide-model`].Value|[0],Tags[?Key==`decide-file`].Value|[0]]'
  if [ -n "${REGION:-}" ] && [ -n "${INSTANCE_ID:-}" ]; then
    set -- $(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query "$q" --output text 2>/dev/null)
    [ $# -ge 4 ] && { INSTANCE_ID=$1 IP=$2 ITYPE=$3 STATE=$4 IMODEL=${5:-} IBULK=${6:-} IDECIDE=${7:-} IDECIDEFILE=${8:-}; return 0; }
  fi
  for r in $(echo "$REGIONS" | tr , ' '); do
    set -- $(aws ec2 describe-instances --region "$r" --filters "Name=tag:bond-inference,Values=$NAME" --query "$q" --output text 2>/dev/null)
    [ $# -ge 4 ] && { REGION=$r INSTANCE_ID=$1 IP=$2 ITYPE=$3 STATE=$4 IMODEL=${5:-} IBULK=${6:-} IDECIDE=${7:-} IDECIDEFILE=${8:-}; save_state REGION "$r"; save_state INSTANCE_ID "$1"; return 0; }
  done
  return 1
}
# `none` is what cmd_restart writes to the tag when a slot is dropped, and None
# is what the AWS CLI prints for a tag that was never set.
has_bulk() { [ -n "${IBULK:-}" ] && [ "$IBULK" != None ] && [ "$IBULK" != none ]; }
# IDECIDE is the decide-model tag: the served name, or none.
has_decide() { [ -n "${IDECIDE:-}" ] && [ "$IDECIDE" != None ] && [ "$IDECIDE" != none ]; }

free_port() {  # three adjacent free ports, for the three slots
  local p; for p in $(seq "$PORT_FROM" $((PORT_FROM + 97))); do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && continue
    lsof -nP -iTCP:"$((p + 1))" -sTCP:LISTEN >/dev/null 2>&1 && continue
    lsof -nP -iTCP:"$((p + 2))" -sTCP:LISTEN >/dev/null 2>&1 && continue
    echo "$p"; return
  done; die "no three free local ports in a row in $PORT_FROM..$((PORT_FROM + 99))"
}

# A background `ssh -N -L` to the box's three slot ports; re-used while it
# lives. A forward to a slot the box does not run costs nothing until used.
ensure_tunnel() {  # needs IP; sets PORT, URL, BULK_URL, DECIDE_URL
  load_state
  # A tunnel opened before the decide slot existed forwards two ports, not
  # three; it is closed and reopened rather than re-used.
  # It is waited out (bounded) and its base port re-used when all three are
  # free, so the tunnel stays at 18100 by convention.
  if [ -n "${TUNNEL_PID:-}" ] && [ "${TUNNEL_SLOTS:-}" != 3 ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    kill "$TUNNEL_PID" 2>/dev/null
    local w=0; while kill -0 "$TUNNEL_PID" 2>/dev/null && [ $w -lt 10 ]; do sleep 0.3; w=$((w + 1)); done
    TUNNEL_PID=; log "closed a two-port tunnel to reopen it with the decide port"
    if [ -z "$PORT" ] && [ -n "${TUNNEL_PORT:-}" ] \
       && ! lsof -nP -iTCP:"$TUNNEL_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
       && ! lsof -nP -iTCP:"$((TUNNEL_PORT + 1))" -sTCP:LISTEN >/dev/null 2>&1 \
       && ! lsof -nP -iTCP:"$((TUNNEL_PORT + 2))" -sTCP:LISTEN >/dev/null 2>&1; then
      PORT=$TUNNEL_PORT
    fi
  fi
  if [ -n "${TUNNEL_PID:-}" ] && kill -0 "$TUNNEL_PID" 2>/dev/null && [ -n "${TUNNEL_PORT:-}" ] \
     && curl -s --max-time 5 -o /dev/null "http://localhost:$TUNNEL_PORT/health"; then
    PORT=$TUNNEL_PORT
  else
    [ -n "$PORT" ] || PORT=$(free_port)
    nohup ssh -N -L "$PORT:127.0.0.1:8000" -L "$((PORT + 1)):127.0.0.1:8001" -L "$((PORT + 2)):127.0.0.1:8002" \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o LogLevel=ERROR -i "$SSH_KEY" "$SSH_USER@$IP" >/dev/null 2>&1 &
    TUNNEL_PID=$!
    local i=0; until curl -s --max-time 3 -o /dev/null "http://localhost:$PORT/health"; do
      kill -0 "$TUNNEL_PID" 2>/dev/null || die "ssh to $IP failed (security group, key $SSH_KEY, or the box is down: $0 status)"
      i=$((i + 1)); [ $i -gt 30 ] && die "tunnel on :$PORT is up but vLLM on the box does not answer; on the box: docker logs vllm-prose"; sleep 2
    done
    save_state TUNNEL_PID "$TUNNEL_PID"; save_state TUNNEL_PORT "$PORT"; save_state TUNNEL_SLOTS 3
    log "tunnel: localhost:$PORT → $IP:8000 (prose), localhost:$((PORT + 1)) → :8001 (bulk), localhost:$((PORT + 2)) → :8002 (decide) (pid $TUNNEL_PID)"
  fi
  URL="http://localhost:$PORT"; BULK_URL="http://localhost:$((PORT + 1))"; DECIDE_URL="http://localhost:$((PORT + 2))"
}

kill_tunnel() { load_state; [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null && log "tunnel closed"; :; }

# ── the box's configuration ─────────────────────────────────────────────
# One env file per slot and one serve.sh that (re)starts a slot's container:
#   /opt/bond/serve.sh prose            /opt/bond/serve.sh bulk --some-flag
#   /opt/bond/serve.sh decide           (llama.cpp, not vLLM; extra flags go to llama-server)
# `up` writes them from the boot script; `restart` pushes them over SSH.
# Single-quote a string for a sourced file, so the JSON flags inside survive.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
slot_env() {  # slot_env SLOT → the env file's contents
  local mem=$MEM maxlen=$MAXLEN mtp_args=
  [ "$MTP" -gt 0 ] && mtp_args="--speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":$MTP}'"
  if [ "$1" = prose ]; then
    if [ -n "$BULK_MODEL" ]; then
      # Sized to share one 48 GB card with the bulk slot: the 27B's weights and
      # graphs take ~34 GB, so its KV cache goes FP8 and its context 16K (what
      # local.mk already uses); the bulk slot gets the rest.
      : "${mem:=0.80}" "${maxlen:=16384}"; mtp_args="$mtp_args --kv-cache-dtype fp8 --max-num-seqs 8"
    else
      : "${mem:=0.92}" "${maxlen:=32768}"; mtp_args="$mtp_args --max-num-seqs 16"
    fi
    printf 'MODEL=%s\nSERVED=%s\nPORT=8000\nMAXLEN=%s\nMEM=%s\nARGS=%s\n' \
      "$MODEL" "$SERVED" "$maxlen" "$mem" "$(sq "$VLLM_ARGS $mtp_args $EXTRA_ARGS")"
  elif [ "$1" = decide ]; then
    printf 'FILE=%s\nSERVED=%s\nPORT=8002\nCTX=%s\n' "$DECIDE_FILE" "$DECIDE_SERVED" "$DECIDE_CTX"
  else
    printf 'MODEL=%s\nSERVED=%s\nPORT=8001\nMAXLEN=%s\nMEM=%s\nARGS=%s\n' \
      "$BULK_MODEL" "$BULK_SERVED" "$BULK_MAXLEN" "$BULK_MEM" "$(sq "$BULK_ARGS")"
  fi
}
# The part of the boot that is also a reconfiguration: write the slot files
# and serve.sh, start prose, wait for it, start bulk, then decide. Runs as
# root on the box.
box_setup() {
  cat <<EOF
mkdir -p /opt/bond/hf
cat > /opt/bond/prose.env <<'ENV'
$(slot_env prose)
ENV
rm -f /opt/bond/bulk.env
rm -f /opt/bond/decide.env
EOF
  [ -n "$BULK_MODEL" ] && cat <<EOF
cat > /opt/bond/bulk.env <<'ENV'
$(slot_env bulk)
ENV
EOF
  [ -n "$DECIDE_FILE" ] && cat <<EOF
cat > /opt/bond/decide.env <<'ENV'
$(slot_env decide)
ENV
EOF
  cat <<EOF
cat > /opt/bond/serve.sh <<'SERVE'
#!/bin/bash
# /opt/bond/serve.sh SLOT [extra flags] — (re)start one slot's container.
slot=\${1:-prose}; shift 2>/dev/null || true
. /opt/bond/\$slot.env
# The decide slot is llama.cpp serving the decision model's GGUF as mean-pooled
# embeddings. A persistent box's key reaches it as a mounted file, never a flag.
if [ "\$slot" = decide ]; then
  KEYMOUNT=; KEYFLAG=
  if [ -f /opt/bond/api.key ]; then
    KEYMOUNT="-v /opt/bond/api.key:/opt/bond/api.key:ro"; KEYFLAG="--api-key-file /opt/bond/api.key"
  fi
  # docker run -v on a missing source CREATES a directory there, which then
  # blocks the real file forever; refuse instead.
  if [ ! -f "/opt/bond/decide/\$FILE" ] || [ -L "/opt/bond/decide/\$FILE" ]; then
    echo "serve.sh decide: /opt/bond/decide/\$FILE is not a regular file; upload it with tools/inference.sh restart --decide-gguf PATH" >&2
    exit 1
  fi
  docker rm -f llama-decide 2>/dev/null || true
  exec docker run -d --name llama-decide --gpus all -p 127.0.0.1:\$PORT:8080 \\
    -v /opt/bond/decide/\$FILE:/models/\$FILE:ro \$KEYMOUNT $DECIDE_IMAGE \\
    -m /models/\$FILE --embeddings --pooling mean -c \$CTX -ub \$CTX -b \$CTX -np 1 -ngl 99 \\
    --host 0.0.0.0 --port 8080 \$KEYFLAG --alias \$SERVED "\$@"
fi
# The api-key a persistent box checks, as an env file rather than a flag: a
# flag would show in the box's process table. The value is still readable in
# \`docker inspect\` .Config.Env, on a box only the operator can reach.
KEYENV=; [ -f /opt/bond/api.env ] && KEYENV="--env-file /opt/bond/api.env"
docker rm -f vllm vllm-\$slot 2>/dev/null || true
GPUS=\$(nvidia-smi -L | wc -l)
eval "exec docker run -d --name vllm-\$slot --gpus all --ipc=host -p 127.0.0.1:\$PORT:8000 \\
  -v /opt/bond/hf:/root/.cache/huggingface \$KEYENV $IMAGE \\
  --model \$MODEL --served-model-name \$SERVED \$MODEL --tensor-parallel-size \$GPUS \\
  --max-model-len \$MAXLEN --gpu-memory-utilization \$MEM \$ARGS \"\\\$@\""
SERVE
chmod +x /opt/bond/serve.sh
echo serving-prose > /opt/bond/stage
/opt/bond/serve.sh prose
for i in \$(seq 1 240); do curl -s -o /dev/null localhost:8000/health && break; sleep 10; done
if [ -f /opt/bond/bulk.env ]; then echo serving-bulk > /opt/bond/stage; /opt/bond/serve.sh bulk; fi
EOF
  # The GGUF is copied up from the operator's machine while the box boots, and
  # appears under its final name only once its sha256 checked out; the vLLM
  # slots go first because vLLM measures free GPU memory when it starts.
  [ -n "$DECIDE_FILE" ] && cat <<EOF
if [ -f /opt/bond/decide.env ]; then
  echo waiting-gguf > /opt/bond/stage
  for i in \$(seq 1 180); do [ -f /opt/bond/decide/$DECIDE_FILE ] && break; sleep 10; done
  if [ -f /opt/bond/decide/$DECIDE_FILE ]; then
    if [ -f /opt/bond/bulk.env ]; then for i in \$(seq 1 240); do curl -s -o /dev/null localhost:8001/health && break; sleep 5; done; fi
    echo serving-decide > /opt/bond/stage; /opt/bond/serve.sh decide
    echo started > /opt/bond/stage
  fi
else
  echo started > /opt/bond/stage
fi
EOF
  # With the slot on, a GGUF that never arrived leaves the stage at
  # waiting-gguf and starts no container; the operator's command says why.
  [ -n "$DECIDE_FILE" ] || echo "echo started > /opt/bond/stage"
}
userdata() {  # the first-boot script: timer, image pull, then box_setup
  local minutes; minutes=$(awk -v d="$DAYS" 'BEGIN { printf "%d", d * 1440 }')
  [ "$PERSISTENT" = 1 ] || [ "$minutes" -ge 5 ] || die "--days $DAYS is under five minutes"
  cat <<EOF
#!/bin/bash
set -uxo pipefail
exec > /var/log/bond-inference.log 2>&1
EOF
  # A persistent box runs until 'down' ends it, so it gets no timer at all.
  [ "$PERSISTENT" = 1 ] || echo "shutdown -h +$minutes"
  cat <<EOF
mkdir -p /opt/bond; echo booting > /opt/bond/stage
echo pulling > /opt/bond/stage
docker pull $IMAGE
EOF
  [ -n "$DECIDE_FILE" ] && echo "docker pull $DECIDE_IMAGE"
  box_setup
}

# ── the persistent endpoint ─────────────────────────────────────────────
# A persistent box is reached at one hostname over TLS instead of through the
# SSH tunnel: Caddy holds 443, forwards /prose/ and /bulk/ to the two slots on
# the box's loopback, and vLLM checks an api-key on both. The key is the
# credential for the app; port 22 stays open to the operator's IP alone.

read_api_key() {  # fills API_KEY from --api-key-file; the value is never logged
  [ -n "$API_KEY" ] && [ -n "$API_KEY_FILE" ] && die "give --api-key or --api-key-file, not both"
  if [ -n "$API_KEY_FILE" ]; then
    [ -f "$API_KEY_FILE" ] || die "no key file at $API_KEY_FILE"
    API_KEY=$(tr -d '[:space:]' < "$API_KEY_FILE")
    [ -n "$API_KEY" ] || die "the key file $API_KEY_FILE is empty"
  fi
  :
}

# The key travels over ssh STDIN, never on a command line, so it is in no
# process table and in no shell history on either machine.
push_api_key() {  # push_api_key IP
  local ip=$1
  printf 'VLLM_API_KEY=%s\n' "$API_KEY" \
    | ssh_box "$ip" 'sudo install -m 600 /dev/stdin /opt/bond/api.env' \
    || die "could not write /opt/bond/api.env on $ip"
  printf '%s\n' "$API_KEY" \
    | ssh_box "$ip" 'sudo install -m 600 /dev/stdin /opt/bond/api.key' \
    || die "could not write /opt/bond/api.key on $ip"
  log "the access key is on the box at /opt/bond/api.env, mode 600, root only"
}

# Re-running `persist` on a box that is already converted used to restart both
# vLLM containers, which costs minutes of downtime for nothing when the key has
# not changed. The box's copy of the key is hashed over ssh and compared with
# the key in hand, and the slots are left alone when they match and every slot
# is still running. --force restarts them anyway.
key_unchanged() {  # key_unchanged IP
  local ip=$1 here there slots=prose s c
  [ "$FORCE" = 1 ] && return 1
  has_bulk && slots="prose bulk"
  has_decide && slots="$slots decide"
  here=$(printf '%s\n' "$API_KEY" | sha256_stdin)
  there=$(ssh_box "$ip" 'sudo sha256sum /opt/bond/api.key 2>/dev/null | cut -d" " -f1' 2>/dev/null) || return 1
  [ -n "$here" ] && [ "$here" = "$there" ] || return 1
  for s in $slots; do
    c=vllm-$s; [ "$s" = decide ] && c=llama-decide
    [ "$(ssh_box "$ip" "docker inspect -f '{{.State.Running}}' $c 2>/dev/null")" = true ] || return 1
  done
  return 0
}

# The second group: 443 for the app, 80 for ACME's HTTP-01 challenge and
# Caddy's redirect. bond-inference-ssh is left exactly as it is.
ensure_web_sg() {  # ensure_web_sg REGION → sets WEB_SG
  local r=$1 vpc
  vpc=$(aws ec2 describe-vpcs --region "$r" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  [ "$vpc" = None ] && die "$r has no default VPC; pick another region (--regions)"
  WEB_SG=$(aws ec2 describe-security-groups --region "$r" --filters Name=group-name,Values=bond-inference-web "Name=vpc-id,Values=$vpc" \
             --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$WEB_SG" = None ]; then
    WEB_SG=$(aws ec2 create-security-group --region "$r" --group-name bond-inference-web \
               --description "HTTPS and ACME to the bond inference box, from anywhere" --vpc-id "$vpc" --query GroupId --output text) \
      || die "could not create the web security group in $r"
    aws ec2 create-tags --region "$r" --resources "$WEB_SG" --tags Key=Name,Value=bond-inference-web Key=project,Value=bond-desktop
    log "$r: created security group $WEB_SG"
  fi
  # One call per port: a group that already has 443 would fail the pair.
  allow_ingress "$r" "$WEB_SG" 443 0.0.0.0/0
  allow_ingress "$r" "$WEB_SG" 80 0.0.0.0/0
}

# An address that outlives a stop and start, so the A record stays true. An
# allocation already tagged for this name is re-used rather than a second one
# taken; an allocation held but not attached is billed, which is why `down`
# releases it unless --keep-ip.
ensure_eip() {  # ensure_eip REGION NAME → sets IP and ALLOC_ID
  local r=$1 n=$2 alloc
  alloc=$(aws ec2 describe-addresses --region "$r" --filters "Name=tag:bond-inference,Values=$n" \
            --query 'Addresses[0].AllocationId' --output text 2>/dev/null)
  if [ -z "$alloc" ] || [ "$alloc" = None ]; then
    alloc=$(aws ec2 allocate-address --region "$r" --domain vpc --query AllocationId --output text) \
      || die "could not allocate an Elastic IP in $r"
    aws ec2 create-tags --region "$r" --resources "$alloc" \
      --tags "Key=bond-inference,Value=$n" "Key=Name,Value=bond-inference-$n" Key=project,Value=bond-desktop
    log "$r: allocated Elastic IP $alloc"
  else
    log "$r: re-using Elastic IP $alloc, already tagged for '$n'"
  fi
  aws ec2 associate-address --region "$r" --instance-id "$INSTANCE_ID" --allocation-id "$alloc" >/dev/null \
    || die "could not associate $alloc with $INSTANCE_ID"
  IP=$(aws ec2 describe-addresses --region "$r" --allocation-ids "$alloc" --query 'Addresses[0].PublicIp' --output text)
  [ -n "$IP" ] && [ "$IP" != None ] || die "the Elastic IP $alloc has no public address"
  ALLOC_ID=$alloc
  save_state ALLOC_ID "$alloc"
  aws ec2 create-tags --region "$r" --resources "$INSTANCE_ID" --tags "Key=eip,Value=$alloc" >/dev/null
  log "$n now answers on $IP, and keeps that address across a stop and start"
}

# handle_path strips the prefix, so vLLM and llama-server see /v1/… (and the
# decide slot's /tokenize). /decide is routed whether or not the slot runs; a
# box without it answers 502 there. A Caddyfile an older version wrote has no
# /decide at all, and `restart --decide-gguf` writes this one over it. flush_interval -1 is load
# bearing: drafts stream as server-sent events and a buffering proxy would hold
# every token to the end. The email line is written only when --acme-email was
# given, because an empty value is a Caddyfile parse error.
caddyfile() {
  if [ -n "$ACME_EMAIL" ]; then
    cat <<'CF'
{
	email {$ACME_EMAIL}
}
CF
  fi
  cat <<'CF'
{$BOX_DOMAIN} {
	handle_path /prose/* {
		reverse_proxy 127.0.0.1:8000 {
			flush_interval -1
		}
	}
	handle_path /bulk/* {
		reverse_proxy 127.0.0.1:8001 {
			flush_interval -1
		}
	}
	handle_path /decide/* {
		reverse_proxy 127.0.0.1:8002 {
			flush_interval -1
		}
	}
	handle {
		respond "bond inference" 200
	}
}
CF
}

# Host networking, so 127.0.0.1:8000 is the host's loopback and 443 and 80 bind
# directly. /data holds the account key and the certificate, so a restart or a
# stop and start does not order a new one.
install_caddy() {  # install_caddy IP
  local ip=$1
  ssh_box "$ip" 'sudo bash -s' <<EOF || die "could not install Caddy on $ip"
set -e
mkdir -p /opt/bond/caddy/data /opt/bond/caddy/config
cat > /opt/bond/caddy.env <<'ENV'
BOX_DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
ENV
cat > /opt/bond/Caddyfile <<'CADDY'
$(caddyfile)
CADDY
docker run --rm -v /opt/bond/Caddyfile:/etc/caddy/Caddyfile:ro \\
  --env-file /opt/bond/caddy.env caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker rm -f caddy 2>/dev/null || true
docker run -d --name caddy --restart unless-stopped --network host \\
  --env-file /opt/bond/caddy.env \\
  -v /opt/bond/Caddyfile:/etc/caddy/Caddyfile:ro \\
  -v /opt/bond/caddy/data:/data -v /opt/bond/caddy/config:/config caddy:2
# docker run -d exits 0 the moment the container is created, so the container
# has to be asked whether it is still alive a moment later.
sleep 3
if [ "\$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" != true ]; then
  docker logs --tail 40 caddy >&2 || true
  echo "caddy did not stay up" >&2
  exit 1
fi
EOF
  log "caddy is up; https://$DOMAIN/prose, https://$DOMAIN/bulk and https://$DOMAIN/decide are the slots"
}

# The A record, then the wait for it. Caddy must not ask for a certificate
# before the name resolves: a failed ACME order counts against a tighter
# weekly limit than the five certificates a hostname gets.
dns_note() {  # dns_note IP
  local ip=$1 i=0 got
  if [ -n "$ROUTE53_ZONE" ]; then
    aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_ZONE" \
      --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$DOMAIN\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$ip\"}]}}]}" \
      --query 'ChangeInfo.Status' --output text >/dev/null \
      || die "could not write the A record for $DOMAIN in hosted zone $ROUTE53_ZONE"
    log "route53: $DOMAIN A $ip, TTL 60, in hosted zone $ROUTE53_ZONE"
  else
    log "create this DNS record now and this command carries on by itself:"
    log "    $DOMAIN   A   $ip   TTL 60"
  fi
  log "waiting for $DOMAIN to resolve to $ip, up to ten minutes"
  while :; do
    got=$(dig +short "$DOMAIN" A 2>/dev/null | tail -1)
    [ "$got" = "$ip" ] && { log "$DOMAIN resolves to $ip"; return 0; }
    i=$((i + 1))
    [ $((i * POLL)) -ge 600 ] && die "$DOMAIN still does not resolve to $ip after ten minutes. Fix the record, then resume with '$0 persist --name $NAME --domain $DOMAIN --api-key-file FILE'; an 'up' cannot be re-run, it would say the box is already running"
    sleep "$POLL"
  done
}

instance_tag() {  # instance_tag KEY → one tag off the instance, empty when unset
  local v
  v=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].Tags[?Key=='$1'].Value|[0]" --output text 2>/dev/null)
  [ "$v" = None ] && v=
  printf '%s' "$v"
}

# Every slot again, so they read a key file written after they started. The
# milestones and the wait are wait_serving's, exactly as on a boot.
restart_slots() {  # restart_slots IP
  local ip=$1
  log "restarting the slots so they read the access key"
  cat <<'RS' | ssh_box "$ip" 'sudo mkdir -p /opt/bond; sudo bash -c "cat > /opt/bond/restart-slots.sh"; sudo nohup bash /opt/bond/restart-slots.sh >/dev/null 2>&1 &' \
    || die "could not restart the slots on $ip"
set -uxo pipefail
exec >> /var/log/bond-inference.log 2>&1
docker rm -f vllm vllm-prose vllm-bulk llama-decide 2>/dev/null || true
echo restarting > /opt/bond/stage
/opt/bond/serve.sh prose
for i in $(seq 1 240); do curl -s -o /dev/null localhost:8000/health && break; sleep 5; done
if [ -f /opt/bond/bulk.env ]; then echo serving-bulk > /opt/bond/stage; /opt/bond/serve.sh bulk; fi
if [ -f /opt/bond/decide.env ]; then
  if [ -f /opt/bond/bulk.env ]; then for i in $(seq 1 240); do curl -s -o /dev/null localhost:8001/health && break; sleep 5; done; fi
  echo serving-decide > /opt/bond/stage; /opt/bond/serve.sh decide
fi
echo started > /opt/bond/stage
RS
  wait_serving
}

# Caddy binds 443 before its first ACME order has finished, so the fallback
# route is what says the endpoint is really ready: a 200 with no key, on a path
# that reaches no model.
# The budget is wall clock, as wait_instance's is: a poll that blocks for its
# own ten seconds makes a counted loop run far longer than the five minutes it
# promises.
wait_https() {
  local t0 code=
  t0=$(date +%s)
  log "waiting for the certificate on https://$DOMAIN, up to five minutes"
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null)
    [ "$code" = 200 ] && { log "https://$DOMAIN answers 200; the certificate is in place"; return 0; }
    [ $(( $(date +%s) - t0 )) -ge 300 ] && die "https://$DOMAIN did not answer 200 within five minutes; the last answer was ${code:-none}. On the box, docker logs caddy"
    sleep "$POLL"
  done
}

test_https() {  # every slot through the front door, with the key
  load_state
  run_test "https://$DOMAIN/prose" "${SERVED_NAME:-$SERVED}" "$API_KEY" || return 1
  has_bulk && { run_test "https://$DOMAIN/bulk" "${BULK_SERVED_NAME:-$BULK_SERVED}" "$API_KEY" || return 1; }
  has_decide && { run_decide_test "https://$DOMAIN/decide" "${DECIDE_SERVED_NAME:-$DECIDE_SERVED}" "$API_KEY" || return 1; }
  return 0
}

# What the owner needs after a box becomes persistent. The key is never
# printed: it is typed into the app and kept in .env for the bench recipes.
persist_next_steps() {
  local served bserved
  load_state
  served=${SERVED_NAME:-$SERVED}
  cat <<EOF

the app's model URLs:
  https://$DOMAIN/prose/v1/chat/completions   model: $served
EOF
  has_bulk && { bserved=${BULK_SERVED_NAME:-$BULK_SERVED}
    echo "  https://$DOMAIN/bulk/v1/chat/completions    model: $bserved"; }
  has_decide && {
    echo "the app's decision address (Settings, Decision model, Your server):"
    echo "  https://$DOMAIN/decide/v1/embeddings        model: ${DECIDE_SERVED_NAME:-$DECIDE_SERVED}"
    echo "  (the heads file stays on the Mac: the app downloads it from the model registry)"; }
  cat <<EOF
the access key goes in local.mk as BOND_BOX_KEY, or is typed in the app. It is not printed here and
it belongs in no committed file.
next:
  $0 test --url https://$DOMAIN/prose --bearer <key> --model $served
EOF
  has_bulk && echo "  $0 test --url https://$DOMAIN/bulk --bearer <key> --model ${BULK_SERVED_NAME:-$BULK_SERVED}"
  has_decide && echo "  $0 test --url https://$DOMAIN/decide --decide --bearer <key> --model ${DECIDE_SERVED_NAME:-$DECIDE_SERVED}"
  echo "  $0 status      $0 down      $0 tunnel is still the operator's own path"
}

# ── up / restart ────────────────────────────────────────────────────────
# The one check on a decide file name, for --decide-gguf and for the
# decide-file tag read back off the instance: it reaches a remote shell, a
# docker mount and a tag, so it is a plain .gguf name and nothing else.
# The served name a decide file gets by default: its name less .gguf and the
# last -<quant> segment (bond-decide-mbl-v3-f16.gguf -> bond-decide-mbl-v3).
served_from_file() {  # served_from_file FILE
  local b=${1%.gguf}
  echo "${b%-*}"
}

check_decide_file() {  # check_decide_file NAME WHERE-IT-CAME-FROM
  case "$1" in
    *.json) die "$2: takes the .gguf; the heads file ($1) stays on the Mac" ;;
    *[!A-Za-z0-9._-]*|.*) die "$2: the file name $1 must be letters, digits, dot, dash and underscore" ;;
    *.gguf) ;;
    *) die "$2: takes a .gguf file, not $1" ;;
  esac
}

describe_box() { echo "$MODEL as '$SERVED'${BULK_MODEL:+ + bulk $BULK_MODEL as '$BULK_SERVED'}${DECIDE_FILE:+ + decide $DECIDE_FILE as '$DECIDE_SERVED'}"; }

scp_box() {  # scp_box LOCAL IP REMOTE — the same options as ssh_box
  scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
      -o LogLevel=ERROR -i "$SSH_KEY" "$1" "$SSH_USER@$2:$3"
}

# The decide slot's GGUF, from this machine to /opt/bond/decide/ on the box.
# It lands in incoming/ first and moves to its final name only after the box's
# sha256 of it equals this machine's, because the boot script starts the slot
# as soon as the final name exists. A file already there with the same digest
# is not sent again. Only the GGUF travels: the heads file stays on the Mac,
# where the app applies the heads.
upload_decide() {  # upload_decide IP
  local ip=$1 here there
  [ -f "$DECIDE_GGUF" ] || die "no decision model at $DECIDE_GGUF (the app downloads it into the models folder, or run make decide-fetch)"
  log "decide: hashing $DECIDE_FILE here"
  here=$(sha256_stdin < "$DECIDE_GGUF")
  [ -n "$here" ] || die "could not hash $DECIDE_GGUF"
  # A non-file at the final path (a directory an older boot's docker -v left)
  # counts as absent.
  there=$(ssh_box "$ip" "f=/opt/bond/decide/$DECIDE_FILE; [ -f \"\$f\" ] && [ ! -L \"\$f\" ] && sudo sha256sum \"\$f\" 2>/dev/null | cut -d' ' -f1" 2>/dev/null)
  if [ "$here" = "$there" ]; then
    log "decide: $DECIDE_FILE is already on the box with sha256 ${here:0:12}…; not sent again"
    return 0
  fi
  ssh_box "$ip" "sudo mkdir -p /opt/bond/decide/incoming && sudo chown $SSH_USER /opt/bond/decide/incoming" \
    || die "could not make /opt/bond/decide/incoming on $ip"
  log "decide: copying $DECIDE_FILE ($(( $(wc -c < "$DECIDE_GGUF") / 1048576 )) MB) to the box"
  scp_box "$DECIDE_GGUF" "$ip" "/opt/bond/decide/incoming/$DECIDE_FILE" || die "could not copy $DECIDE_FILE to $ip (the box is still running and billing: retry with $0 restart --name $NAME --decide-gguf PATH, or end it with $0 down --name $NAME)"
  there=$(ssh_box "$ip" "sha256sum /opt/bond/decide/incoming/$DECIDE_FILE | cut -d' ' -f1")
  if [ "$here" != "$there" ]; then
    ssh_box "$ip" "rm -f /opt/bond/decide/incoming/$DECIDE_FILE" || :
    die "decide: sha256 MISMATCH for $DECIDE_FILE: here $here, on the box ${there:-unreadable}. The copy was deleted and the slot not started (the box is still running and billing: retry with $0 restart --name $NAME --decide-gguf PATH, or end it with $0 down --name $NAME)"
  fi
  # mv -T (GNU; the box is Linux) never moves INTO a directory of that name;
  # one left by an older boot is removed first.
  ssh_box "$ip" "f=/opt/bond/decide/$DECIDE_FILE; src=/opt/bond/decide/incoming/$DECIDE_FILE; sudo chown root:root \"\$src\" && sudo chmod 644 \"\$src\" && { [ ! -d \"\$f\" ] || [ -L \"\$f\" ] || sudo rm -rf \"\$f\"; } && sudo mv -T \"\$src\" \"\$f\"" \
    || die "could not move $DECIDE_FILE into /opt/bond/decide on $ip (the box is still running and billing: retry with $0 restart --name $NAME --decide-gguf PATH, or end it with $0 down --name $NAME)"
  log "decide: $DECIDE_FILE is on the box, sha256 ${here:0:12}… matches"
}

cmd_up() {
  need aws jq ssh curl lsof
  local want_domain=$DOMAIN
  read_api_key
  whoami_aws
  find_instance && die "'$NAME' is already $STATE in $REGION ($INSTANCE_ID, $IP). Use --name for a second box, or: $0 down --name $NAME"
  # find_instance sources the state file, which may carry an older hostname.
  DOMAIN=$want_domain
  if [ -n "$DOMAIN" ]; then
    need dig
    [ -n "$API_KEY" ] || die "--domain needs --api-key-file FILE or --api-key KEY: on a public hostname the key is the only credential"
    # A box the app points at must not walk away mid-session, so a hostname
    # implies persistence whether or not --persistent was given.
    PERSISTENT=1
  fi
  local ud r ami out gpu bulk_tag= decide_tag= domain_tag= sgids=
  [ -n "$BULK_MODEL" ] && bulk_tag=",{Key=bulk-model,Value=$BULK_MODEL}"
  if [ -n "$DECIDE_FILE" ]; then
    # Checked before anything is launched, so a wrong path costs no instance.
    [ -f "$DECIDE_GGUF" ] || die "no decision model at $DECIDE_GGUF (the app downloads it into the models folder, or run make decide-fetch)"
    decide_tag=",{Key=decide-model,Value=$DECIDE_SERVED},{Key=decide-file,Value=$DECIDE_FILE}"
  fi
  [ -n "$DOMAIN" ] && domain_tag=",{Key=domain,Value=$DOMAIN}"
  ud=$(mktemp); userdata > "$ud" || exit 1
  gpu=$(aws ec2 describe-instance-types --region "${REGIONS%%,*}" --instance-types "$TYPE" \
          --query 'InstanceTypes[0].GpuInfo.Gpus[0].[Count,Name,MemoryInfo.SizeInMiB]' --output text 2>/dev/null)
  [ -n "$gpu" ] && [ "$gpu" != "None" ] || die "$TYPE is not an instance type with a GPU"
  log "up: $TYPE ($(echo "$gpu" | awk '{printf "%d× %s %d GB", $1, $2, $3/1024}')) · $(describe_box) · $( [ "$PERSISTENT" = 1 ] && echo "persistent, no timer" || echo "$DAYS day(s)") · $( [ "$SPOT" = 1 ] && echo spot || echo on-demand)${DOMAIN:+ · https://$DOMAIN}"
  for r in $(echo "$REGIONS" | tr , ' '); do
    if [ "$(aws ec2 describe-instance-type-offerings --region "$r" --location-type region \
              --filters "Name=instance-type,Values=$TYPE" --query 'length(InstanceTypeOfferings)' --output text 2>/dev/null)" = 0 ]; then
      log "$r: $TYPE not offered here"; continue
    fi
    ensure_key "$r"; ensure_sg "$r"; allow_my_ip "$r"
    sgids=$SG
    [ -n "$DOMAIN" ] && { ensure_web_sg "$r"; sgids="$SG $WEB_SG"; }
    ami=$(aws ssm get-parameter --region "$r" --query Parameter.Value --output text \
            --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id) \
      || die "$r: no Deep Learning Base AMI parameter"
    log "$r: trying $TYPE (AMI $ami, $(price_for "$TYPE" "$r") USD/h on-demand)…"
    out=$(aws ec2 run-instances --region "$r" --image-id "$ami" --instance-type "$TYPE" \
            --key-name bond-inference --security-group-ids $sgids --associate-public-ip-address \
            --instance-initiated-shutdown-behavior terminate \
            --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
            --user-data "file://$ud" \
            $( [ "$SPOT" = 1 ] && echo "--instance-market-options MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}" ) \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=bond-inference-$NAME},{Key=bond-inference,Value=$NAME},{Key=project,Value=bond-desktop},{Key=model,Value=$MODEL}$bulk_tag$decide_tag,{Key=persistent,Value=$PERSISTENT}$domain_tag]" \
            --query 'Instances[0].[InstanceId,Placement.AvailabilityZone]' --output text 2>&1)
    case "$out" in
      i-*) set -- $out; REGION=$r INSTANCE_ID=$1
           log "$r: launched $INSTANCE_ID in $2"; break ;;
      *InsufficientInstanceCapacity*|*"no Spot capacity"*|*"Insufficient capacity"*)
           log "$r: no $TYPE capacity right now"; INSTANCE_ID= ;;
      *)   die "$r: $out" ;;
    esac
  done
  rm -f -- "$ud"
  [ -n "${INSTANCE_ID:-}" ] || die "no region in [$REGIONS] had $TYPE capacity; retry later, try --spot, another --type, or more --regions"
  rm -f -- "$(state_file)"
  save_state REGION "$REGION"; save_state INSTANCE_ID "$INSTANCE_ID"; save_state SERVED_NAME "$SERVED"
  [ -n "$BULK_MODEL" ] && save_state BULK_SERVED_NAME "$BULK_SERVED"
  [ -n "$DECIDE_FILE" ] && save_state DECIDE_SERVED_NAME "$DECIDE_SERVED"
  ITYPE=$TYPE IMODEL=$MODEL IBULK=$BULK_MODEL IDECIDE=${DECIDE_FILE:+$DECIDE_SERVED} IDECIDEFILE=$DECIDE_FILE
  wait_instance
  # The GGUF goes up while the box pulls images; the boot script waits for it.
  [ -n "$DECIDE_FILE" ] && upload_decide "$IP"
  # The address and the record go in before the boot is waited out, so DNS has
  # the whole weight download to propagate and the slots are restarted once.
  [ -n "$DOMAIN" ] && { ensure_eip "$REGION" "$NAME"; dns_note "$IP"; }
  wait_serving
  if [ -n "$DOMAIN" ]; then
    push_api_key "$IP"
    restart_slots "$IP"
    install_caddy "$IP"
    save_state DOMAIN "$DOMAIN"
    wait_https
    test_https && persist_next_steps
  else
    ensure_tunnel; test_slots && next_steps
  fi
}

# Reconfigure a running box in place: push the slot files and serve.sh, restart
# prose (and bulk), follow the same milestones, test. Every model option
# applies exactly as it would on `up`; the weights are cached, so a restart
# is minutes rather than a relaunch.
cmd_restart() {
  need aws jq ssh curl lsof
  find_instance || die "no endpoint named '$NAME' in [$REGIONS]"
  [ "$STATE" = running ] || die "'$NAME' is $STATE"
  # Options not given keep what the box runs (its model tags), so a flags-only
  # restart such as `restart --bulk-args …` cannot silently drop a slot.
  [ -n "$MODEL_SET" ] || { [ -n "${IMODEL:-}" ] && [ "$IMODEL" != None ] && MODEL=$IMODEL; :; }
  [ -n "$BULK_MODEL_SET" ] || { has_bulk && BULK_MODEL=$IBULK; :; }
  [ "$BULK_MODEL" = none ] && BULK_MODEL= || :
  # The decide slot kept from the box: its file is already there (decide-file
  # tag), so nothing is uploaded; its served name comes from the decide-model
  # tag unless --decide-served was given.
  local decide_keep=0
  if [ -z "$DECIDE_SET" ] && has_decide; then
    case "${IDECIDEFILE:-}" in ''|None|none) die "'$NAME' runs a decide slot but has no decide-file tag; give --decide-gguf PATH or --decide-gguf none" ;; esac
    check_decide_file "$IDECIDEFILE" "the decide-file tag on $INSTANCE_ID"
    DECIDE_FILE=$IDECIDEFILE; decide_keep=1
    if [ -z "$DECIDE_SERVED_SET" ]; then
      case "$IDECIDE" in *[!A-Za-z0-9._-]*) die "the decide-model tag on $INSTANCE_ID ($IDECIDE) is not a plain name; give --decide-served NAME" ;; esac
      DECIDE_SERVED=${IDECIDE:-$(served_from_file "$IDECIDEFILE")}
    fi
  fi
  # --decide-served renames a slot. With no --decide-gguf and no slot on the
  # box to keep there is nothing to rename, and the flag would be dropped
  # without a word.
  if [ -n "$DECIDE_SERVED_SET" ] && [ -z "$DECIDE_SET" ] && [ "$decide_keep" = 0 ]; then
    printf 'inference: --decide-served is ignored: %s runs no decide slot and --decide-gguf was not given\n' "$NAME" >&2
  fi
  allow_my_ip "$REGION" "$INSTANCE_ID"
  log "restart $NAME ($INSTANCE_ID, $IP): $(describe_box)"
  if [ -n "$DECIDE_FILE" ]; then
    if [ "$decide_keep" = 1 ]; then
      ssh_box "$IP" "test -f /opt/bond/decide/$DECIDE_FILE" \
        || die "the box has no /opt/bond/decide/$DECIDE_FILE to keep; give --decide-gguf PATH"
    else
      upload_decide "$IP"
    fi
  fi
  { echo "set -uxo pipefail; exec >> /var/log/bond-inference.log 2>&1"
    echo "docker rm -f vllm vllm-prose vllm-bulk llama-decide 2>/dev/null; echo restarting > /opt/bond/stage"
    box_setup; } | ssh_box "$IP" 'sudo mkdir -p /opt/bond; sudo bash -c "cat > /opt/bond/restart.sh"; sudo nohup bash /opt/bond/restart.sh >/dev/null 2>&1 &' \
    || die "could not push the configuration to $IP"
  aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" --tags "Key=model,Value=$MODEL" "Key=bulk-model,Value=${BULK_MODEL:-none}" \
    "Key=decide-model,Value=$( [ -n "$DECIDE_FILE" ] && echo "$DECIDE_SERVED" || echo none)" "Key=decide-file,Value=${DECIDE_FILE:-none}"
  save_state SERVED_NAME "$SERVED"
  if [ -n "$BULK_MODEL" ]; then save_state BULK_SERVED_NAME "$BULK_SERVED"; else save_state BULK_SERVED_NAME ""; fi
  if [ -n "$DECIDE_FILE" ]; then save_state DECIDE_SERVED_NAME "$DECIDE_SERVED"; else save_state DECIDE_SERVED_NAME ""; fi
  ITYPE=$ITYPE IMODEL=$MODEL IBULK=$BULK_MODEL IDECIDE=${DECIDE_FILE:+$DECIDE_SERVED} IDECIDEFILE=$DECIDE_FILE
  wait_serving
  # A box persisted before the decide slot existed has a Caddyfile with no
  # /decide route, so its hostname answers the catch-all there, and the
  # tunnel test below cannot see that. install_caddy validates and then
  # replaces the container, so writing the file again is harmless; the email
  # the box was persisted with is read back rather than dropped.
  if [ -n "$DECIDE_SET" ] && [ -n "$DECIDE_FILE" ]; then
    local domain; domain=$(instance_tag domain)
    if [ -n "$domain" ]; then
      DOMAIN=$domain
      [ -n "$ACME_EMAIL" ] || ACME_EMAIL=$(ssh_box "$IP" "sudo sed -n 's/^ACME_EMAIL=//p' /opt/bond/caddy.env 2>/dev/null" || :)
      install_caddy "$IP"
    else
      log "decide: $NAME has no hostname, so there is no /decide route; 'persist' adds one"
    fi
  fi
  kill_tunnel; ensure_tunnel; test_slots && next_steps
}

# ── waiting ─────────────────────────────────────────────────────────────
wait_instance() {  # until the instance runs and answers SSH; sets IP
  local t0; t0=$(date +%s)
  log "waiting for $INSTANCE_ID to run…"
  while :; do
    set -- $(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
               --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text)
    [ "$1" = running ] && [ "$2" != None ] && { IP=$2; break; }
    [ "$1" = terminated ] || [ "$1" = shutting-down ] && die "$INSTANCE_ID went $1 during boot"
    sleep 5
  done
  log "running at $IP; waiting for SSH…"
  until ssh_box "$IP" true 2>/dev/null; do
    [ $(( $(date +%s) - t0 )) -gt 600 ] && die "no SSH after 10 min (security group? key $SSH_KEY?)"; sleep 5
  done
}

# Progress, one line per change: the boot stage, the weight cache growing,
# each slot's container and its last vLLM milestone, until every expected
# slot answers /health. The readiness probe is /health and not /v1/models
# because a keyed box answers 401 to every /v1 path, and a wait on 200 there
# would never finish.
# 200 is a healthy slot. 401 means the slot is up and checking the access key,
# which is just as much "serving" for anything that is only waiting for it.
up_code() { case "$1" in 200|401) return 0 ;; *) return 1 ;; esac; }

wait_serving() {
  local t0 last probe line elapsed want=1
  has_bulk && want=2
  has_decide && want=$((want + 1))
  t0=$(date +%s); last=
  log "following the box (image pull → weights → compile → serve; $want slot(s))"
  probe='st=$(cat /opt/bond/stage 2>/dev/null); mb=$(du -sm /opt/bond/hf 2>/dev/null | cut -f1); out="$st|$mb"; for s in prose bulk decide; do n=vllm-$s; [ $s = decide ] && n=llama-decide; c=$(docker inspect -f "{{.State.Status}}" $n 2>/dev/null); m=$(docker logs $n 2>&1 | grep -E -o "Loading weights took [0-9.]+ s|torch.compile took [0-9.]+ s|GPU KV cache size: [0-9,]+ tokens|Application startup complete|CUDA out of memory|Traceback|ValueError: [^\n]{0,80}|model loaded|server is listening on [^ ]+|failed to load model|error: [^\n]{0,80}" | tail -1); p=8000; [ $s = bulk ] && p=8001; [ $s = decide ] && p=8002; h=$(curl -s -o /dev/null -w "%{http_code}" localhost:$p/health); out="$out|$c|$m|$h"; done; echo "$out"'
  while :; do
    line=$(ssh_box "$IP" "$probe" 2>/dev/null) || line="?|?|?|ssh dropped|000|||000|||000"
    elapsed=$(( ($(date +%s) - t0) / 60 ))
    if [ "$line" != "$last" ]; then
      IFS='|' read -r st mb c1 m1 h1 c2 m2 h2 c3 m3 h3 <<EOF
$line
EOF
      log "$(printf '%3d min  stage=%-13s weights=%5.1f GB  prose=%-8s%s' "$elapsed" "${st:-cloud-init}" "$(awk -v m="${mb:-0}" 'BEGIN{print m/1024}')" "${c1:-none}" "${m1:+ · $m1}")"
      has_bulk && [ -n "${c2:-}" ] && log "$(printf '%3d min  %-13s %-16s bulk=%-8s%s' "$elapsed" "" "" "$c2" "${m2:+ · $m2}")"
      has_decide && [ -n "${c3:-}" ] && log "$(printf '%3d min  %-13s %-16s decide=%-6s%s' "$elapsed" "" "" "$c3" "${m3:+ · $m3}")"
      last=$line
      case "$c1$c2$c3" in *exited*) die "a slot's container exited — on the box: docker logs vllm-prose / vllm-bulk / llama-decide" ;; esac
      if up_code "$h1" && { ! has_bulk || up_code "${h2:-}"; } && { ! has_decide || up_code "${h3:-}"; }; then
        log "serving: prose on the box's :8000$(has_bulk && echo ", bulk on :8001")$(has_decide && echo ", decide on :8002")"; return 0
      fi
    fi
    [ "$elapsed" -ge "$BOOT_TIMEOUT_MIN" ] && die "not serving after $BOOT_TIMEOUT_MIN min — on the box: cat /opt/bond/stage; docker logs vllm-prose"
    sleep "$POLL"
  done
}

# ── test ────────────────────────────────────────────────────────────────
# Four checks any endpoint the app would use must pass, then a throughput
# read: (1) the model is listed, (2) a plain completion answers with usage,
# (3) a json_schema response_format is CONSTRAINED (an enum probe asks for a
# value outside the enum and must get one inside — the same probe as
# app/test/llm_target_verify_test.dart), (4) enable_thinking=false is honoured,
# then tokens/s for one stream and for four at once.
run_test() {  # run_test URL MODEL BEARER
  local url=$1 model=$2 bearer=$3 r content usage n t0 t1 ok=1 tps agg tmp pids i cfg= mcode
  tmp=$(mktemp -d) || die "could not make a temporary directory"
  # The key goes to curl in a 0600 config file, never as an argument: an
  # argument is readable in this machine's process table by anyone on it.
  if [ -n "$bearer" ]; then
    cfg=$(mktemp) && chmod 600 "$cfg" || die "could not make a temporary file for the access key"
    printf 'header = "Authorization: Bearer %s"\n' "$bearer" > "$cfg"
  fi
  # Self-clearing: a RETURN trap outlives the function that set it and would
  # fire again in the caller, where `cfg` and `tmp` are unbound under set -u.
  trap '[ -n "$cfg" ] && rm -f -- "$cfg"; rm -rf -- "$tmp"; trap - RETURN' RETURN
  post() { curl -s --max-time 180 ${cfg:+--config "$cfg"} -H 'Content-Type: application/json' "$url/v1/chat/completions" -d "$1"; }
  body() {  # body PROMPT MAX_TOKENS [EXTRA_JSON]
    jq -n --arg m "$model" --arg p "$1" --argjson n "$2" \
      '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$n, temperature:0.2, chat_template_kwargs:{enable_thinking:false}}'"${3:+ + $3}"
  }
  printf '\n%-28s %s\n' "test: $url" "model $model"
  r=$(curl -s -w '\n%{http_code}' --max-time 15 ${cfg:+--config "$cfg"} "$url/v1/models") || r=
  mcode=${r##*$'\n'}; r=${r%$'\n'*}
  if echo "$r" | jq -e --arg m "$model" '.data[]?|select(.id==$m)' >/dev/null 2>&1; then
    printf '  %-26s %s\n' "models" "ok ($(echo "$r" | jq -r '[.data[].id]|join(", ")'))"
  elif [ "$mcode" = 401 ]; then
    printf '  %-26s %s\n' "models" "401, so the server is up and checking the access key; a completion decides"
  else printf '  %-26s %s\n' "models" "no '$model' in $(echo "$r" | jq -r '[.data[]?.id]|join(", ")' 2>/dev/null || echo 'no listing') (Bedrock has no listing; a completion decides)"; fi

  r=$(post "$(body 'Reply with the single word: ready' 8)")
  content=$(echo "$r" | jq -r '.choices[0].message.content // empty'); usage=$(echo "$r" | jq -c '.usage // empty')
  if [ -n "$content" ] && [ -n "$usage" ]; then printf '  %-26s %s\n' "completion + usage" "ok ('$content', $usage)"
  else ok=0; printf '  %-26s FAIL: %s\n' "completion + usage" "$(echo "$r" | cut -c1-200)"; fi
  case "$content" in *'<think>'*) ok=0; printf '  %-26s FAIL: the answer contains <think>\n' "enable_thinking=false";; *) printf '  %-26s ok\n' "enable_thinking=false";; esac

  r=$(post "$(body 'Answer with the Greek letter zeta.' 16 '{response_format:{type:"json_schema",json_schema:{name:"probe",strict:true,schema:{type:"object",properties:{letter:{type:"string",enum:["alpha","beta","gamma"]}},required:["letter"],additionalProperties:false}}}}')")
  content=$(echo "$r" | jq -r '.choices[0].message.content // empty' | jq -r '.letter // empty' 2>/dev/null)
  case "$content" in alpha|beta|gamma) printf '  %-26s ok (asked for zeta, got %s)\n' "constrained json_schema" "$content";;
    *) ok=0; printf '  %-26s FAIL: got %s\n' "constrained json_schema" "$(echo "$r" | jq -c '.choices[0].message.content // .' | cut -c1-160)";; esac

  [ "$ok" = 1 ] || { printf '  %-26s FAIL (throughput skipped)\n' "result"; rm -rf -- "$tmp"; return 1; }
  t0=$(date +%s); r=$(post "$(body 'Write two paragraphs about how tides work.' 256)"); t1=$(date +%s)
  n=$(echo "$r" | jq -r '.usage.completion_tokens // 0')
  tps=$(awk -v n="$n" -v s="$((t1 - t0))" 'BEGIN{ if (s>0) printf "%.1f", n/s; else print "?" }')
  printf '  %-26s %s tok/s (%s tokens in %ss)\n' "one stream" "$tps" "$n" "$((t1 - t0))"
  t0=$(date +%s); pids=
  for i in 1 2 3 4; do post "$(body 'Write two paragraphs about how tides work.' 256)" | jq -r '.usage.completion_tokens // 0' > "$tmp/$i" & pids="$pids $!"; done
  wait $pids   # only these four — a plain `wait` would also wait on the tunnel
  t1=$(date +%s); n=$(cat "$tmp"/[1-4] | awk '{s+=$1} END{print s+0}'); rm -rf -- "$tmp"
  agg=$(awk -v n="$n" -v s="$((t1 - t0))" 'BEGIN{ if (s>0) printf "%.1f", n/s; else print "?" }')
  printf '  %-26s %s tok/s aggregate (%s tokens in %ss)\n' "four streams" "$agg" "$n" "$((t1 - t0))"
  [ "$ok" = 1 ] && printf '  %-26s PASS\n' "result" || { printf '  %-26s FAIL\n' "result"; return 1; }
}

# The decide slot's checks, the facts the app's DecisionClient relies on:
# (1) /v1/embeddings with embd_normalize -1 answers a 1024-long vector that is
# RAW, not unit length (the client refuses a norm within 1e-3 of 1.0, which is
# what a server that ignored the field would send); (2) /tokenize, with the
# model in the body, answers token ids (the client's path for an over-long
# message). The key goes to curl in a 0600 config file, as in run_test.
run_decide_test() {  # run_decide_test URL MODEL BEARER
  local url=$1 model=$2 bearer=$3 r dim norm ntok ok=1 cfg=
  if [ -n "$bearer" ]; then
    cfg=$(mktemp) && chmod 600 "$cfg" || die "could not make a temporary file for the access key"
    printf 'header = "Authorization: Bearer %s"\n' "$bearer" > "$cfg"
  fi
  trap '[ -n "$cfg" ] && rm -f -- "$cfg"; trap - RETURN' RETURN
  printf '\n%-28s %s\n' "test: $url" "model $model (decision embeddings)"
  r=$(curl -s --max-time 30 ${cfg:+--config "$cfg"} -H 'Content-Type: application/json' "$url/v1/embeddings" \
        -d "$(jq -n --arg m "$model" '{model:$m, input:"hello", embd_normalize:-1}')")
  dim=$(echo "$r" | jq -r '.data[0].embedding | length' 2>/dev/null)
  norm=$(echo "$r" | jq -r '[.data[0].embedding[] | . * .] | add | sqrt' 2>/dev/null)
  if [ "$dim" = 1024 ] && [ -n "$norm" ] && awk -v n="$norm" 'BEGIN{ d = n - 1; if (d < 0) d = -d; exit !(d > 0.001) }'; then
    printf '  %-26s ok (1024 floats, L2 norm %.2f, so raw)\n' "embeddings, raw" "$norm"
  elif [ "$dim" = 1024 ]; then
    ok=0; printf '  %-26s FAIL: norm %s is unit length; the server ignored embd_normalize -1\n' "embeddings, raw" "$norm"
  else
    ok=0; printf '  %-26s FAIL: %s\n' "embeddings, raw" "$( [ -n "$dim" ] && [ "$dim" != null ] && echo "$dim floats, not 1024" || echo "$r" | cut -c1-200)"
  fi
  r=$(curl -s --max-time 30 ${cfg:+--config "$cfg"} -H 'Content-Type: application/json' "$url/tokenize" \
        -d "$(jq -n --arg m "$model" '{model:$m, content:"hello", add_special:false}')")
  ntok=$(echo "$r" | jq -r '.tokens | length' 2>/dev/null)
  if [ -n "$ntok" ] && [ "$ntok" != null ] && [ "$ntok" -gt 0 ] 2>/dev/null; then
    printf '  %-26s ok (%s token(s))\n' "tokenize" "$ntok"
  else
    ok=0; printf '  %-26s FAIL: %s\n' "tokenize" "$(echo "$r" | cut -c1-200)"
  fi
  [ "$ok" = 1 ] && printf '  %-26s PASS\n' "result" || { printf '  %-26s FAIL\n' "result"; return 1; }
}

test_slots() {  # the box's prose slot, then its bulk and decide slots when it has them
  load_state
  run_test "$URL" "${SERVED_NAME:-$SERVED}" "" || return 1
  has_bulk && { run_test "$BULK_URL" "${BULK_SERVED_NAME:-$BULK_SERVED}" "" || return 1; }
  has_decide && { run_decide_test "$DECIDE_URL" "${DECIDE_SERVED_NAME:-$DECIDE_SERVED}" "" || return 1; }
  return 0
}

cmd_test() {
  need jq curl
  if [ -n "$URL" ]; then
    # --bearer-file keeps the key off this command's argv, for the same reason
    # --api-key-file does; tools/model-box.sh test hands it over this way.
    if [ -n "$BEARER_FILE" ]; then
      [ -f "$BEARER_FILE" ] || die "no key file at $BEARER_FILE"
      BEARER=$(tr -d '[:space:]' < "$BEARER_FILE")
    fi
    # With --url, --model is the name the server routes on (default: the alias).
    local m=$SERVED; [ -n "$MODEL_SET" ] && m=$MODEL
    if [ "$TEST_DECIDE" = 1 ]; then
      # --decide: URL is the slot's base (…/decide), not its /v1/embeddings.
      [ -n "$MODEL_SET" ] || m=$DECIDE_SERVED
      [ -n "$m" ] || die "test --url --decide needs the served name: give --model NAME or --decide-served NAME"
      run_decide_test "${URL%/}" "$m" "$BEARER"
    else
      run_test "${URL%/}" "$m" "$BEARER"
    fi
  else
    need aws ssh lsof
    find_instance || die "no endpoint named '$NAME' in [$REGIONS]; give --url for an arbitrary one"
    [ "$STATE" = running ] || die "'$NAME' is $STATE"
    allow_my_ip "$REGION" "$INSTANCE_ID"; ensure_tunnel
    test_slots && next_steps
  fi
}

next_steps() {  # needs URL/BULK_URL; ITYPE / IMODEL / IBULK / *_SERVED_NAME from the box when known
  local served label bserved blabel
  served=${SERVED_NAME:-$SERVED}; label="vllm-${ITYPE:-$TYPE}/$(basename "${IMODEL:-$MODEL}")"
  cat <<EOF

prose: $URL/v1/chat/completions   model: $served
EOF
  has_bulk && { bserved=${BULK_SERVED_NAME:-$BULK_SERVED}; blabel="vllm-${ITYPE:-$TYPE}/$(basename "$IBULK")"
    echo "bulk:  $BULK_URL/v1/chat/completions   model: $bserved"; }
  has_decide && echo "decide: $DECIDE_URL/v1/embeddings   model: ${DECIDE_SERVED_NAME:-$DECIDE_SERVED}   (DECIDE_URL for the app's hand-servers build)"
  if [ -n "$DOMAIN" ]; then
    echo "over TLS, which is the path the app takes:"
    echo "  https://$DOMAIN/prose/v1/chat/completions   model: $served"
    has_bulk && echo "  https://$DOMAIN/bulk/v1/chat/completions    model: ${BULK_SERVED_NAME:-$BULK_SERVED}"
    has_decide && echo "  https://$DOMAIN/decide/v1/embeddings        model: ${DECIDE_SERVED_NAME:-$DECIDE_SERVED}   (the heads file stays on the Mac)"
  fi
  cat <<EOF
(the tunnel closes with '$0 down' or when this machine sleeps; '$0 tunnel' reopens it)
next:
  make bench-verify-prose PROSE_URL=$URL/v1/chat/completions PROSE_MODEL=$served PROSE_LABEL=$label
  make bench-prose        PROSE_URL=$URL/v1/chat/completions PROSE_MODEL=$served PROSE_LABEL=$label
EOF
  has_bulk && cat <<EOF
  make bench              BENCH_URL=$BULK_URL/v1/chat/completions BENCH_MODEL=$bserved BENCH_LABEL=$blabel
  make drain BENCH_K=1,3,6 BENCH_URL=$BULK_URL/v1/chat/completions BENCH_MODEL=$bserved BENCH_LABEL=$blabel
EOF
  echo "  $0 status      $0 extend --days N      $0 restart …      $0 down"
}

# ── status / tunnel / extend / down ─────────────────────────────────────
cmd_status() {
  need aws jq
  whoami_aws
  local r rows found=0 id ip type st launch name model bulk hours price when persist domain decide
  printf '%-10s %-11s %-20s %-12s %-9s %-16s %6s %8s  %-17s %s\n' name region instance type state ip hours '$so-far' shutdown models
  for r in $(echo "$REGIONS" | tr , ' '); do
    rows=$(aws ec2 describe-instances --region "$r" --filters Name=tag-key,Values=bond-inference \
             --query 'Reservations[].Instances[?State.Name!=`terminated`][].[Tags[?Key==`bond-inference`].Value|[0],InstanceId,InstanceType,State.Name,PublicIpAddress,LaunchTime,Tags[?Key==`model`].Value|[0],Tags[?Key==`bulk-model`].Value|[0],Tags[?Key==`persistent`].Value|[0],Tags[?Key==`domain`].Value|[0],Tags[?Key==`decide-model`].Value|[0]]' \
             --output text 2>/dev/null)
    [ -n "$rows" ] || continue
    while read -r name id type st ip launch model bulk persist domain decide; do
      found=1
      hours=$(awk -v l="$(TZ=UTC date -j -f %Y-%m-%dT%H:%M:%S "${launch%%[.+]*}" +%s 2>/dev/null || date -u -d "$launch" +%s)" -v n="$(date +%s)" 'BEGIN{printf "%.1f", (n-l)/3600}')
      price=$(price_for "$type" "$r")
      # A persistent box has no timer, so it is not asked about one.
      # </dev/null: ssh would otherwise read the remaining rows as its stdin.
      if [ "$persist" = 1 ]; then when=persistent
      else when=$( [ "$st" = running ] && [ "$ip" != None ] && ssh_box "$ip" 'u=$(sed -n "s/^USEC=//p" /run/systemd/shutdown/scheduled 2>/dev/null); [ -n "$u" ] && date -u -d @$((u/1000000)) +%Y-%m-%dT%H:%MZ || echo none' 2>/dev/null </dev/null || echo "?"); fi
      printf '%-10s %-11s %-20s %-12s %-9s %-16s %6s %8s  %-17s %s\n' "$name" "$r" "$id" "$type" "$st" "$ip" "$hours" \
        "$( [ "$price" = "?" ] && echo "?" || awk -v h="$hours" -v p="$price" 'BEGIN{printf "%.2f", h*p}')" "$when" \
        "$(basename "$model")$( [ -n "$bulk" ] && [ "$bulk" != None ] && [ "$bulk" != none ] && echo " + $(basename "$bulk")")$( [ -n "$decide" ] && [ "$decide" != None ] && [ "$decide" != none ] && echo " + decide $decide")$( [ -n "$domain" ] && [ "$domain" != None ] && echo " · https://$domain")"
    done <<EOF
$rows
EOF
  done
  [ "$found" = 1 ] || echo "(no bond-inference instances in $REGIONS)"
}

cmd_tunnel() {
  need aws ssh curl lsof
  find_instance || die "no endpoint named '$NAME'"
  [ "$STATE" = running ] || die "'$NAME' is $STATE"
  allow_my_ip "$REGION" "$INSTANCE_ID"; ensure_tunnel
  echo "$URL/v1/chat/completions"; has_bulk && echo "$BULK_URL/v1/chat/completions"
  has_decide && echo "$DECIDE_URL/v1/embeddings"; :
}

cmd_extend() {
  need aws ssh
  local minutes; minutes=$(awk -v d="$DAYS" 'BEGIN { printf "%d", d * 1440 }')
  find_instance || die "no endpoint named '$NAME'"
  [ "$(instance_tag persistent)" = 1 ] && die "'$NAME' is persistent, so it has no timer to move. Use 'down' to end it"
  allow_my_ip "$REGION" "$INSTANCE_ID"
  ssh_box "$IP" "sudo shutdown -c >/dev/null 2>&1; sudo shutdown -h +$minutes 2>&1 | tail -1" || die "could not reach $IP"
}

cmd_down() {
  need aws
  kill_tunnel
  find_instance || { rm -f -- "$(state_file)"; log "nothing named '$NAME' is running"; return 0; }
  local alloc=${ALLOC_ID:-} i=0
  [ -n "$alloc" ] || alloc=$(instance_tag eip)
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'TerminatingInstances[0].CurrentState.Name' --output text | sed "s/^/$(date +%H:%M:%S)  $INSTANCE_ID in $REGION: /"
  # An Elastic IP that is held but attached to nothing is billed by the hour,
  # so the default is to give it back; --keep-ip holds it for the next box.
  if [ -n "$alloc" ] && [ "$KEEP_IP" = 1 ]; then
    log "kept the Elastic IP $alloc; an address held but not attached is billed"
  elif [ -n "$alloc" ]; then
    until aws ec2 release-address --region "$REGION" --allocation-id "$alloc" >/dev/null 2>&1; do
      i=$((i + 1))
      [ "$i" -ge 12 ] && { log "could not release the Elastic IP $alloc; release it by hand or it keeps billing"; break; }
      sleep 5
    done
    [ "$i" -lt 12 ] && log "released the Elastic IP $alloc"
  fi
  rm -f -- "$(state_file)"
  log "the root volume goes with it; key pair bond-inference and SG bond-inference-ssh stay (free)"
}

# Convert a RUNNING box into an always-on keyed HTTPS endpoint, in place: the
# timer goes, the web group is attached, an Elastic IP replaces the address the
# box was given at boot, the A record follows, the key reaches both slots and
# Caddy takes 443. The public IP changes here, so any open tunnel is closed
# first and `tunnel` reopens it against the new address.
cmd_persist() {
  need aws jq ssh curl
  [ -n "$DOMAIN" ] || die "persist needs --domain HOST, the hostname the app will use"
  need dig
  local want_domain=$DOMAIN
  whoami_aws
  find_instance || die "no endpoint named '$NAME' in [$REGIONS]"
  DOMAIN=$want_domain
  [ "$STATE" = running ] || die "'$NAME' is $STATE, and persist converts a running box"
  allow_my_ip "$REGION" "$INSTANCE_ID"
  read_api_key
  [ -n "$API_KEY" ] || die "persist needs --api-key-file FILE or --api-key KEY: on a public hostname the key is the only credential"
  log "persist: $NAME becomes https://$DOMAIN"
  ssh_box "$IP" 'sudo shutdown -c' >/dev/null 2>&1 || :
  log "the self-termination timer is cancelled; this box now runs until 'down' ends it"
  aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" \
    --tags Key=persistent,Value=1 "Key=domain,Value=$DOMAIN" >/dev/null \
    || die "could not tag $INSTANCE_ID as persistent in $REGION"
  ensure_web_sg "$REGION"
  local groups
  # --groups REPLACES the instance's list, so an unread or empty answer here
  # would send the web group alone and take port 22 off the box. Both the
  # failure and the empty list are fatal.
  groups=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
             --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text) \
    || die "could not read the security groups of $INSTANCE_ID"
  [ -n "$(echo $groups)" ] \
    || die "no security group came back for $INSTANCE_ID; refusing to replace its list with $WEB_SG alone"

  # --output text separates with TABS, so the list is re-split on whitespace
  # before it is matched or extended. --groups REPLACES the list, so every group
  # the box already has goes back in, each exactly once: a duplicate id is
  # rejected, and a second persist would otherwise send one.
  local g uniq=
  for g in $groups $WEB_SG; do
    case " $uniq " in *" $g "*) : ;; *) uniq="$uniq $g" ;; esac
  done
  groups=$(echo $uniq)
  aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$INSTANCE_ID" --groups $groups \
    || die "could not attach $WEB_SG to $INSTANCE_ID"
  log "security groups on the box: $groups"
  kill_tunnel
  ensure_eip "$REGION" "$NAME"
  dns_note "$IP"
  if key_unchanged "$IP"; then
    log "the key is unchanged; the slots keep running"
  else
    push_api_key "$IP"
    restart_slots "$IP"
  fi
  install_caddy "$IP"
  save_state DOMAIN "$DOMAIN"
  wait_https
  test_https || die "the endpoint is up but a check above failed"
  persist_next_steps
}

# ── args ────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || usage 1
CMD=$1; shift
while [ $# -gt 0 ]; do
  case "$1" in
    # A name reaches a state file path, an AWS tag filter and the log, so it
    # is held to letters, digits, dash and underscore at the door.
    --name) NAME=$2
      case "$NAME" in ''|*[!A-Za-z0-9_-]*) die "--name takes letters, digits, dash and underscore only" ;; esac
      shift ;;
    --type) TYPE=$2; shift ;;
    --days) DAYS=$2; shift ;;        --model) MODEL=$2 MODEL_SET=1; shift ;;
    --served-name) SERVED=$2; shift ;; --image) IMAGE=$2; shift ;;
    --max-len) MAXLEN=$2; shift ;;   --mem) MEM=$2; shift ;;
    --mtp) MTP=$2; shift ;;          --vllm-args) VLLM_ARGS=$2; shift ;;
    --extra-args) EXTRA_ARGS=$2; shift ;;
    --bulk-model) BULK_MODEL=$2 BULK_MODEL_SET=1; shift ;; --bulk-served) BULK_SERVED=$2; shift ;;
    --bulk-max-len) BULK_MAXLEN=$2; shift ;; --bulk-mem) BULK_MEM=$2; shift ;;
    --bulk-args) BULK_ARGS=$2; shift ;;
    --decide-gguf) DECIDE_GGUF=$2 DECIDE_SET=1; shift ;;
    --decide-served) DECIDE_SERVED=$2 DECIDE_SERVED_SET=1; shift ;;
    --decide-image) DECIDE_IMAGE=$2; shift ;; --decide) TEST_DECIDE=1 ;;
    --disk) DISK=$2; shift ;;        --regions) REGIONS=$2; shift ;;
    --profile) PROFILE=$2; shift ;;  --account) ACCOUNT=$2; shift ;;
    --spot) SPOT=1 ;;                --ssh-key) SSH_KEY=$2; shift ;;
    --port) PORT=$2; shift ;;        --url) URL=$2; shift ;;
    --bearer) BEARER=$2; shift ;;  --bearer-file) BEARER_FILE=$2; shift ;;
    --persistent) PERSISTENT=1 ;;    --domain) DOMAIN=$2; shift ;;
    --api-key) API_KEY=$2; shift ;;  --api-key-file) API_KEY_FILE=$2; shift ;;
    --route53-zone) ROUTE53_ZONE=$2; shift ;; --acme-email) ACME_EMAIL=$2; shift ;;
    --keep-ip) KEEP_IP=1 ;;      --force) FORCE=1 ;;
    -h|--help) usage ;;
    *) die "unknown option $1 (see --help)" ;;
  esac; shift
done
# --decide-gguf none drops the slot (restart); a path names the file the box
# will serve. Its name reaches a remote shell, a docker mount and a tag, so it
# is held to a plain file name ending in .gguf; the heads JSON is refused
# because it never leaves the Mac.
case "$DECIDE_GGUF" in
  '') ;;
  none) DECIDE_GGUF= DECIDE_FILE= ;;
  *) DECIDE_FILE=$(basename "$DECIDE_GGUF"); check_decide_file "$DECIDE_FILE" --decide-gguf ;;
esac
# No --decide-served: a file given here names its own slot.
[ -z "$DECIDE_SERVED_SET" ] && [ -n "$DECIDE_FILE" ] && DECIDE_SERVED=$(served_from_file "$DECIDE_FILE")
[ -n "$DECIDE_SERVED_SET" ] && [ -z "$DECIDE_SERVED" ] && die "--decide-served takes a name"
case "$DECIDE_SERVED" in *[!A-Za-z0-9._-]*) die "--decide-served takes letters, digits, dot, dash and underscore only" ;; esac
case "$CMD" in
  up) cmd_up ;; restart) cmd_restart ;; status) cmd_status ;; test) cmd_test ;; tunnel) cmd_tunnel ;;
  extend) cmd_extend ;; down) cmd_down ;; persist) cmd_persist ;; -h|--help|help) usage ;;
  userdata) userdata ;;   # print the boot script `up` would send, for a dry read
  *) die "unknown command $CMD (up|restart|persist|status|test|tunnel|extend|down)" ;;
esac
