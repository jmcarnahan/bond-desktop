#!/usr/bin/env bash
# tools/model-box.sh — the app's two models on a GPU box INSIDE a platform VPC,
# reached at a path on the platform's own hostname through its existing
# internal ALB: https://<host>/models/prose and https://<host>/models/bulk.
# The design and the reasons are in docs/model-box-platform.md.
#
#   tools/model-box.sh preflight              read-only: every check the launch depends on
#   tools/model-box.sh up [--days 14] [--type T] [model options]
#                                             launch, route /models/* to it, follow the boot
#   tools/model-box.sh watch                  follow the boot until both slots serve
#   tools/model-box.sh status                 the box, its deadline, the target's health
#   tools/model-box.sh test                   both slots through the ALB, with the key
#   tools/model-box.sh key --out FILE         the access key into a 0600 file, for the app
#   tools/model-box.sh extend --days D        move the deadline to D days from now
#   tools/model-box.sh shell                  an SSM session on the box
#   tools/model-box.sh down [--purge]         remove the rule and target group, terminate
#
# Every option: --config FILE (default ./model-box.env), --name NAME (default
# `default`), --days D, --type T, --disk GB, --api-key-file FILE (seed the key
# instead of generating one), --out FILE, --purge. Model options are handed to
# `tools/inference.sh userdata` unchanged: --model, --served-name, --bulk-model
# (`none` drops the bulk slot), --bulk-served, --image, --mtp, --max-len,
# --mem, --bulk-mem, --bulk-max-len, --vllm-args, --extra-args, --bulk-args.
#
# Why a second script and not a mode of inference.sh: that one builds a PUBLIC
# box in a default VPC and reaches it over SSH from the operator's IP. This one
# builds a PRIVATE box in a subnet somebody else owns, behind a listener
# somebody else owns, under that account's SCPs, and reaches it through SSM.
# The two share the box recipe itself: this script's user data embeds the
# output of `tools/inference.sh userdata`, so the slots, serve.sh and the
# vLLM flags have one source.
#
# The environment — account, region, subnet, listener, hostname, AMI, the tags
# the account's SCPs require — is read from the config file, which is
# git-ignored (*.env). tools/model-box.env.example lists every variable. This
# repo is public: real values never go in a tracked file.
#
# What it creates, all named bond-models-<name> and tagged with the config's
# BOX_TAGS: an IAM role and instance profile (SSM, plus read on the one key
# secret), a security group (80 from the ALB's groups only), a Secrets Manager
# secret holding the access key, the instance, a target group and one listener
# rule. `down` removes the rule, the target group and the instance; `--purge`
# also removes the role, the group and the secret.
#
# The box ends itself: a systemd timer compares the clock with the deadline in
# /opt/bond/deadline every ten minutes and powers off once it has passed, and
# the instance is launched to TERMINATE on shutdown. A timer rather than
# `shutdown -h +N` because a scheduled shutdown does not survive a reboot, and
# a box under a patching regime can be rebooted. `down` is still what removes
# the rule and the target group; a box that ended itself leaves them pointing
# at nothing, which answers 503 on the path.
set -u

