# The model box inside a platform — design, and `tools/model-box.sh`

The app's two models (the 27B for prose, the 4B for bulk extraction) on one
GPU instance inside a platform's own VPC, reached at a PATH on the
platform's own hostname through the platform's existing ALB:

```
https://<platform-host>/models/prose/v1/chat/completions    (bearer key)
https://<platform-host>/models/bulk/v1/chat/completions
```

`tools/model-box.sh` builds it, in one command, from a git-ignored config
file. This page is the design, the facts it rests on, and how to run it.
`docs/inference-endpoint.md` is the other shape — a public bench box in any
region, reached over SSH or its own hostname — and stays the development
tool.

This revises an earlier design (written 2026-09-22, not in the repo) that
assumed the box would join the platform's IngressGroup, sit behind the
platform WAF on a 300 s idle timeout, and boot from the Deep Learning AMI.
A survey of a real environment on 2026-09-23 — its tfvars, its live ALB and
listener rules, and dry-run launches under its SCPs — found none of that
held, and found a simpler shape. §5 lists what changed and why.

The repo is public. Every account, subnet, listener, hostname, image owner
and tag value below is a placeholder; the values for an environment live in
its `model-box.env`, which `*.env` keeps out of git.

---

## 1. The shape

```
desktop app  (on the network that reaches <platform-host>)
  │  https://<platform-host>/models/prose/…   Authorization: Bearer <key>
  ▼
the platform's ALB (internal, owned by the platform; TLS ends here)
  │  listener rule, priority <n>: path /models and /models/*  → target group
  ▼
target group bond-models-<name>   (ip, HTTP :80, health /models/prose/health)
  │  HTTP inside the VPC; the box's group admits the ALB's groups only
  ▼
Caddy on the box (:80, host networking)
  ├─ handle_path /models/prose/*  → 127.0.0.1:8000   vLLM, the 27B
  ├─ handle_path /models/bulk/*   → 127.0.0.1:8001   vLLM, the 4B
  └─ anything else                → 200 "bond models"
```

- **One listener rule, not an Ingress.** Platforms whose ALB is made by a
  cloud team (an SCP that stops the load balancer controller from creating
  one is the usual reason) route their services with Terraform-owned target
  groups and path-only listener rules on the shared HTTPS listener, and
  their catch-all service is the listener's default action. The box is one
  more of those rules. No Kubernetes object, no IngressGroup order, no DNS
  record and no certificate: the hostname and its certificate are the
  platform's already.
- **Caddy strips the prefix.** The ALB forwards the path as it came, and
  vLLM serves `/v1/…` at its root. Caddy's `handle_path` removes
  `/models/prose` or `/models/bulk` and streams through with
  `flush_interval -1`.
- **The key is the credential.** Both slots run with `VLLM_API_KEY`, so
  every `/v1` path answers 401 without it. `/health` is outside vLLM's key
  check, which is what lets the target group's health check work.
- **No public address.** The box is in a private subnet with NAT egress for
  the image and the weights. The operator reaches it through SSM Session
  Manager, not SSH.
- **The app needs no change.** `BOND_BOX_URL = https://<platform-host>/models`
  and `BOND_BOX_KEY` in `local.mk` are compiled into a build made from the
  repository: the Generative model's **Your server** address defaults to
  `<base>/prose/v1/chat/completions`, and the key comes with it. An address
  or key saved under Settings → Models wins over the build's, and
  **Remove key** returns to it. `isBoxOrigin` accepts a base with a path.
  The slots are one host, so one key.

## 2. Running it

```sh
cp tools/model-box.env.example model-box.env   # fill in; git-ignored
tools/model-box.sh preflight                   # read-only, plus a dry-run launch
tools/model-box.sh up                          # ~20–30 min to serving on a cold boot
tools/model-box.sh key --out ~/model-box.key   # the key, for Settings → Models, once
tools/model-box.sh test                        # both slots through the ALB, with the key
tools/model-box.sh status                      # box, deadline, $ so far, target health
tools/model-box.sh extend --days 7             # move the deadline
tools/model-box.sh shell                       # an SSM session (session-manager-plugin)
tools/model-box.sh down                        # rule, target group, instance
tools/model-box.sh down --purge                # …and the role, the group, the secret
```

