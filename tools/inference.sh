#!/usr/bin/env bash
# tools/inference.sh — vLLM inference endpoints on an AWS GPU instance, in
# one command each: stand a box up, watch it boot, test it, reach it through
# an SSH tunnel, reconfigure it in place, extend its life, tear it down. The
# `test` half also works on any OpenAI-compatible endpoint (a local
# llama-server, Bedrock, an old box).
#
#   tools/inference.sh up      [--type g6e.xlarge] [--days 1] [--model REPO] [--bulk-model REPO]
#                              [--regions a,b,c] [--profile P] [--account ID] [--spot] [--mtp N] [--name NAME] …
#   tools/inference.sh restart [--name NAME] [the same model options]   push a new configuration to a running box
#                            (models not given are kept from the box; --bulk-model none drops the slot)
#   tools/inference.sh status  [--name NAME]              every box this script manages
#   tools/inference.sh test    [--name NAME | --url URL --model NAME [--bearer KEY]]
#   tools/inference.sh tunnel  [--name NAME] [--port N]   local URLs for PROSE_URL / BENCH_URL
#   tools/inference.sh extend  --days D [--name NAME]     move the self-termination timer
#   tools/inference.sh down    [--name NAME] [--keep-ip]   terminate; the key pair and SG stay
#   tools/inference.sh persist --domain HOST --api-key-file FILE [--route53-zone ZONE]
#                              [--acme-email YOU] [--name NAME]
#                            turn a running box into an always-on keyed HTTPS endpoint
#
# A box serves one or two SLOTS, mirroring the app's two servers: `prose`
# (--model, the 27B, the box's :8000) and an optional `bulk` (--bulk-model,
# the 4B, :8001). Each is its own vLLM container with its own share of the
# GPU (--mem / --bulk-mem); the shares are chosen so the pair fits one L40S.
#
# PERSISTENT MODE. `up --domain HOST …` builds an always-on box, and `persist`
# converts a running one in place. Either way Caddy takes 443 on one hostname
# and forwards /prose/ and /bulk/ to the two slots on the box's loopback, vLLM
# checks an api-key on both, and an Elastic IP keeps the name pointing at the
# box across a stop and start. A hostname implies --persistent, because a box
# the app points at must not walk away mid-session: a persistent box has no
# self-termination timer, so `down` is what ends it, and `extend` refuses.
# Its options: --persistent, --domain HOST, --api-key KEY or --api-key-file
# FILE, --route53-zone ZONE to write the A record, --acme-email YOU for the
# certificate notices, --keep-ip to keep the address after the box goes down.
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
# box adds Caddy on 443 and an api-key on both slots, and then the key is the
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
DISK=200
REGIONS=us-west-2,us-east-2,us-east-1
PROFILE=
ACCOUNT=
SPOT=0
SSH_KEY=$HOME/.ssh/id_ed25519
PORT=
URL=
BEARER=
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
  local r=$1 sg=${SG:-} ip
  [ -n "${2:-}" ] && sg=$(aws ec2 describe-instances --region "$r" --instance-ids "$2" \
                           --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
  ip=$(my_ip); [ -n "$ip" ] || die "could not learn this machine's public IP"
  allow_ingress "$r" "$sg" 22 "$ip/32"
}