# ── defaults ────────────────────────────────────────────────────────────
NAME=default
CONFIG=
DAYS=
TYPE=
DISK=
API_KEY_FILE=
OUT=
PURGE=0
RECIPE_ARGS=()
BULK_GIVEN=0
# The 4B beside the 27B, because the app sends extraction to the small model
# and a box without it leaves the bulk address answering nothing.
DEFAULT_BULK=Qwen/Qwen3-4B-Instruct-2507-FP8
POLL=30
BOOT_TIMEOUT_MIN=60

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# ── plumbing ────────────────────────────────────────────────────────────
log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'model-box: %s\n' "$*" >&2; exit 1; }
need() { for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "needs $b on PATH"; done; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
aws()  { command aws --no-cli-pager ${BOX_PROFILE:+--profile "$BOX_PROFILE"} --region "$BOX_REGION" "$@"; }

# An epoch as an ISO minute, with the date(1) this machine has.
iso() { date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ; }
deadline_for() { awk -v d="$1" -v n="$(date +%s)" 'BEGIN { printf "%d", n + d * 86400 }'; }

load_config() {
  [ -n "$CONFIG" ] || CONFIG=$ROOT/model-box.env
  [ -f "$CONFIG" ] || die "no config at $CONFIG; copy tools/model-box.env.example there and fill it in"
  # shellcheck disable=SC1090
  . "$CONFIG"
  local v; for v in BOX_REGION BOX_ACCOUNT BOX_SUBNET BOX_LISTENER_ARN BOX_HOST; do
    [ -n "${!v:-}" ] || die "$v is not set in $CONFIG"
  done
  [ -n "${BOX_AMI:-}" ] || { [ -n "${BOX_AMI_OWNER:-}" ] && [ -n "${BOX_AMI_NAME:-}" ]; } \
    || die "set BOX_AMI, or BOX_AMI_OWNER and BOX_AMI_NAME, in $CONFIG"
  : "${BOX_PROFILE:=}" "${BOX_TAGS:=}" "${BOX_PATH:=/models}" "${BOX_RULE_PRIORITY:=95}"
  : "${BOX_TYPE:=g6e.xlarge}" "${BOX_DISK:=200}" "${BOX_DAYS:=14}"
  [ -n "$TYPE" ] || TYPE=$BOX_TYPE
  [ -n "$DISK" ] || DISK=$BOX_DISK
  [ -n "$DAYS" ] || DAYS=$BOX_DAYS
  case "$BOX_PATH" in /*[!/]) ;; *) die "BOX_PATH must start with / and not end with one (it is '$BOX_PATH')" ;; esac
  PREFIX=bond-models-$NAME
  SECRET_NAME=bond-models/$NAME/api-key
  BASE_URL=https://$BOX_HOST$BOX_PATH
}

whoami_aws() {
  local acct; acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || die "no AWS credentials${BOX_PROFILE:+ for profile $BOX_PROFILE}"
  [ "$acct" = "$BOX_ACCOUNT" ] || die "signed in to account $acct, not $BOX_ACCOUNT"
  log "aws account $acct${BOX_PROFILE:+ (profile $BOX_PROFILE)}, $BOX_REGION"
}

# BOX_TAGS is `key=value,key=value`: the tags the account's SCPs insist on,
# put on every resource this script makes. Values may not hold a comma.
tags_json() {  # tags_json [KEY=VALUE…] → a JSON list of {Key,Value}, BOX_TAGS first
  { printf '%s\n' "$BOX_TAGS" | tr ',' '\n'; printf '%s\n' "Name=$PREFIX" "bond-models=$NAME" "project=bond-desktop" "$@"; } \
    | grep '=' | jq -R -s -c 'split("\n") | map(select(length > 0) | capture("^(?<Key>[^=]+)=(?<Value>.*)$"))'
}

price_for() {  # on-demand $/h from the pricing API; "?" when not permitted
  command aws --no-cli-pager ${BOX_PROFILE:+--profile "$BOX_PROFILE"} pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$1" "Type=TERM_MATCH,Field=regionCode,Value=$BOX_REGION" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --query 'PriceList[0]' --output text 2>/dev/null \
    | jq -r '.terms.OnDemand[]?.priceDimensions[]?.pricePerUnit.USD' 2>/dev/null | head -1 | grep . | awk '{printf "%.2f", $1}' || echo "?"
}

# ── the environment, read from the account ──────────────────────────────
# BOX_SUBNET may list several subnets, comma-separated, in different zones:
# GPU capacity runs out one zone at a time, and `up` tries them in order.
use_subnet() {  # use_subnet SUBNET → sets SUBNET VPC AZ
  set -- "$1" $(aws ec2 describe-subnets --subnet-ids "$1" --query 'Subnets[0].[VpcId,AvailabilityZone]' --output text 2>/dev/null)
  [ $# -eq 3 ] || die "subnet $1 not found in $BOX_REGION"
  [ -z "${VPC:-}" ] || [ "$VPC" = "$2" ] || die "the subnets in BOX_SUBNET are in different VPCs ($VPC, $2)"
  SUBNET=$1 VPC=$2 AZ=$3
}
# Sets SUBNETS, the first subnet's SUBNET VPC AZ, and ALB_ARN ALB_SGS AMI ROOT_DEV.
resolve_env() {
  SUBNETS=$(echo "$BOX_SUBNET" | tr ',' ' ')
  local s; for s in $SUBNETS; do use_subnet "$s"; done
  use_subnet "${SUBNETS%% *}"
  ALB_ARN=$(aws elbv2 describe-listeners --listener-arns "$BOX_LISTENER_ARN" --query 'Listeners[0].LoadBalancerArn' --output text 2>/dev/null)
  [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != None ] || die "listener $BOX_LISTENER_ARN not found"
  ALB_SGS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].SecurityGroups' --output text)
  [ -n "$(echo $ALB_SGS)" ] || die "the ALB behind the listener has no security groups to allow port 80 from"
  if [ -n "${BOX_AMI:-}" ]; then AMI=$BOX_AMI
  else
    AMI=$(aws ec2 describe-images --owners "$BOX_AMI_OWNER" --filters "Name=name,Values=$BOX_AMI_NAME" Name=state,Values=available \
            --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null)
    [ -n "$AMI" ] && [ "$AMI" != None ] || die "no available image named '$BOX_AMI_NAME' from owner $BOX_AMI_OWNER"
  fi
  ROOT_DEV=$(aws ec2 describe-images --image-ids "$AMI" --query 'Images[0].RootDeviceName' --output text)
}

# The instance behind NAME, if any: sets INSTANCE_ID STATE PRIVATE_IP.
find_instance() {
  set -- $(aws ec2 describe-instances --filters "Name=tag:bond-models,Values=$NAME" \
             "Name=instance-state-name,Values=pending,running,stopping,stopped" \
             --query 'Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress]' --output text 2>/dev/null)
  [ $# -ge 2 ] || return 1
  INSTANCE_ID=$1 STATE=$2 PRIVATE_IP=${3:-}
}
instance_tag() {  # instance_tag KEY → one tag off the instance, empty when unset
  local v; v=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
                 --query "Reservations[0].Instances[0].Tags[?Key=='$1'].Value|[0]" --output text 2>/dev/null)
  [ "$v" = None ] && v=; printf '%s' "$v"
}
tg_arn() {
  local a; a=$(aws elbv2 describe-target-groups --names "$PREFIX" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || a=
  [ "$a" = None ] && a=; printf '%s' "$a"
}
# The listener rule whose path is ours, whoever it forwards to.
rule_for_path() {  # → "RULE_ARN PRIORITY TARGET_ARN", empty when none
  aws elbv2 describe-rules --listener-arn "$BOX_LISTENER_ARN" --output json 2>/dev/null \
    | jq -r --arg p "$BOX_PATH/*" '.Rules[] | select([.Conditions[]?.Values[]?, .Conditions[]?.PathPatternConfig.Values[]?] | index($p))
        | "\(.RuleArn) \(.Priority) \(.Actions[0].TargetGroupArn // "-")"' | head -1
}

# ── the box's boot ──────────────────────────────────────────────────────
# The slot recipe comes from inference.sh so the two builders cannot drift;
# `--persistent` because this box's lifetime is the deadline timer below, not
# inference.sh's `shutdown -h +N`.
recipe() {
  local args=("${RECIPE_ARGS[@]+"${RECIPE_ARGS[@]}"}")
  [ "$BULK_GIVEN" = 1 ] || args+=(--bulk-model "$DEFAULT_BULK")
  "$ROOT/tools/inference.sh" userdata --persistent ${args[@]+"${args[@]}"}
}
# One value out of one slot's env file in the rendered recipe.
recipe_value() {  # recipe_value FILE KEY  (FILE is prose.env or bulk.env)
  printf '%s\n' "$RECIPE" | awk -v f="/opt/bond/$1" -v k="$2" '
    index($0, "cat > " f " <<") == 1 { on = 1; next }
    on && $0 == "ENV" { on = 0 }
    on && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

userdata() {  # userdata DEADLINE_EPOCH SECRET_ARN
  cat <<EOF
#!/bin/bash
set -uo pipefail
exec > /var/log/bond-model-box.log 2>&1
mkdir -p /opt/bond
stage() { echo "\$1" > /opt/bond/stage; echo "== \$1"; }
fail()  { stage "failed:\$1"; exit 1; }
stage preparing

# The deadline, checked by a timer so a reboot cannot lose it. The instance
# terminates on shutdown, so powering off is the end of the box.
echo $1 > /opt/bond/deadline
cat > /opt/bond/deadline.sh <<'SH'
#!/bin/sh
d=\$(cat /opt/bond/deadline 2>/dev/null)
[ -n "\$d" ] && [ "\$(date +%s)" -ge "\$d" ] && exec /usr/sbin/shutdown -h now
exit 0
SH
chmod +x /opt/bond/deadline.sh
cat > /etc/systemd/system/bond-deadline.service <<'U'
[Unit]
Description=Power the model box off once its deadline has passed
[Service]
Type=oneshot
ExecStart=/opt/bond/deadline.sh
U
cat > /etc/systemd/system/bond-deadline.timer <<'U'
[Unit]
Description=Check the model box's deadline
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
U
systemctl daemon-reload
systemctl enable --now bond-deadline.timer

# Docker and the NVIDIA runtime. The account's approved GPU image carries the
# driver; Docker and the container toolkit are installed when it does not.
stage docker
command -v docker >/dev/null || dnf install -y docker || fail docker-install
systemctl enable --now docker || fail docker-start
nvidia-smi -L || fail no-gpu-driver
if ! docker info 2>/dev/null | grep -qi 'runtimes:.*nvidia'; then
  if ! command -v nvidia-ctk >/dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \\
      -o /etc/yum.repos.d/nvidia-container-toolkit.repo || fail toolkit-repo
    dnf install -y nvidia-container-toolkit || fail toolkit-install
  fi
  nvidia-ctk runtime configure --runtime=docker || fail toolkit-configure
  systemctl restart docker || fail docker-restart
fi

# The access key, from Secrets Manager through the instance role. Tracing
# stays off here so the value is never written to the log.
stage key
command -v aws >/dev/null || dnf install -y awscli || fail awscli
KEY=\$(aws secretsmanager get-secret-value --region $BOX_REGION --secret-id '$2' --query SecretString --output text) || fail key
( umask 077; printf 'VLLM_API_KEY=%s\n' "\$KEY" > /opt/bond/api.env )
unset KEY

# Caddy on :80 only: the ALB terminates TLS and cannot rewrite paths, so the
# prefix is stripped here. flush_interval -1 keeps streamed drafts streaming.
stage caddy
mkdir -p /opt/bond/caddy/data /opt/bond/caddy/config
cat > /opt/bond/Caddyfile <<'CF'
:80 {
	handle_path $BOX_PATH/prose/* {
		reverse_proxy 127.0.0.1:8000 {
			flush_interval -1
		}
	}
	handle_path $BOX_PATH/bulk/* {
		reverse_proxy 127.0.0.1:8001 {
			flush_interval -1
		}
	}
	handle {
		respond "bond models" 200
	}
}
CF
docker rm -f caddy 2>/dev/null
docker run -d --name caddy --restart unless-stopped --network host \\
  -v /opt/bond/Caddyfile:/etc/caddy/Caddyfile:ro \\
  -v /opt/bond/caddy/data:/data -v /opt/bond/caddy/config:/config caddy:2 || fail caddy

# After a reboot the slots come back through this unit: serve.sh starts its
# containers without a restart policy, and a box that lives two weeks will
# see one.
cat > /opt/bond/start-slots.sh <<'SH'
#!/bin/bash
/opt/bond/serve.sh prose
for i in \$(seq 1 240); do curl -s -o /dev/null localhost:8000/health && break; sleep 10; done
[ -f /opt/bond/bulk.env ] && /opt/bond/serve.sh bulk
echo started > /opt/bond/stage
SH
chmod +x /opt/bond/start-slots.sh
cat > /etc/systemd/system/bond-slots.service <<'U'
[Unit]
Description=The model box's vLLM slots
After=docker.service network-online.target
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/opt/bond/start-slots.sh
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
systemctl enable bond-slots.service

# The slot recipe, exactly as tools/inference.sh renders it.
cat > /opt/bond/recipe.sh <<'RECIPE'
$RECIPE
RECIPE
bash /opt/bond/recipe.sh
EOF
}

# The launch, as an argument list shared by preflight's dry run and `up`, so
# what preflight proves is what up sends. Sets RUN.
run_args() {  # run_args UDFILE SG PROFILE TAGS_EXTRA… (SG / PROFILE may be empty)
  local ud=$1 sg=$2 profile=$3; shift 3
  local tags spec
  tags=$(tags_json "$@")
  spec=$(jq -c -n --argjson t "$tags" '[{ResourceType:"instance",Tags:$t},{ResourceType:"volume",Tags:$t},{ResourceType:"network-interface",Tags:$t}]')
  RUN=(ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" --subnet-id "$SUBNET"
       --no-associate-public-ip-address --instance-initiated-shutdown-behavior terminate
       --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2
       --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEV\",\"Ebs\":{\"VolumeSize\":$DISK,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]"
       --tag-specifications "$spec")
  [ -n "$ud" ] && RUN+=(--user-data "file://$ud")
  [ -n "$sg" ] && RUN+=(--security-group-ids "$sg")
  [ -n "$profile" ] && RUN+=(--iam-instance-profile "Name=$profile")
  :
}

# An explicit deny from an SCP names the one resource and condition that
# failed; this reads the encoded message so preflight can say which.
explain_deny() {  # explain_deny ERROR_TEXT
  local m; m=$(printf '%s' "$1" | sed -n 's/.*Encoded authorization failure message: //p')
  [ -n "$m" ] || { printf '%s' "$1" | tail -c 300; return; }
  aws sts decode-authorization-message --encoded-message "$m" --query DecodedMessage --output text 2>/dev/null \
    | jq -r '"denied on \(.context.resource)"' 2>/dev/null || echo "denied (the message could not be decoded)"
}

# ── the pieces around the instance ──────────────────────────────────────
ensure_secret() {  # sets SECRET_ARN; the value never reaches argv or the log
  local tmp arn
  arn=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --query ARN --output text 2>/dev/null) || arn=
  if [ -n "$arn" ] && [ -z "$API_KEY_FILE" ]; then SECRET_ARN=$arn; log "access key: re-using secret $SECRET_NAME"; return; fi
  tmp=$(mktemp) && chmod 600 "$tmp" || die "could not make a temporary file for the key"
  if [ -n "$API_KEY_FILE" ]; then
    [ -f "$API_KEY_FILE" ] || { rm -f "$tmp"; die "no key file at $API_KEY_FILE"; }
    tr -d '[:space:]' < "$API_KEY_FILE" > "$tmp"
  else
    openssl rand -hex 32 | tr -d '\n' > "$tmp"
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; die "the access key came out empty"; }
  if [ -n "$arn" ]; then
    aws secretsmanager put-secret-value --secret-id "$arn" --secret-string "file://$tmp" >/dev/null \
      || { rm -f "$tmp"; die "could not update the secret $SECRET_NAME"; }
    SECRET_ARN=$arn; log "access key: secret $SECRET_NAME now holds the key from $API_KEY_FILE"
  else
    SECRET_ARN=$(aws secretsmanager create-secret --name "$SECRET_NAME" --description "Access key for the bond model box '$NAME'" \
                   --secret-string "file://$tmp" --tags "$(tags_json)" --query ARN --output text) \
      || { rm -f "$tmp"; die "could not create the secret $SECRET_NAME"; }
    log "access key: created secret $SECRET_NAME${API_KEY_FILE:+ from $API_KEY_FILE}"
  fi
  rm -f "$tmp"
}

ensure_role() {  # the instance role: SSM for the operator, the one secret for the box
  local trust policy
  if ! aws iam get-role --role-name "$PREFIX" >/dev/null 2>&1; then
    trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam create-role --role-name "$PREFIX" --assume-role-policy-document "$trust" \
      --description "The bond model box '$NAME': SSM, and read on its one access-key secret" --tags "$(tags_json)" >/dev/null \
      || die "could not create the role $PREFIX"
    log "created role $PREFIX"
  fi
  aws iam attach-role-policy --role-name "$PREFIX" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
    || die "could not attach AmazonSSMManagedInstanceCore to $PREFIX"
  policy=$(jq -c -n --arg a "$SECRET_ARN" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"secretsmanager:GetSecretValue",Resource:$a}]}')
  aws iam put-role-policy --role-name "$PREFIX" --policy-name access-key --policy-document "$policy" \
    || die "could not give $PREFIX read on the key secret"
  if ! aws iam get-instance-profile --instance-profile-name "$PREFIX" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$PREFIX" --tags "$(tags_json)" >/dev/null \
      || die "could not create the instance profile $PREFIX"
    aws iam add-role-to-instance-profile --instance-profile-name "$PREFIX" --role-name "$PREFIX" \
      || die "could not put $PREFIX into its instance profile"
    log "created instance profile $PREFIX"
  fi
}

ensure_sg() {  # sets SG: port 80 from the ALB's groups and from nothing else
  local g err
  SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$PREFIX" "Name=vpc-id,Values=$VPC" \
         --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$SG" = None ]; then
    SG=$(aws ec2 create-security-group --group-name "$PREFIX" --vpc-id "$VPC" \
           --description "The bond model box: HTTP from the platform ALB only" \
           --tag-specifications "$(jq -c -n --argjson t "$(tags_json)" '[{ResourceType:"security-group",Tags:$t}]')" \
           --query GroupId --output text) || die "could not create the security group $PREFIX"
    log "created security group $SG"
  fi
  for g in $ALB_SGS; do
    err=$(aws ec2 authorize-security-group-ingress --group-id "$SG" \
            --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$g,Description=platform ALB}]" 2>&1 >/dev/null) \
      || case "$err" in *InvalidPermission.Duplicate*) ;; *) die "could not open 80 from $g on $SG: $err" ;; esac
  done
}

ensure_target() {  # the target group, the box registered in it, and the rule
  local tg rule
  tg=$(aws elbv2 create-target-group --name "$PREFIX" --protocol HTTP --port 80 --vpc-id "$VPC" --target-type ip \
         --health-check-protocol HTTP --health-check-path "$BOX_PATH/prose/health" --matcher HttpCode=200 \
         --health-check-interval-seconds 30 --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
         --tags "$(tags_json)" --query 'TargetGroups[0].TargetGroupArn' --output text) \
    || die "could not create the target group $PREFIX"
  aws elbv2 modify-target-group-attributes --target-group-arn "$tg" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
  aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$PRIVATE_IP,Port=80" \
    || die "could not register $PRIVATE_IP in $PREFIX"
  log "target group $PREFIX: $PRIVATE_IP:80, health $BOX_PATH/prose/health"
  set -- $(rule_for_path)
  if [ $# -ge 1 ]; then
    [ "$3" = "$tg" ] || die "the listener already routes $BOX_PATH/* (priority $2) to something else; refusing to take it"
    log "listener rule for $BOX_PATH/* already in place (priority $2)"
  else
    rule=$(aws elbv2 create-rule --listener-arn "$BOX_LISTENER_ARN" --priority "$BOX_RULE_PRIORITY" \
             --conditions "$(jq -c -n --arg a "$BOX_PATH" --arg b "$BOX_PATH/*" '[{Field:"path-pattern",PathPatternConfig:{Values:[$a,$b]}}]')" \
             --actions "Type=forward,TargetGroupArn=$tg" --tags "$(tags_json)" --query 'Rules[0].RuleArn' --output text) \
      || die "could not add the listener rule at priority $BOX_RULE_PRIORITY"
    log "listener rule: $BOX_PATH and $BOX_PATH/* → $PREFIX, priority $BOX_RULE_PRIORITY"
  fi
}

# ── SSM, the operator's only way onto the box ───────────────────────────
ssm_run() {  # ssm_run CMD → stdout of CMD on the box; fails while SSM cannot reach it
  local id status i=0
  id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
         --parameters "$(jq -c -n --arg c "$1" '{commands:[$c]}')" --query Command.CommandId --output text 2>/dev/null) || return 1
  while :; do
    sleep 2
    status=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null) || status=Pending
    case "$status" in Pending|InProgress|Delayed) ;; *) break ;; esac
    i=$((i + 1)); [ $i -gt 30 ] && return 1
  done
  aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
  [ "$status" = Success ]
}

# ── commands ────────────────────────────────────────────────────────────
cmd_preflight() {
  need aws jq
  load_config; whoami_aws
  local fails=0 vcpu quota nat r ud sgid prof=
  ok()   { printf '  %-24s ok    %s\n' "$1" "$2"; }
  warn() { printf '  %-24s WARN  %s\n' "$1" "$2"; }
  bad()  { printf '  %-24s FAIL  %s\n' "$1" "$2"; fails=$((fails + 1)); }
  resolve_env
  echo
  local s; for s in $SUBNETS; do
    use_subnet "$s"
    ok subnet "$SUBNET in $AZ, $VPC"
    [ "$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
           --filters "Name=instance-type,Values=$TYPE" "Name=location,Values=$AZ" --query 'length(InstanceTypeOfferings)' --output text)" = 1 ] \
      && ok "$TYPE offered" "in $AZ" || bad "$TYPE offered" "not in $AZ; pick a subnet in another zone"
    nat=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[NatGatewayId,TransitGatewayId]|[0]' --output text 2>/dev/null)
    case "$nat" in nat-*|*tgw-*) ok egress "0.0.0.0/0 via $(echo $nat | tr ' ' '\n' | grep -v None | head -1)";; *) bad egress "no default route from $SUBNET; the box must pull an image and weights";; esac
  done
  use_subnet "${SUBNETS%% *}"
  vcpu=$(aws ec2 describe-instance-types --instance-types "$TYPE" --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --query 'Quota.Value' --output text 2>/dev/null | cut -d. -f1)
  if [ -z "$quota" ]; then warn "G-instance quota" "could not be read"
  elif [ "$quota" -ge "$vcpu" ]; then ok "G-instance quota" "$quota vCPUs, $TYPE needs $vcpu"
  else bad "G-instance quota" "$quota vCPUs, $TYPE needs $vcpu"; fi
  ok "ALB" "$(basename "$(dirname "$ALB_ARN")"), groups $(echo $ALB_SGS)"
  aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
    --query 'Attributes[?Key==`idle_timeout.timeout_seconds`].Value|[0]' --output text | {
      read -r t; if [ "${t:-60}" -ge 300 ]; then ok "ALB idle timeout" "${t}s"
      else warn "ALB idle timeout" "${t}s: a completion that sends nothing for that long is cut (504)"; fi; }
  set -- $(rule_for_path)
  if [ $# -ge 1 ]; then
    [ "$3" = "$(tg_arn)" ] && ok "path $BOX_PATH/*" "already ours (priority $2)" || bad "path $BOX_PATH/*" "already routed by priority $2"
  else ok "path $BOX_PATH/*" "free"; fi
  if ! aws elbv2 describe-rules --listener-arn "$BOX_LISTENER_ARN" --query 'Rules[].Priority' --output text \
       | tr '\t' '\n' | grep -qx "$BOX_RULE_PRIORITY"; then ok "priority $BOX_RULE_PRIORITY" "free"
  elif [ $# -ge 1 ] && [ "$2" = "$BOX_RULE_PRIORITY" ]; then ok "priority $BOX_RULE_PRIORITY" "ours"
  else bad "priority $BOX_RULE_PRIORITY" "taken; set BOX_RULE_PRIORITY"; fi
  ok image "$AMI ($(aws ec2 describe-images --image-ids "$AMI" --query 'Images[0].Name' --output text))"
  for r in ssm ssmmessages ec2messages; do
    aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" "Name=service-name,Values=com.amazonaws.$BOX_REGION.$r" \
      --query 'length(VpcEndpoints)' --output text | grep -qv '^0$' && continue
    warn "SSM endpoints" "no $r endpoint; SSM then goes through NAT"; break
  done
  # The dry run carries everything the real launch will, bar the pieces `up`
  # creates: a missing group or profile is left out rather than failed on.
  sgid=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$PREFIX" "Name=vpc-id,Values=$VPC" \
           --query 'SecurityGroups[0].GroupId' --output text); [ "$sgid" = None ] && sgid=
  prof=; aws iam get-instance-profile --instance-profile-name "$PREFIX" >/dev/null 2>&1 && prof=$PREFIX
  ud=$(mktemp); RECIPE=$(recipe) || die "tools/inference.sh userdata failed"
  userdata "$(deadline_for "$DAYS")" "arn:aws:secretsmanager:$BOX_REGION:$BOX_ACCOUNT:secret:$SECRET_NAME" > "$ud"
  run_args "$ud" "$sgid" "$prof" "expires=preflight"
  r=$(aws "${RUN[@]}" --dry-run 2>&1); rm -f "$ud"
  case "$r" in *DryRunOperation*) ok "launch (dry run)" "the account's policies allow it$([ -z "$sgid$prof" ] && echo "; group and profile not made yet, so not in the run")";;
    *) bad "launch (dry run)" "$(explain_deny "$r")";; esac
  echo
  [ "$fails" = 0 ] && log "preflight: ready. Capacity at launch time is the one thing a dry run cannot check." \
                   || die "preflight: $fails check(s) failed"
}

cmd_up() {
  need aws jq openssl
  load_config; whoami_aws
  find_instance && die "'$NAME' is already $STATE ($INSTANCE_ID). '$0 status', or '$0 down' first"
  resolve_env
  local deadline ud out i price
  RECIPE=$(recipe) || die "tools/inference.sh userdata failed"
  MODEL=$(recipe_value prose.env MODEL); SERVED=$(recipe_value prose.env SERVED)
  BULK=$(recipe_value bulk.env MODEL); BULK_SERVED=$(recipe_value bulk.env SERVED)
  deadline=$(deadline_for "$DAYS")
  price=$(price_for "$TYPE")
  log "up: $TYPE in $(echo $SUBNETS | wc -w | tr -d ' ') subnet(s) · $MODEL as '$SERVED'${BULK:+ + $BULK as '$BULK_SERVED'} · until $(iso "$deadline") ($DAYS days) · $price USD/h on demand"
  ensure_secret; ensure_role; ensure_sg
  ud=$(mktemp); userdata "$deadline" "$SECRET_ARN" > "$ud"
  local s; out=
  for s in $SUBNETS; do
    use_subnet "$s"
    run_args "$ud" "$SG" "$PREFIX" "expires=$(iso "$deadline")" "model=$MODEL" "served=$SERVED" \
      "bulk-model=${BULK:-none}" "bulk-served=${BULK_SERVED:-none}"
    log "trying $TYPE in $AZ ($SUBNET)…"
    # A profile made seconds ago is not yet visible to EC2; that one error is
    # retried for a minute. No capacity moves on to the next subnet, and
    # every other error is fatal.
    for i in $(seq 1 12); do
      out=$(aws "${RUN[@]}" --query 'Instances[0].InstanceId' --output text 2>&1) && break
      case "$out" in
        *"Invalid IAM Instance Profile"*|*iamInstanceProfile*) sleep 5 ;;
        *InsufficientInstanceCapacity*|*"sufficient"*"capacity"*) log "$AZ: no $TYPE capacity right now"; break ;;
        *) rm -f "$ud"; die "launch failed: $(explain_deny "$out")" ;;
      esac
    done
    case "$out" in i-*) break ;; esac
  done
  rm -f "$ud"
  case "$out" in i-*) INSTANCE_ID=$out ;; *) die "no subnet in BOX_SUBNET had $TYPE capacity; retry later, add a subnet in another zone, or --type g6e.2xlarge" ;; esac
  log "launched $INSTANCE_ID in $AZ"
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" || die "$INSTANCE_ID did not reach running"
  PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  log "running at $PRIVATE_IP"
  ensure_target
  cmd_watch
}

cmd_watch() {
  need aws jq
  [ -n "${BOX_REGION:-}" ] || load_config
  find_instance || die "no box named '$NAME'"
  local t0 last= line elapsed st mb p b c m tg health want=1
  [ "$(instance_tag bulk-model)" = none ] || want=2
  tg=$(tg_arn); t0=$(date +%s)
  log "following $INSTANCE_ID (docker → key → caddy → image → weights → serve); a cold boot is 15–30 minutes"
  while :; do
    line=$(ssm_run 'st=$(cat /opt/bond/stage 2>/dev/null); mb=$(du -sm /opt/bond/hf 2>/dev/null | cut -f1); p=$(curl -s -o /dev/null -w "%{http_code}" localhost:8000/health); b=$(curl -s -o /dev/null -w "%{http_code}" localhost:8001/health); c=$(docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" " "); m=$(docker logs vllm-prose 2>&1 | grep -E -o "Loading weights took [0-9.]+ s|torch.compile took [0-9.]+ s|Application startup complete|CUDA out of memory|Traceback" | tail -1); echo "$st|${mb:-0}|$p|$b|$c|$m"' 2>/dev/null) \
      || line="ssm not answering yet|0|000|000||"
    health=$([ -n "$tg" ] && aws elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null)
    line="$line|${health:-none}"
    elapsed=$(( ($(date +%s) - t0) / 60 ))
    if [ "$line" != "$last" ]; then
      IFS='|' read -r st mb p b c m health <<EOF
$line
EOF
      log "$(printf '%3d min  stage=%-14s weights=%5.1f GB  prose=%s bulk=%s  alb=%s%s' "$elapsed" "${st:-cloud-init}" \
             "$(awk -v m="${mb:-0}" 'BEGIN{print m/1024}')" "$p" "$b" "$health" "${m:+ · $m}")"
      last=$line
      case "$st" in failed:*) die "the boot stopped at ${st#failed:}. On the box ('$0 shell'): tail -50 /var/log/bond-model-box.log" ;; esac
    fi
    if [ "$p" = 200 ] && { [ "$want" = 1 ] || [ "$b" = 200 ]; } && [ "$health" = healthy ]; then
      log "serving: $BASE_URL/prose$([ "$want" = 2 ] && echo " and $BASE_URL/bulk")"
      next_steps; return 0
    fi
    [ "$elapsed" -ge "$BOOT_TIMEOUT_MIN" ] && die "not serving after $BOOT_TIMEOUT_MIN min; '$0 shell', then tail /var/log/bond-model-box.log /var/log/bond-inference.log"
    sleep "$POLL"
  done
}

next_steps() {
  cat <<EOF

the app, on a machine that reaches $BOX_HOST:
  BOND_BOX_URL=$BASE_URL                       in .env, then rebuild
  $0 key --out ~/model-box.key                 the access key, typed once into Settings → Models
check both slots through the ALB:
  $0 test
  $0 status      $0 extend --days N      $0 down
EOF
}

cmd_status() {
  need aws jq
  load_config; whoami_aws
  local tg rule hours price launch
  if find_instance; then
    launch=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].LaunchTime' --output text)
    hours=$(awk -v l="$(TZ=UTC date -j -f %Y-%m-%dT%H:%M:%S "${launch%%[.+]*}" +%s 2>/dev/null || date -u -d "$launch" +%s)" -v n="$(date +%s)" 'BEGIN{printf "%.1f", (n-l)/3600}')
    price=$(price_for "$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].InstanceType' --output text)")
    printf '  %-14s %s (%s), %s\n' box "$INSTANCE_ID" "$STATE" "${PRIVATE_IP:-no address}"
    printf '  %-14s %s + %s\n' models "$(instance_tag model)" "$(instance_tag bulk-model)"
    printf '  %-14s %s h, %s USD so far\n' up "$hours" "$( [ "$price" = "?" ] && echo "?" || awk -v h="$hours" -v p="$price" 'BEGIN{printf "%.2f", h*p}')"
    printf '  %-14s %s (the box powers itself off then)\n' ends "$(instance_tag expires)"
  else
    printf '  %-14s none running\n' box
  fi
  tg=$(tg_arn)
  if [ -n "$tg" ]; then
    printf '  %-14s %s\n' target "$(aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text | tr '\t' ' ' | head -1)"
  fi
  set -- $(rule_for_path)
  [ $# -ge 1 ] && printf '  %-14s %s/* at priority %s\n' rule "$BOX_PATH" "$2"
  printf '  %-14s %s\n' url "$BASE_URL"
  if [ -z "${INSTANCE_ID:-}" ] && { [ -n "$tg" ] || [ $# -ge 1 ]; }; then
    echo "  the box is gone but the rule and target group are not; '$0 down' removes them"
  fi
}

# The key leaves Secrets Manager only into a 0600 file or curl's config file.
fetch_key() {  # fetch_key FILE
  ( umask 077; aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text > "$1" ) \
    || die "could not read the secret $SECRET_NAME"
}

cmd_key() {
  need aws
  [ -n "$OUT" ] || die "key needs --out FILE; the key is never printed"
  load_config
  [ -e "$OUT" ] && die "$OUT already exists; remove it or pick another path"
  fetch_key "$OUT"
  log "the access key is in $OUT (mode 600). Type it into the app once, then delete the file."
}

cmd_test() {
  need aws jq curl
  load_config
  find_instance || die "no box named '$NAME'"
  local k; k=$(mktemp) || die "could not make a temporary file"
  fetch_key "$k"
  "$ROOT/tools/inference.sh" test --url "$BASE_URL/prose" --model "$(instance_tag served)" --bearer-file "$k"; local rc=$?
  if [ "$(instance_tag bulk-model)" != none ]; then
    "$ROOT/tools/inference.sh" test --url "$BASE_URL/bulk" --model "$(instance_tag bulk-served)" --bearer-file "$k" || rc=1
  fi
  rm -f -- "$k"
  return $rc
}

cmd_extend() {
  need aws jq
  load_config
  find_instance || die "no box named '$NAME'"
  local d; d=$(deadline_for "$DAYS")
  ssm_run "echo $d > /opt/bond/deadline" >/dev/null || die "could not reach $INSTANCE_ID through SSM"
  aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=expires,Value=$(iso "$d")"
  log "$INSTANCE_ID now powers itself off at $(iso "$d")"
}

cmd_shell() {
  need aws session-manager-plugin
  load_config
  find_instance || die "no box named '$NAME'"
  exec command aws ${BOX_PROFILE:+--profile "$BOX_PROFILE"} --region "$BOX_REGION" ssm start-session --target "$INSTANCE_ID"
}

cmd_down() {
  need aws jq
  load_config; whoami_aws
  local tg; tg=$(tg_arn)
  set -- $(rule_for_path)
  if [ $# -ge 1 ]; then
    # Ours when it forwards to our target group. When that group is already
    # gone (a half-finished down, or one deleted by hand) the forward proves
    # nothing, so the rule's own tag decides: create-rule tags it
    # bond-models=$NAME, and a rule without that tag belongs to somebody else
    # even though it sits on our path. Such a rule is left and logged, and
    # teardown carries on: a rule we do not own must never stop the instance
    # from terminating, because the box bills by the hour.
    local ours=1
    if [ -z "$tg" ] || [ "$3" != "$tg" ]; then
      local owner
      owner=$(aws elbv2 describe-tags --resource-arns "$1" \
                --query "TagDescriptions[0].Tags[?Key=='bond-models'].Value|[0]" --output text 2>/dev/null)
      if [ "$owner" != "$NAME" ]; then
        ours=0
        log "the rule on $BOX_PATH/* (priority $2) is not ours: it forwards elsewhere and is not tagged bond-models=$NAME; leaving it"
      fi
    fi
    [ "$ours" = 1 ] && aws elbv2 delete-rule --rule-arn "$1" && log "removed the listener rule for $BOX_PATH/*"
  fi
  [ -n "$tg" ] && aws elbv2 delete-target-group --target-group-arn "$tg" && log "removed target group $PREFIX"
  if find_instance; then
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null && log "terminating $INSTANCE_ID; its volume and weights go with it"
  else
    log "no instance named '$NAME' to terminate"
  fi
  [ "$PURGE" = 1 ] || { log "kept (free): role, instance profile and security group $PREFIX, secret $SECRET_NAME. --purge removes them"; return 0; }
  [ -n "${INSTANCE_ID:-}" ] && { log "waiting for the instance to go, so its group can"; aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"; }
  resolve_env
  local sg; sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$PREFIX" "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text)
  [ "$sg" != None ] && aws ec2 delete-security-group --group-id "$sg" && log "removed security group $sg"
  aws iam remove-role-from-instance-profile --instance-profile-name "$PREFIX" --role-name "$PREFIX" 2>/dev/null
  aws iam delete-instance-profile --instance-profile-name "$PREFIX" 2>/dev/null && log "removed instance profile $PREFIX"
  aws iam detach-role-policy --role-name "$PREFIX" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
  aws iam delete-role-policy --role-name "$PREFIX" --policy-name access-key 2>/dev/null
  aws iam delete-role --role-name "$PREFIX" 2>/dev/null && log "removed role $PREFIX"
  aws secretsmanager delete-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1 \
    && log "scheduled secret $SECRET_NAME for deletion (the usual recovery window applies)"
}

# ── args ────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || usage 1
CMD=$1; shift
while [ $# -gt 0 ]; do
  case "$1" in
    # A name reaches resource names, a tag filter and the log.
    --name) NAME=$2
      case "$NAME" in ''|*[!a-z0-9-]*) die "--name takes lower-case letters, digits and dashes only" ;; esac
      [ ${#NAME} -le 20 ] || die "--name is at most 20 characters (target group names stop at 32)"
      shift ;;
    --config) CONFIG=$2; shift ;;    --days) DAYS=$2; shift ;;
    --type) TYPE=$2; shift ;;        --disk) DISK=$2; shift ;;
    --api-key-file) API_KEY_FILE=$2; shift ;;
    --out) OUT=$2; shift ;;          --purge) PURGE=1 ;;
    --bulk-model)
      BULK_GIVEN=1; [ "$2" = none ] || RECIPE_ARGS+=("$1" "$2"); shift ;;
    --model|--served-name|--bulk-served|--image|--mtp|--max-len|--mem|--bulk-mem|--bulk-max-len|--vllm-args|--extra-args|--bulk-args)
      RECIPE_ARGS+=("$1" "$2"); shift ;;
    -h|--help) usage ;;
    *) die "unknown option $1 (see --help)" ;;
  esac; shift
done
case "$CMD" in
  preflight) cmd_preflight ;; up) cmd_up ;; watch) cmd_watch ;; status) cmd_status ;;
  test) cmd_test ;; key) cmd_key ;; extend) cmd_extend ;; shell) cmd_shell ;; down) cmd_down ;;
  -h|--help|help) usage ;;
  userdata) load_config; RECIPE=$(recipe) || exit 1
            userdata "$(deadline_for "$DAYS")" "arn:aws:secretsmanager:$BOX_REGION:$BOX_ACCOUNT:secret:$SECRET_NAME" ;;  # a dry read
  *) die "unknown command $CMD (preflight|up|watch|status|test|key|extend|shell|down)" ;;
esac