`up` accepts the model options of `tools/inference.sh` and passes them
through unchanged (`--model`, `--bulk-model`, `--bulk-model none`, `--mem`,
`--image`, …); the defaults are the 27B and the 4B on one L40S. `--name`
runs a second box beside the first.

`test` and the app must run on a machine that reaches `<platform-host>`
(for an internal ALB, the corporate network or its zero-trust client).
Everything else needs only AWS credentials for the account.

## 3. What `up` creates

Everything is named `bond-models-<name>` and carries the config's
`BOX_TAGS` plus `bond-models=<name>` and `project=bond-desktop`.

| Resource | Notes |
|---|---|
| Secrets Manager secret `bond-models/<name>/api-key` | Generated with `openssl rand`, or seeded with `--api-key-file`. The value goes to the CLI as `file://`, never on argv, and is never printed. `key --out` writes it to a new 0600 file. |
| IAM role and instance profile | `AmazonSSMManagedInstanceCore`, plus `secretsmanager:GetSecretValue` on that one secret. |
| Security group | Port 80 from the ALB's own security groups, nothing else in. |
| The instance | The newest image matching `BOX_AMI_NAME`, the private subnet, no public IP, IMDSv2 required, an encrypted gp3 root volume (200 GB), `BOX_TAGS` on the instance, its volume AND its network interface, and shutdown behaviour **terminate**. Tagged `expires`, `model`, `served`, `bulk-model`, `bulk-served`. |
| Target group | `ip`, HTTP 80, health `<path>/prose/health`, 200, every 30 s, healthy 2 / unhealthy 3, deregistration 30 s. The box's private IP is its one target. |
| Listener rule | `BOX_RULE_PRIORITY`, path `<path>` and `<path>/*`, forward to the target group. `up` refuses a path that already forwards somewhere else. |

`down` deletes the rule, then the target group, then terminates the
instance. The role, the group and the secret are free to keep and are
re-used by the next `up` — including the key, so a tester's keychain entry
stays valid. `--purge` removes them too.

A rule added to someone else's listener does not disturb their Terraform:
it manages its own rules by resource, and an extra rule at an unused
priority is not drift.

## 4. The boot

The user data (`tools/model-box.sh userdata` prints it for a dry read) does,
in order, writing each step to `/opt/bond/stage`, logging to
`/var/log/bond-model-box.log`, and stopping at `failed:<step>` on an error:

1. **The deadline.** The epoch goes to `/opt/bond/deadline`, and a systemd
   timer checks it five minutes after boot and every ten minutes after,
   powering off once it has passed. The instance terminates on shutdown, so
   that is the end of the box. A timer rather than `shutdown -h +N` because
   a scheduled shutdown does not survive a reboot, and an image under a
   patching regime gets rebooted. `extend` rewrites the file over SSM.
2. **Docker and the NVIDIA runtime.** The approved GPU image is expected to
   carry the driver (`nvidia-smi -L` must answer, or the boot stops). Docker
   and the NVIDIA container toolkit are installed with `dnf` when absent,
   and the toolkit configured as a Docker runtime.
3. **The key**, read from Secrets Manager through the instance role into
   `/opt/bond/api.env`, mode 600. The script runs without tracing so the
   value never reaches the log.
4. **Caddy** on :80, with the Caddyfile of §1.
5. **A unit that restarts the slots after a reboot.** `serve.sh` starts its
   containers without a restart policy; `bond-slots.service` runs them
   again, prose first and bulk once prose answers.
6. **The slot recipe, exactly as `tools/inference.sh userdata --persistent`
   renders it**: the image pull, the two slot env files, `serve.sh`, prose,
   the wait, bulk. One recipe, two builders, no copy to drift.

`watch` (which `up` ends with) follows the stage, the weight cache, each
slot's `/health` and the target's ALB health through SSM, one line per
change, until both slots answer and the target is healthy.

## 5. What the survey found, against the earlier design