# The instance behind NAME: the state file first (fast), then a tag scan of
# every region in --regions. Sets REGION INSTANCE_ID IP ITYPE STATE IMODEL IBULK.
find_instance() {
  load_state
  local r q; q='Reservations[].Instances[?State.Name!=`terminated`&&State.Name!=`shutting-down`][].[InstanceId,PublicIpAddress,InstanceType,State.Name,Tags[?Key==`model`].Value|[0],Tags[?Key==`bulk-model`].Value|[0]]'
  if [ -n "${REGION:-}" ] && [ -n "${INSTANCE_ID:-}" ]; then
    set -- $(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query "$q" --output text 2>/dev/null)
    [ $# -ge 4 ] && { INSTANCE_ID=$1 IP=$2 ITYPE=$3 STATE=$4 IMODEL=${5:-} IBULK=${6:-}; return 0; }
  fi
  for r in $(echo "$REGIONS" | tr , ' '); do
    set -- $(aws ec2 describe-instances --region "$r" --filters "Name=tag:bond-inference,Values=$NAME" --query "$q" --output text 2>/dev/null)
    [ $# -ge 4 ] && { REGION=$r INSTANCE_ID=$1 IP=$2 ITYPE=$3 STATE=$4 IMODEL=${5:-} IBULK=${6:-}; save_state REGION "$r"; save_state INSTANCE_ID "$1"; return 0; }
  done
  return 1
}
# `none` is what cmd_restart writes to the tag when a slot is dropped, and None
# is what the AWS CLI prints for a tag that was never set.
has_bulk() { [ -n "${IBULK:-}" ] && [ "$IBULK" != None ] && [ "$IBULK" != none ]; }

free_port() {  # two adjacent free ports, for the two slots
  local p; for p in $(seq "$PORT_FROM" $((PORT_FROM + 98))); do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && continue
    lsof -nP -iTCP:"$((p + 1))" -sTCP:LISTEN >/dev/null 2>&1 && continue
    echo "$p"; return
  done; die "no free local port pair in $PORT_FROM..$((PORT_FROM + 99))"
}

# A background `ssh -N -L` to the box's two slot ports; re-used while it lives.
ensure_tunnel() {  # needs IP; sets PORT, URL, BULK_URL
  load_state
  if [ -n "${TUNNEL_PID:-}" ] && kill -0 "$TUNNEL_PID" 2>/dev/null && [ -n "${TUNNEL_PORT:-}" ] \
     && curl -s --max-time 5 -o /dev/null "http://localhost:$TUNNEL_PORT/health"; then
    PORT=$TUNNEL_PORT
  else
    [ -n "$PORT" ] || PORT=$(free_port)
    nohup ssh -N -L "$PORT:127.0.0.1:8000" -L "$((PORT + 1)):127.0.0.1:8001" \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o LogLevel=ERROR -i "$SSH_KEY" "$SSH_USER@$IP" >/dev/null 2>&1 &
    TUNNEL_PID=$!
    local i=0; until curl -s --max-time 3 -o /dev/null "http://localhost:$PORT/health"; do
      kill -0 "$TUNNEL_PID" 2>/dev/null || die "ssh to $IP failed (security group, key $SSH_KEY, or the box is down: $0 status)"
      i=$((i + 1)); [ $i -gt 30 ] && die "tunnel on :$PORT is up but vLLM on the box does not answer; on the box: docker logs vllm-prose"; sleep 2
    done
    save_state TUNNEL_PID "$TUNNEL_PID"; save_state TUNNEL_PORT "$PORT"
    log "tunnel: localhost:$PORT → $IP:8000 (prose), localhost:$((PORT + 1)) → :8001 (bulk) (pid $TUNNEL_PID)"
  fi
  URL="http://localhost:$PORT"; BULK_URL="http://localhost:$((PORT + 1))"
}

kill_tunnel() { load_state; [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null && log "tunnel closed"; :; }

# ── the box's configuration ─────────────────────────────────────────────
# One env file per slot and one serve.sh that (re)starts a slot's container:
#   /opt/bond/serve.sh prose            /opt/bond/serve.sh bulk --some-flag
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
  else
    printf 'MODEL=%s\nSERVED=%s\nPORT=8001\nMAXLEN=%s\nMEM=%s\nARGS=%s\n' \
      "$BULK_MODEL" "$BULK_SERVED" "$BULK_MAXLEN" "$BULK_MEM" "$(sq "$BULK_ARGS")"
  fi
}
# The part of the boot that is also a reconfiguration: write the slot files
# and serve.sh, start prose, wait for it, start bulk. Runs as root on the box.
box_setup() {
  cat <<EOF
mkdir -p /opt/bond/hf
cat > /opt/bond/prose.env <<'ENV'
$(slot_env prose)
ENV
rm -f /opt/bond/bulk.env
EOF
  [ -n "$BULK_MODEL" ] && cat <<EOF
cat > /opt/bond/bulk.env <<'ENV'
$(slot_env bulk)
ENV
EOF
  cat <<EOF
cat > /opt/bond/serve.sh <<'SERVE'
#!/bin/bash
# /opt/bond/serve.sh SLOT [extra vllm flags] — (re)start one slot's container.
slot=\${1:-prose}; shift 2>/dev/null || true
. /opt/bond/\$slot.env
# The api-key a persistent box checks, as an env file rather than a flag: a
# flag would show in the box's process table. The value is still readable in
# `docker inspect` .Config.Env, on a box only the operator can reach.
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
echo started > /opt/bond/stage
EOF
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

# handle_path strips the prefix, so vLLM sees /v1/… . flush_interval -1 is load
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
  --env-file /opt/bond/caddy.env caddy:2 validate --config /etc/caddy/Caddyfile --adapter caddyfile
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
  log "caddy is up; https://$DOMAIN/prose and https://$DOMAIN/bulk are the two slots"
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

# Both slots again, so they read a key file written after they started. The
# milestones and the wait are wait_serving's, exactly as on a boot.
restart_slots() {  # restart_slots IP
  local ip=$1
  log "restarting both slots so they read the access key"
  cat <<'RS' | ssh_box "$ip" 'sudo mkdir -p /opt/bond; sudo bash -c "cat > /opt/bond/restart-slots.sh"; sudo nohup bash /opt/bond/restart-slots.sh >/dev/null 2>&1 &' \
    || die "could not restart the slots on $ip"
set -uxo pipefail
exec >> /var/log/bond-inference.log 2>&1
docker rm -f vllm vllm-prose vllm-bulk 2>/dev/null || true
echo restarting > /opt/bond/stage
/opt/bond/serve.sh prose
for i in $(seq 1 240); do curl -s -o /dev/null localhost:8000/health && break; sleep 5; done
if [ -f /opt/bond/bulk.env ]; then echo serving-bulk > /opt/bond/stage; /opt/bond/serve.sh bulk; fi
echo started > /opt/bond/stage
RS
  wait_serving
}

# Caddy binds 443 before its first ACME order has finished, so the fallback
# route is what says the endpoint is really ready: a 200 with no key, on a path
# that reaches no model.
wait_https() {
  local i=0 code
  log "waiting for the certificate on https://$DOMAIN, up to five minutes"
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null)
    [ "$code" = 200 ] && { log "https://$DOMAIN answers 200; the certificate is in place"; return 0; }
    i=$((i + 1))
    [ $((i * POLL)) -ge 300 ] && die "https://$DOMAIN did not answer 200 within five minutes; on the box, docker logs caddy"
    sleep "$POLL"
  done
}

test_https() {  # both slots through the front door, with the key
  load_state
  run_test "https://$DOMAIN/prose" "${SERVED_NAME:-$SERVED}" "$API_KEY" || return 1
  has_bulk && { run_test "https://$DOMAIN/bulk" "${BULK_SERVED_NAME:-$BULK_SERVED}" "$API_KEY" || return 1; }
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
  cat <<EOF
the access key is what a tester types in the app. It is not printed here and
it belongs in no committed file.
next:
  $0 test --url https://$DOMAIN/prose --bearer <key> --model $served
EOF
  has_bulk && echo "  $0 test --url https://$DOMAIN/bulk --bearer <key> --model ${BULK_SERVED_NAME:-$BULK_SERVED}"
  echo "  $0 status      $0 down      $0 tunnel is still the operator's own path"
}

# ── up / restart ────────────────────────────────────────────────────────
describe_box() { echo "$MODEL as '$SERVED'${BULK_MODEL:+ + bulk $BULK_MODEL as '$BULK_SERVED'}"; }

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
  local ud r ami out gpu bulk_tag= domain_tag= sgids=
  [ -n "$BULK_MODEL" ] && bulk_tag=",{Key=bulk-model,Value=$BULK_MODEL}"
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
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=bond-inference-$NAME},{Key=bond-inference,Value=$NAME},{Key=project,Value=bond-desktop},{Key=model,Value=$MODEL}$bulk_tag,{Key=persistent,Value=$PERSISTENT}$domain_tag]" \
            --query 'Instances[0].[InstanceId,Placement.AvailabilityZone]' --output text 2>&1)
    case "$out" in
      i-*) set -- $out; REGION=$r INSTANCE_ID=$1
           log "$r: launched $INSTANCE_ID in $2"; break ;;
      *InsufficientInstanceCapacity*|*"no Spot capacity"*|*"Insufficient capacity"*)
           log "$r: no $TYPE capacity right now"; INSTANCE_ID= ;;
      *)   die "$r: $out" ;;
    esac
  done
  rm -f "$ud"
  [ -n "${INSTANCE_ID:-}" ] || die "no region in [$REGIONS] had $TYPE capacity; retry later, try --spot, another --type, or more --regions"
  rm -f "$(state_file)"
  save_state REGION "$REGION"; save_state INSTANCE_ID "$INSTANCE_ID"; save_state SERVED_NAME "$SERVED"
  [ -n "$BULK_MODEL" ] && save_state BULK_SERVED_NAME "$BULK_SERVED"
  ITYPE=$TYPE IMODEL=$MODEL IBULK=$BULK_MODEL
  wait_instance
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
  allow_my_ip "$REGION" "$INSTANCE_ID"
  log "restart $NAME ($INSTANCE_ID, $IP): $(describe_box)"
  { echo "set -uxo pipefail; exec >> /var/log/bond-inference.log 2>&1"
    echo "docker rm -f vllm vllm-prose vllm-bulk 2>/dev/null; echo restarting > /opt/bond/stage"
    box_setup; } | ssh_box "$IP" 'sudo mkdir -p /opt/bond; sudo bash -c "cat > /opt/bond/restart.sh"; sudo nohup bash /opt/bond/restart.sh >/dev/null 2>&1 &' \
    || die "could not push the configuration to $IP"
  aws ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" --tags "Key=model,Value=$MODEL" "Key=bulk-model,Value=${BULK_MODEL:-none}"
  save_state SERVED_NAME "$SERVED"
  if [ -n "$BULK_MODEL" ]; then save_state BULK_SERVED_NAME "$BULK_SERVED"; else save_state BULK_SERVED_NAME ""; fi
  ITYPE=$ITYPE IMODEL=$MODEL IBULK=$BULK_MODEL
  wait_serving
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
  t0=$(date +%s); last=
  log "following the box (image pull → weights → compile → serve; $want slot(s))"
  probe='st=$(cat /opt/bond/stage 2>/dev/null); mb=$(du -sm /opt/bond/hf 2>/dev/null | cut -f1); out="$st|$mb"; for s in prose bulk; do c=$(docker inspect -f "{{.State.Status}}" vllm-$s 2>/dev/null); m=$(docker logs vllm-$s 2>&1 | grep -E -o "Loading weights took [0-9.]+ s|torch.compile took [0-9.]+ s|GPU KV cache size: [0-9,]+ tokens|Application startup complete|CUDA out of memory|Traceback|ValueError: [^\n]{0,80}" | tail -1); p=8000; [ $s = bulk ] && p=8001; h=$(curl -s -o /dev/null -w "%{http_code}" localhost:$p/health); out="$out|$c|$m|$h"; done; echo "$out"'
  while :; do
    line=$(ssh_box "$IP" "$probe" 2>/dev/null) || line="?|?|?|ssh dropped|000|||000"
    elapsed=$(( ($(date +%s) - t0) / 60 ))
    if [ "$line" != "$last" ]; then
      IFS='|' read -r st mb c1 m1 h1 c2 m2 h2 <<EOF