| Earlier design assumed | What the environment had | Consequence |
|---|---|---|
| An Ingress in the platform IngressGroup, with a group order below the catch-all | A cloud-team ALB; services add path rules to its listener; the catch-all is the default action | One `create-rule` at an unused priority. No Kubernetes, no contract row for group order. |
| The platform WAF inspects the path, and its SQLi body rule would block prompts | No web ACL on this ALB | No WAF change. Re-check per environment: `aws wafv2 get-web-acl-for-resource`. |
| A 300 s idle timeout, set by the catch-all's Ingress | 60 s, the ALB default | Streamed drafts are fine. A NON-streamed call that sends nothing for 60 s gets a 504; the app allows 90–120 s. See §6. |
| The Deep Learning Base AMI | An SCP refuses every image but the organisation's golden ones, on the image itself | `BOX_AMI_OWNER` / `BOX_AMI_NAME` select the golden GPU image. It is Amazon Linux, not Ubuntu, so the boot installs what it lacks with `dnf`. |
| Tags on the instance | The SCP denies the launch unless the required tags are on the instance, the volume **and the network interface** | `BOX_TAGS` goes on all three. The network interface was the last deny to clear. |
| A public box with SSH, or tunnel access | No default VPC, private subnets only | No public IP; SSM (the VPC already had the `ssm`, `ssmmessages` and `ec2messages` endpoints). |
| A Terraform root in this repo, first | — | A script first, so the box can run within the day and the unknowns in §6 are answered before anything is codified. §7. |

How the SCP was read: a dry-run launch that fails with an explicit deny
carries an encoded message, and `aws sts decode-authorization-message` names
the one resource and conditions that failed. `preflight` does this for you
and prints which resource was refused. Two denies were cleared in order:
the image (golden images only), then the network interface (the required
tags). IMDSv2 and an encrypted volume are set as well; they are the CIS
baseline, and the dry run passes with them.

## 6. Risks, and what the first launch answered

The first `up`, on 2026-09-23, went from launch to both slots healthy
behind the ALB in 21 minutes, and `test` passed on both through the
platform hostname. What it settled:

- **Docker on the golden image: present.** The golden GPU image carried
  Docker, the NVIDIA driver and the container runtime; the boot's `dnf`
  fallbacks did not run. They stay, for an image that lacks them.
- **Egress through NAT: open.** Docker Hub (vLLM, Caddy) and Hugging Face
  (~34 GB for the two models) all pulled through the corporate NAT. An
  environment whose egress filter refuses them needs a mirror: the vLLM
  image in ECR, the weights in S3 behind the VPC's S3 endpoint.
- **Through the ALB:** `/v1` answers 401 without the key, `/health` 200; a
  streamed completion's first byte arrived in 0.3 s and the rest as 130
  events over 7 s, so nothing between the app and vLLM buffers. The L40S
  sat at 42 of 46 GB with both slots loaded.
- **Throughput** from the `test` read (one run, not a ledger row): the 27B
  at 43 tok/s on one stream and 146 on four, the 4B at 85 and 512. A
  keeper row belongs in `docs/model-bakeoff.md` after a bench run twice.

Still open:

- **The 60 s idle timeout.** The ALB belongs to the platform, so raising it
  to 300 s is the platform owner's change. Until then, a long non-streamed
  generation under load can 504; `preflight` warns about it.
- **Capacity.** A dry run does not reserve anything, and `g6e` capacity
  moves hour to hour: the first `up` found none in one zone. `BOX_SUBNET`
  lists subnets in different zones and `up` tries them in order;
  `--type g6e.2xlarge` (the same GPU) is the other retry.
- **Cost.** A `g6e.xlarge` on demand is about $1.9/h, roughly $630 for 14
  days, plus the volume. `status` shows the running total.
- **A box that ended itself** leaves the rule and the target group behind,
  so the path answers 503 until `down` removes them. `status` says so.
- **The key is a shared secret at the edge**, as in persistent mode.
  Anyone on the network with the key can use the box. Signing requests
  with the platform's own auth is the natural next step and out of scope.

## 7. Toward Terraform

The script is the shape to codify once §6 is answered. A root module would
own the same resources (§3) with the same names, render the same user data
with `templatefile()`, and take the same variables `model-box.env` holds.
Two things to carry over deliberately: `lifecycle { ignore_changes = [ami,
user_data] }` on the instance, because a new golden image or a changed
model flag would otherwise replace the box and its weight cache; and the
deadline, which in Terraform is better an EventBridge Scheduler one-shot
than a timer on the box.