$line
EOF
      log "$(printf '%3d min  stage=%-13s weights=%5.1f GB  prose=%-8s%s' "$elapsed" "${st:-cloud-init}" "$(awk -v m="${mb:-0}" 'BEGIN{print m/1024}')" "${c1:-none}" "${m1:+ · $m1}")"
      [ "$want" = 2 ] && [ -n "${c2:-}" ] && log "$(printf '%3d min  %-13s %-16s bulk=%-8s%s' "$elapsed" "" "" "$c2" "${m2:+ · $m2}")"
      last=$line
      case "$c1$c2" in *exited*) die "a vLLM container exited — on the box: docker logs vllm-prose / vllm-bulk" ;; esac
      if up_code "$h1" && { [ "$want" = 1 ] || up_code "${h2:-}"; }; then
        log "serving: prose on the box's :8000${IBULK:+, bulk on :8001}"; return 0
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
  tmp=$(mktemp -d)
  # The key goes to curl in a 0600 config file, never as an argument: an
  # argument is readable in this machine's process table by anyone on it.
  if [ -n "$bearer" ]; then
    cfg=$(mktemp) && chmod 600 "$cfg" || die "could not make a temporary file for the access key"
    printf 'header = "Authorization: Bearer %s"\n' "$bearer" > "$cfg"
  fi
  # Self-clearing: a RETURN trap outlives the function that set it and would
  # fire again in the caller, where `cfg` and `tmp` are unbound under set -u.
  trap '[ -n "$cfg" ] && rm -f "$cfg"; rm -rf "$tmp"; trap - RETURN' RETURN
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

  [ "$ok" = 1 ] || { printf '  %-26s FAIL (throughput skipped)\n' "result"; rm -rf "$tmp"; return 1; }
  t0=$(date +%s); r=$(post "$(body 'Write two paragraphs about how tides work.' 256)"); t1=$(date +%s)
  n=$(echo "$r" | jq -r '.usage.completion_tokens // 0')
  tps=$(awk -v n="$n" -v s="$((t1 - t0))" 'BEGIN{ if (s>0) printf "%.1f", n/s; else print "?" }')
  printf '  %-26s %s tok/s (%s tokens in %ss)\n' "one stream" "$tps" "$n" "$((t1 - t0))"
  t0=$(date +%s); pids=
  for i in 1 2 3 4; do post "$(body 'Write two paragraphs about how tides work.' 256)" | jq -r '.usage.completion_tokens // 0' > "$tmp/$i" & pids="$pids $!"; done
  wait $pids   # only these four — a plain `wait` would also wait on the tunnel
  t1=$(date +%s); n=$(cat "$tmp"/[1-4] | awk '{s+=$1} END{print s+0}'); rm -rf "$tmp"
  agg=$(awk -v n="$n" -v s="$((t1 - t0))" 'BEGIN{ if (s>0) printf "%.1f", n/s; else print "?" }')
  printf '  %-26s %s tok/s aggregate (%s tokens in %ss)\n' "four streams" "$agg" "$n" "$((t1 - t0))"
  [ "$ok" = 1 ] && printf '  %-26s PASS\n' "result" || { printf '  %-26s FAIL\n' "result"; return 1; }
}

test_slots() {  # the box's prose slot, then its bulk slot when it has one
  load_state
  run_test "$URL" "${SERVED_NAME:-$SERVED}" "" || return 1
  has_bulk && { run_test "$BULK_URL" "${BULK_SERVED_NAME:-$BULK_SERVED}" "" || return 1; }
  return 0
}

cmd_test() {
  need jq curl
  if [ -n "$URL" ]; then
    # With --url, --model is the name the server routes on (default: the alias).
    local m=$SERVED; [ -n "$MODEL_SET" ] && m=$MODEL
    run_test "${URL%/}" "$m" "$BEARER"
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
  if [ -n "$DOMAIN" ]; then
    echo "over TLS, which is the path the app takes:"
    echo "  https://$DOMAIN/prose/v1/chat/completions   model: $served"
    has_bulk && echo "  https://$DOMAIN/bulk/v1/chat/completions    model: ${BULK_SERVED_NAME:-$BULK_SERVED}"
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
  local r rows found=0 id ip type st launch name model bulk hours price when persist domain
  printf '%-10s %-11s %-20s %-12s %-9s %-16s %6s %8s  %-17s %s\n' name region instance type state ip hours '$so-far' shutdown models
  for r in $(echo "$REGIONS" | tr , ' '); do
    rows=$(aws ec2 describe-instances --region "$r" --filters Name=tag-key,Values=bond-inference \
             --query 'Reservations[].Instances[?State.Name!=`terminated`][].[Tags[?Key==`bond-inference`].Value|[0],InstanceId,InstanceType,State.Name,PublicIpAddress,LaunchTime,Tags[?Key==`model`].Value|[0],Tags[?Key==`bulk-model`].Value|[0],Tags[?Key==`persistent`].Value|[0],Tags[?Key==`domain`].Value|[0]]' \
             --output text 2>/dev/null)
    [ -n "$rows" ] || continue
    while read -r name id type st ip launch model bulk persist domain; do
      found=1
      hours=$(awk -v l="$(TZ=UTC date -j -f %Y-%m-%dT%H:%M:%S "${launch%%[.+]*}" +%s 2>/dev/null || date -u -d "$launch" +%s)" -v n="$(date +%s)" 'BEGIN{printf "%.1f", (n-l)/3600}')
      price=$(price_for "$type" "$r")
      # A persistent box has no timer, so it is not asked about one.
      # </dev/null: ssh would otherwise read the remaining rows as its stdin.
      if [ "$persist" = 1 ]; then when=persistent
      else when=$( [ "$st" = running ] && [ "$ip" != None ] && ssh_box "$ip" 'u=$(sed -n "s/^USEC=//p" /run/systemd/shutdown/scheduled 2>/dev/null); [ -n "$u" ] && date -u -d @$((u/1000000)) +%Y-%m-%dT%H:%MZ || echo none' 2>/dev/null </dev/null || echo "?"); fi
      printf '%-10s %-11s %-20s %-12s %-9s %-16s %6s %8s  %-17s %s\n' "$name" "$r" "$id" "$type" "$st" "$ip" "$hours" \
        "$( [ "$price" = "?" ] && echo "?" || awk -v h="$hours" -v p="$price" 'BEGIN{printf "%.2f", h*p}')" "$when" \
        "$(basename "$model")$( [ -n "$bulk" ] && [ "$bulk" != None ] && [ "$bulk" != none ] && echo " + $(basename "$bulk")")$( [ -n "$domain" ] && [ "$domain" != None ] && echo " · https://$domain")"
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
  find_instance || { rm -f "$(state_file)"; log "nothing named '$NAME' is running"; return 0; }
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
  rm -f "$(state_file)"
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
    --tags Key=persistent,Value=1 "Key=domain,Value=$DOMAIN" >/dev/null
  ensure_web_sg "$REGION"
  local groups
  groups=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
             --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)
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
  push_api_key "$IP"
  restart_slots "$IP"
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
    --name) NAME=$2; shift ;;        --type) TYPE=$2; shift ;;
    --days) DAYS=$2; shift ;;        --model) MODEL=$2 MODEL_SET=1; shift ;;
    --served-name) SERVED=$2; shift ;; --image) IMAGE=$2; shift ;;
    --max-len) MAXLEN=$2; shift ;;   --mem) MEM=$2; shift ;;
    --mtp) MTP=$2; shift ;;          --vllm-args) VLLM_ARGS=$2; shift ;;
    --extra-args) EXTRA_ARGS=$2; shift ;;
    --bulk-model) BULK_MODEL=$2 BULK_MODEL_SET=1; shift ;; --bulk-served) BULK_SERVED=$2; shift ;;
    --bulk-max-len) BULK_MAXLEN=$2; shift ;; --bulk-mem) BULK_MEM=$2; shift ;;
    --bulk-args) BULK_ARGS=$2; shift ;;
    --disk) DISK=$2; shift ;;        --regions) REGIONS=$2; shift ;;
    --profile) PROFILE=$2; shift ;;  --account) ACCOUNT=$2; shift ;;
    --spot) SPOT=1 ;;                --ssh-key) SSH_KEY=$2; shift ;;
    --port) PORT=$2; shift ;;        --url) URL=$2; shift ;;
    --bearer) BEARER=$2; shift ;;
    --persistent) PERSISTENT=1 ;;    --domain) DOMAIN=$2; shift ;;
    --api-key) API_KEY=$2; shift ;;  --api-key-file) API_KEY_FILE=$2; shift ;;
    --route53-zone) ROUTE53_ZONE=$2; shift ;; --acme-email) ACME_EMAIL=$2; shift ;;
    --keep-ip) KEEP_IP=1 ;;
    -h|--help) usage ;;
    *) die "unknown option $1 (see --help)" ;;
  esac; shift
done
case "$CMD" in
  up) cmd_up ;; restart) cmd_restart ;; status) cmd_status ;; test) cmd_test ;; tunnel) cmd_tunnel ;;
  extend) cmd_extend ;; down) cmd_down ;; persist) cmd_persist ;; -h|--help|help) usage ;;
  userdata) userdata ;;   # print the boot script `up` would send, for a dry read
  *) die "unknown command $CMD (up|restart|persist|status|test|tunnel|extend|down)" ;;
esac
