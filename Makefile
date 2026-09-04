# bond-desktop — local orchestration for the on-device model server.
# Runs a llama.cpp OpenAI-compatible server (Qwen 3.8 27B, Q4_K_M) on
# :8080 and drives the Dart agent in agent/ against it. Coexists with the
# sibling stacks on this machine: one on :8001 / :3001, bond-ai
# (:8000 / :8002) and bond-mcps (:18000-18005). Nothing here starts or stops
# those.

# These comments sit ABOVE their assignment, never trailing after the value:
# make keeps the whitespace between a value and a trailing `#`, so
# `MODEL_PORT ?= 8080   # free` yields "8080          " and every
# http://localhost:$(MODEL_PORT)/v1/... below would expand with a space in it.

# Free locally; sibling stacks use 8000-8002, 18000-18005, 3001.
MODEL_PORT   ?= 8080
MODEL_HF     ?= ggml-org/Qwen3.8-27B-GGUF:Q4_K_M
# ~2GB KV cache; raise later for long agent trajectories.
CTX_SIZE     ?= 32768

# Explicit rather than the new auto default, which resolved to 4 slots — and
# four slots against this app's strictly-serial client is slot roulette: the
# LRU/LCP slot picker bounces consecutive requests across slots, so the
# byte-identical system prompt the app maintains gets re-evaluated (~5s a
# message) instead of hitting the one warm slot's cache. One slot until the
# app actually sends concurrent requests.
SLOTS        ?= 1

# Speculative decoding seams, off by default — and MEASURED OFF on purpose.
# This server disables speculation on grammar-constrained requests, and every
# call the app makes is `response_format: json_schema`, so neither shape ever
# engages for real traffic; both benched slightly SLOWER than no speculation
# (corpus pass: 464.6s draft / 468.6s ngram vs 452.9s without). The seams stay
# because they are one flag away for a build that lifts that limit or for
# free-text work. Set one or the other, not both — the combination is untried.
#   make model DRAFT_HF=ggml-org/Qwen3.5-0.8B-GGUF   → draft-model speculation
#   make model SPEC_TYPE=ngram-simple                → ngram, no second model
# A draft whose tokenizer does not match the target fails at startup — that
# failure IS the compatibility check, so trying a candidate is safe.
DRAFT_HF     ?=
SPEC_TYPE    ?=

# Tokens drafted per step when DRAFT_HF is set (build default: 3). Untuned —
# see above: no measured config made speculation pay on this workload.
DRAFT_MAX    ?= 12
LOG_DIR      := tmp/logs
WAIT_TIMEOUT ?= 120
# Total seconds `make setup` waits for the first-run ~19GB download + model load.
SETUP_WAIT   ?= 1800

# The second server: a 300M embedding model the app uses to cluster
# conversations. Its own llama-server on its own port, because --embeddings is
# a whole-server mode — one process cannot serve chat completions and
# embeddings at once. The app degrades quietly when it is not running.
EMBED_PORT   ?= 8081
EMBED_HF     ?= ggml-org/embeddinggemma-300M-GGUF

# The third server: the bulk-work model. Triage, extraction and
# storyline-confirm all run here; the 27B on :$(MODEL_PORT) keeps drafting and
# naming, where prose quality is the product. Same chat-completions wire, its
# own port — the app picks a server per task, and a task whose server is down
# parks exactly as it always has.
FAST_PORT    ?= 8082
FAST_HF      ?= ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF
# Matched to the app's drain concurrency of 3, plus one slot of headroom for a
# user-triggered pump. Slots and concurrent clients want to be the same number:
# more slots than clients is the slot roulette described under SLOTS above,
# fewer makes the extra requests queue on the server instead of batching.
FAST_SLOTS   ?= 4

# Where llama-server's -hf flag parks the weights: the repo half of MODEL_HF
# (everything before the ':'), with '/' turned into '--' the way huggingface's
# cache names its directories.
MODEL_CACHE  := $(HOME)/.cache/huggingface/hub/models--$(subst /,--,$(word 1,$(subst :, ,$(MODEL_HF))))

APP_DIR := app
# Overridable because flutter is often absent from make's PATH even when the
# user's interactive shell has it (e.g. a PATH export in ~/.zshrc that a
# non-interactive /bin/sh never reads): make app-test FLUTTER=/path/to/flutter
FLUTTER ?= flutter

GREEN  := \033[32m
RED    := \033[31m
YELLOW := \033[33m
BLUE   := \033[34m
RESET  := \033[0m

.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help install model stop status logs smoke smoke-tools chat clean \
        setup verify clean-model _wait-model _wait-embed _wait-fast \
        embed embed-stop fast fast-stop omlx omlx-stop _wait-omlx \
        app-install app-run app-test app-gen app-migrations app-analyze \
        app-build vec-vendor bench bench-verify bench-verify-prose bench-prose \
        ab ab-membership drain bench-compare

help:
	@printf "bond-desktop — local model + agent\n\n"
	@printf "  make setup        → install + model + fast + verify + smoke (start here)\n"
	@printf "  make install      → brew install llama.cpp + dart pub get in agent/\n"
	@printf "  make model        → start llama-server :$(MODEL_PORT) ($(MODEL_HF))\n"
	@printf "  make stop         → stop the model server on :$(MODEL_PORT)\n"
	@printf "  make embed        → start the embedding server :$(EMBED_PORT) ($(EMBED_HF))\n"
	@printf "  make embed-stop   → stop the embedding server on :$(EMBED_PORT)\n"
	@printf "  make fast         → start the bulk-work server :$(FAST_PORT) ($(FAST_HF))\n"
	@printf "  make fast-stop    → stop the bulk-work server on :$(FAST_PORT)\n"
	@printf "  make omlx         → start the oMLX bakeoff server :$(OMLX_PORT) (all cached models)\n"
	@printf "  make omlx-stop    → stop the oMLX server on :$(OMLX_PORT)\n"
	@printf "  make status       → are the servers up? [up]/[down] + pid\n"
	@printf "  make logs         → tail $(LOG_DIR)/model-$(MODEL_PORT).log\n"
	@printf "  make smoke        → one chat completion against :$(MODEL_PORT)\n"
	@printf "  make smoke-tools  → prove the model emits OpenAI tool_calls\n"
	@printf "  make chat         → interactive Dart agent (foreground)\n"
	@printf "  make verify       → SHA256 the downloaded weights against the HF cache\n"
	@printf "  make clean-model  → delete the cached weights for a re-download\n"
	@printf "  make clean        → rm $(LOG_DIR)\n\n"
	@printf "  make app-run      → run the $(APP_DIR)/ desktop inbox on macOS\n"
	@printf "  make app-test     → flutter test in $(APP_DIR)/\n"
	@printf "  make app-gen      → regenerate Drift code + migration snapshots\n"
	@printf "  make app-migrations → record a Drift schema bump (run before app-gen)\n"
	@printf "  make bench-verify → does a target uphold the contract? (runs before every bench)\n"
	@printf "  make bench        → live model benchmark (needs make fast up)\n"
	@printf "  make bench-prose  → storyline names + drafted replies, verbatim (needs make model up)\n"
	@printf "  make ab           → 27B vs fast model, side by side (needs both up)\n"
	@printf "  make ab-membership → membership eval, 27B vs fast model (needs both up)\n"
	@printf "  make drain        → drain concurrency race, BENCH_K rounds (needs make fast up)\n"
	@printf "  make bench-compare A=<a.json> B=<b.json> → diff two bench results\n"
	@printf "  make app-build    → release build of the macOS app\n"
	@printf "  make vec-vendor   → re-download the sqlite-vec C sources (SHA-pinned)\n\n"
	@printf "Point a bench at a candidate runtime without editing anything:\n"
	@printf "  make bench BENCH_URL=http://localhost:9000/v1/chat/completions \\\\\n"
	@printf "             BENCH_LABEL=omlx/qwen3-4b-4bit BENCH_MODEL=qwen3-4b\n"
	@printf "Each run writes JSON to $(BENCH_OUT); PROSE_* points the other slot.\n"
	@printf "BENCH_VERIFY=0 skips the contract check; BENCH_K=1,3,6 picks the drain\n"
	@printf "rounds (start the server with FAST_SLOTS >= max(K)).\n\n"
	@printf "First run downloads ~19GB of weights before the port binds —\n"
	@printf "'make model' will time out; watch 'make logs' and wait for [up].\n"

install:
	@brew list llama.cpp >/dev/null 2>&1 || brew install llama.cpp
	@if [ -f agent/pubspec.yaml ]; then \
	   cd agent && dart pub get; \
	 else \
	   printf "  $(YELLOW)[skip]$(RESET) no agent/pubspec.yaml yet — dart pub get skipped\n"; \
	 fi

# One command from a bare machine to a verified, answering model. Everything
# it calls is idempotent, so re-running it on a live server is a no-op plus
# two smoke tests.
#
# The `-` on the model and fast launch lines is load-bearing: on a first run
# `make model` / `make fast` launch llama-server and then exit NON-ZERO after
# WAIT_TIMEOUT seconds because the download (~19GB / ~4.3GB) has not finished
# and the port is not bound yet. That is the expected first-run outcome, not a
# failure — the download keeps going in the background and the polls below are
# what actually wait for it. Both servers, not just the 27B: triage PARKS
# rather than degrades when the fast server is down, so a setup that skipped
# it would hand over an inbox whose AI silently never runs.
setup:
	@printf "$(BLUE)==>$(RESET) [1/7] installing prerequisites\n"
	@$(MAKE) --no-print-directory install
	@printf "$(BLUE)==>$(RESET) [2/7] model server on :$(MODEL_PORT)\n"
	-@if curl -sf -o /dev/null http://localhost:$(MODEL_PORT)/health; then \
	   printf "  $(GREEN)✓$(RESET) model already up — skipping launch\n"; \
	 else \
	   $(MAKE) --no-print-directory model; \
	 fi
	@printf "$(BLUE)==>$(RESET) [3/7] waiting for /health (up to $(SETUP_WAIT)s)\n"
	@waited=0; \
	 while [ $$waited -lt $(SETUP_WAIT) ]; do \
	   if curl -sf -o /dev/null http://localhost:$(MODEL_PORT)/health; then \
	     printf "  $(GREEN)✓$(RESET) /health answering after %ss\n" "$$waited"; \
	     exit 0; \
	   fi; \
	   sleep 10; \
	   waited=$$((waited + 10)); \
	   if [ $$((waited % 60)) -eq 0 ]; then \
	     printf "  $(YELLOW)…$(RESET) still downloading/loading — %ss elapsed (watch: make logs)\n" "$$waited"; \
	   fi; \
	 done; \
	 printf "  $(RED)✗$(RESET) model never answered /health in $(SETUP_WAIT)s\n"; \
	 printf "    check the server log:  make logs\n"; \
	 exit 1
	@printf "$(BLUE)==>$(RESET) [4/7] fast server on :$(FAST_PORT)\n"
	-@if curl -sf -o /dev/null http://localhost:$(FAST_PORT)/health; then \
	   printf "  $(GREEN)✓$(RESET) fast already up — skipping launch\n"; \
	 else \
	   $(MAKE) --no-print-directory fast; \
	 fi
	@printf "$(BLUE)==>$(RESET) [5/7] waiting for fast /health (up to $(SETUP_WAIT)s)\n"
	@waited=0; \
	 while [ $$waited -lt $(SETUP_WAIT) ]; do \
	   if curl -sf -o /dev/null http://localhost:$(FAST_PORT)/health; then \
	     printf "  $(GREEN)✓$(RESET) fast /health answering after %ss\n" "$$waited"; \
	     exit 0; \
	   fi; \
	   sleep 10; \
	   waited=$$((waited + 10)); \
	   if [ $$((waited % 60)) -eq 0 ]; then \
	     printf "  $(YELLOW)…$(RESET) fast still downloading/loading — %ss elapsed\n" "$$waited"; \
	   fi; \
	 done; \
	 printf "  $(RED)✗$(RESET) fast never answered /health in $(SETUP_WAIT)s\n"; \
	 printf "    check the log:  tail -f $(LOG_DIR)/model-$(FAST_PORT).log\n"; \
	 exit 1
	@printf "$(BLUE)==>$(RESET) [6/7] verifying the downloaded weights\n"
	@$(MAKE) --no-print-directory verify
	@printf "$(BLUE)==>$(RESET) [7/7] smoke test\n"
	@$(MAKE) --no-print-directory smoke
	@printf "$(GREEN)setup complete — try: make chat$(RESET)\n"

# -fa on rather than auto, so a regression in auto-detection can never
# silently slow prefill. --load-mode mmap+mlock keeps mmap's fast load AND
# wires the weights: without it macOS pages the mmap'd 16GB out during idle,
# and the first prefill after a quiet stretch measured 6.8 tok/s against 130
# warm (the bare mlock mode drops mmap; the old --mlock flag is deprecated).
MODEL_FLAGS := --jinja -ngl 99 -c $(CTX_SIZE) -fa on --load-mode mmap+mlock \
  --parallel $(SLOTS)
ifneq ($(strip $(DRAFT_HF)),)
MODEL_FLAGS += -hfd $(DRAFT_HF) --spec-draft-n-max $(DRAFT_MAX) \
  --spec-draft-ngl 99
endif
ifneq ($(strip $(SPEC_TYPE)),)
MODEL_FLAGS += --spec-type $(SPEC_TYPE)
endif

# -ngl 99 offloads every layer to Metal; --jinja is required for the model's
# own chat template (and therefore for tool calling — see `make smoke-tools`).
# The weights live in llama.cpp's HF cache, not this repo, so `make clean`
# never touches them.
#
# The launch and the wait are SEPARATE recipe lines on purpose. make executes
# any line containing $(MAKE) even under `make -n`, so folding both into one
# shell command would make a dry run actually start the server (and the ~19GB
# download). Split like this, `make -n model` only dry-runs.
#
# Line 1 is therefore silent when the server is already up: it just skips the
# launch and falls through to _wait-model, which finds the port bound on its
# first probe and prints the single "✓ model bound" line. One status line for
# both the already-up and the fresh-start case.
#
# A foreign process on :$(MODEL_PORT) is a hard error, not an "already up" —
# exiting non-zero here also stops make before line 2, so _wait-model never
# gets to report someone else's listener as our model.
model:
	@pid=$$(lsof -nP -iTCP:$(MODEL_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -n "$$pid" ]; then \
	   cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	   case "$$cmd" in \
	     *llama-server*) exit 0 ;; \
	     *) printf "  $(YELLOW)!$(RESET) :$(MODEL_PORT) is held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd"; \
	        printf "    not ours to reuse — free it, or: make model MODEL_PORT=<other>\n"; \
	        exit 1 ;; \
	   esac; \
	 fi; \
	 mkdir -p $(LOG_DIR); \
	 printf "→ llama-server on :$(MODEL_PORT)  ($(MODEL_HF), ctx $(CTX_SIZE))\n"; \
	 nohup llama-server -hf $(MODEL_HF) $(MODEL_FLAGS) --port $(MODEL_PORT) \
	   > $(LOG_DIR)/model-$(MODEL_PORT).log 2>&1 &
	@$(MAKE) --no-print-directory _wait-model

# Port-based, and command-matched rather than cwd-matched: the binary lives
# in /opt/homebrew and is launched via nohup, so neither its command line nor
# its cwd mentions this checkout. Matching on "llama-server" is what keeps us
# from killing a sibling stack that happens to hold :$(MODEL_PORT).
#
# STRICTLY the port, with no pgrep fallback: `make embed` runs a SECOND
# llama-server on :$(EMBED_PORT), and a fallback that killed llama-server by
# name would take the embedding server down every time someone stopped the
# chat model. The case that costs us — cancelling a first run that is still
# downloading and has not bound the port yet — is now a message rather than a
# kill, because guessing which of two servers the user meant is worse than
# telling them what to do.
stop:
	@pid=$$(lsof -nP -iTCP:$(MODEL_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -z "$$pid" ]; then \
	   printf "  $(RED)[down]$(RESET) nothing holds :$(MODEL_PORT)\n"; \
	   if pgrep -x llama-server >/dev/null 2>&1; then \
	     printf "    a llama-server is alive but has not bound it — another server\n"; \
	     printf "    (make embed-stop / make fast-stop) or a first run still\n"; \
	     printf "    downloading (watch: make logs; kill it by pid to cancel)\n"; \
	   fi; \
	   exit 0; \
	 fi; \
	 cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	 case "$$cmd" in \
	   *llama-server*) ;; \
	   *) printf "  $(YELLOW)[skip]$(RESET) :$(MODEL_PORT) held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd" >&2; \
	      exit 0 ;; \
	 esac; \
	 printf "  stopping llama-server :$(MODEL_PORT) (pid %s)\n" "$$pid"; \
	 kill -TERM $$pid 2>/dev/null || true; \
	 for i in 1 2 3 4 5 6 7 8 9 10; do \
	   rem=$$(lsof -nP -iTCP:$(MODEL_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	   [ -z "$$rem" ] && break; \
	   sleep 1; \
	 done; \
	 rem=$$(lsof -nP -iTCP:$(MODEL_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	 if [ -n "$$rem" ]; then \
	   printf "  $(RED)✗$(RESET) :$(MODEL_PORT) still held after 10s (pid %s)\n" "$$rem"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) :$(MODEL_PORT) free\n"

# The embedding server. Same port guard as `model:`, same split between the
# launch line and the wait line so `make -n embed` stays a dry run.
#
# No --jinja and no -ngl: /v1/embeddings runs no chat template, and a 300M
# model needs no persuading onto the GPU. --embeddings is what puts the server
# in embedding mode, which is also why this cannot share the chat model's
# process — one llama-server serves one mode.
embed:
	@pid=$$(lsof -nP -iTCP:$(EMBED_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -n "$$pid" ]; then \
	   cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	   case "$$cmd" in \
	     *llama-server*) exit 0 ;; \
	     *) printf "  $(YELLOW)!$(RESET) :$(EMBED_PORT) is held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd"; \
	        printf "    not ours to reuse — free it, or: make embed EMBED_PORT=<other>\n"; \
	        exit 1 ;; \
	   esac; \
	 fi; \
	 mkdir -p $(LOG_DIR); \
	 printf "→ llama-server on :$(EMBED_PORT)  ($(EMBED_HF), embeddings)\n"; \
	 nohup llama-server -hf $(EMBED_HF) --embeddings --port $(EMBED_PORT) \
	   > $(LOG_DIR)/model-$(EMBED_PORT).log 2>&1 &
	@$(MAKE) --no-print-directory _wait-embed

# Port-based only, for the reason `stop:` is: killing by name would take the
# chat model down with it.
embed-stop:
	@pid=$$(lsof -nP -iTCP:$(EMBED_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -z "$$pid" ]; then \
	   printf "  $(RED)[down]$(RESET) nothing holds :$(EMBED_PORT)\n"; \
	   exit 0; \
	 fi; \
	 cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	 case "$$cmd" in \
	   *llama-server*) ;; \
	   *) printf "  $(YELLOW)[skip]$(RESET) :$(EMBED_PORT) held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd" >&2; \
	      exit 0 ;; \
	 esac; \
	 printf "  stopping llama-server :$(EMBED_PORT) (pid %s)\n" "$$pid"; \
	 kill -TERM $$pid 2>/dev/null || true; \
	 for i in 1 2 3 4 5 6 7 8 9 10; do \
	   rem=$$(lsof -nP -iTCP:$(EMBED_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	   [ -z "$$rem" ] && break; \
	   sleep 1; \
	 done; \
	 rem=$$(lsof -nP -iTCP:$(EMBED_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	 if [ -n "$$rem" ]; then \
	   printf "  $(RED)✗$(RESET) :$(EMBED_PORT) still held after 10s (pid %s)\n" "$$rem"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) :$(EMBED_PORT) free\n"

# No draft or spec seams, unlike MODEL_FLAGS: this model is already the small
# one, so there is nothing cheaper to draft with. Everything else matches —
# same context, same flash attention, same mmap+mlock reason (a model that
# gets paged out during idle is slow on exactly the first call after a quiet
# stretch, which for bulk work is every sync).
FAST_FLAGS := --jinja -ngl 99 -c $(CTX_SIZE) -fa on --load-mode mmap+mlock \
  --parallel $(FAST_SLOTS)

# The bulk-work server. Same port guard as `model:` and `embed:`, same split
# between the launch line and the wait line so `make -n fast` stays a dry run.
fast:
	@pid=$$(lsof -nP -iTCP:$(FAST_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -n "$$pid" ]; then \
	   cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	   case "$$cmd" in \
	     *llama-server*) exit 0 ;; \
	     *) printf "  $(YELLOW)!$(RESET) :$(FAST_PORT) is held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd"; \
	        printf "    not ours to reuse — free it, or: make fast FAST_PORT=<other>\n"; \
	        exit 1 ;; \
	   esac; \
	 fi; \
	 mkdir -p $(LOG_DIR); \
	 printf "→ llama-server on :$(FAST_PORT)  ($(FAST_HF), ctx $(CTX_SIZE))\n"; \
	 nohup llama-server -hf $(FAST_HF) $(FAST_FLAGS) --port $(FAST_PORT) \
	   > $(LOG_DIR)/model-$(FAST_PORT).log 2>&1 &
	@$(MAKE) --no-print-directory _wait-fast

# Port-based only, for the reason `stop:` is: killing by name would take the
# other two servers down with it.
fast-stop:
	@pid=$$(lsof -nP -iTCP:$(FAST_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -z "$$pid" ]; then \
	   printf "  $(RED)[down]$(RESET) nothing holds :$(FAST_PORT)\n"; \
	   exit 0; \
	 fi; \
	 cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	 case "$$cmd" in \
	   *llama-server*) ;; \
	   *) printf "  $(YELLOW)[skip]$(RESET) :$(FAST_PORT) held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd" >&2; \
	      exit 0 ;; \
	 esac; \
	 printf "  stopping llama-server :$(FAST_PORT) (pid %s)\n" "$$pid"; \
	 kill -TERM $$pid 2>/dev/null || true; \
	 for i in 1 2 3 4 5 6 7 8 9 10; do \
	   rem=$$(lsof -nP -iTCP:$(FAST_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	   [ -z "$$rem" ] && break; \
	   sleep 1; \
	 done; \
	 rem=$$(lsof -nP -iTCP:$(FAST_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	 if [ -n "$$rem" ]; then \
	   printf "  $(RED)✗$(RESET) :$(FAST_PORT) still held after 10s (pid %s)\n" "$$rem"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) :$(FAST_PORT) free\n"

# pgrep -x, NOT `ps ax | grep llama-server`: this recipe's own /bin/sh -c
# command line contains the literal string "llama-server" (in the printf
# below), and ps shows that shell, so a full-command-line grep matches the
# recipe that is running it — the "loading" warning then fires on every
# `make status`, even with no server anywhere. -x matches the executable
# name only, which is the thing we actually mean.
#
# The loading hint is reported only when NO port is bound. With three servers
# a live llama-server is no longer evidence that something is still loading —
# it is usually just one of the others. :$(OMLX_PORT) is deliberately left out
# of that condition: it is a different runtime entirely, so a live oMLX says
# nothing about whether a llama-server is mid-download.
status:
	@printf "$(BLUE)=== bond-desktop ===$(RESET)\n"
	@mpid=$$(lsof -nP -iTCP:$(MODEL_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 epid=$$(lsof -nP -iTCP:$(EMBED_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 fpid=$$(lsof -nP -iTCP:$(FAST_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 opid=$$(lsof -nP -iTCP:$(OMLX_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -n "$$mpid" ]; then \
	   printf "  $(GREEN)[up]$(RESET)   %-12s :%s  (pid %s)\n" "model" "$(MODEL_PORT)" "$$mpid"; \
	 else \
	   printf "  $(RED)[down]$(RESET) %-12s :%s\n" "model" "$(MODEL_PORT)"; \
	 fi; \
	 if [ -n "$$epid" ]; then \
	   printf "  $(GREEN)[up]$(RESET)   %-12s :%s  (pid %s)\n" "embed" "$(EMBED_PORT)" "$$epid"; \
	 else \
	   printf "  $(RED)[down]$(RESET) %-12s :%s\n" "embed" "$(EMBED_PORT)"; \
	 fi; \
	 if [ -n "$$fpid" ]; then \
	   printf "  $(GREEN)[up]$(RESET)   %-12s :%s  (pid %s)\n" "fast" "$(FAST_PORT)" "$$fpid"; \
	 else \
	   printf "  $(RED)[down]$(RESET) %-12s :%s\n" "fast" "$(FAST_PORT)"; \
	 fi; \
	 if [ -n "$$opid" ]; then \
	   printf "  $(GREEN)[up]$(RESET)   %-12s :%s  (pid %s)\n" "omlx" "$(OMLX_PORT)" "$$opid"; \
	 else \
	   printf "  $(RED)[down]$(RESET) %-12s :%s\n" "omlx" "$(OMLX_PORT)"; \
	 fi; \
	 if [ -z "$$mpid" ] && [ -z "$$epid" ] && [ -z "$$fpid" ]; then \
	   lpid=$$(pgrep -x llama-server 2>/dev/null | head -1); \
	   if [ -n "$$lpid" ]; then \
	     printf "  $(YELLOW)[..]$(RESET)   llama-server (pid %s) is loading/downloading — watch: make logs\n" "$$lpid"; \
	   fi; \
	 fi

# The chat model's log. The embedding server writes its own,
# $(LOG_DIR)/model-$(EMBED_PORT).log — tail that one directly when `make embed`
# is the thing misbehaving.
logs:
	@test -f $(LOG_DIR)/model-$(MODEL_PORT).log || { \
	   printf "$(RED)✗$(RESET) no $(LOG_DIR)/model-$(MODEL_PORT).log — run: make model\n"; exit 1; }
	@tail -f $(LOG_DIR)/model-$(MODEL_PORT).log

smoke:
	@resp=$$(curl -sf -X POST http://localhost:$(MODEL_PORT)/v1/chat/completions \
	   -H 'Content-Type: application/json' \
	   -d '{"model":"qwen3.8","messages":[{"role":"user","content":"Reply with one short sentence confirming you are running locally."}],"reasoning_effort":"low","max_tokens":256}') \
	 || { printf "$(RED)✗$(RESET) model not reachable — run: make model\n"; exit 1; }; \
	 printf '%s' "$$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'

# Tool calling is the whole point of the local model, so this is a gate, not a
# demo: it exits non-zero when the model answers in prose instead of emitting
# an OpenAI tool_calls block. Needs llama-server's --jinja (see `model:`).
smoke-tools:
	@resp=$$(curl -sf -X POST http://localhost:$(MODEL_PORT)/v1/chat/completions \
	   -H 'Content-Type: application/json' \
	   -d '{"model":"qwen3.8","messages":[{"role":"user","content":"What time is it right now? Use the tool."}],"tools":[{"type":"function","function":{"name":"get_current_time","description":"Get the current local time as an ISO 8601 timestamp","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":"auto","reasoning_effort":"low","max_tokens":512}') \
	 || { printf "$(RED)✗$(RESET) model not reachable — run: make model\n"; exit 1; }; \
	 printf '%s' "$$resp" | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; tc=m.get("tool_calls") or []; print("TOOL_CALLS OK\n"+json.dumps(tc,indent=2)) if tc else (print("NO TOOL_CALLS\n"+(m.get("content") or "")), sys.exit(1))'

chat:
	@test -f agent/bin/chat.dart || { \
	   printf "$(RED)✗$(RESET) agent/bin/chat.dart not found — the Dart agent isn't in place yet\n"; exit 1; }
	@cd agent && dart run bin/chat.dart

clean:
	@rm -rf $(LOG_DIR)
	@printf "removed $(LOG_DIR)\n"

# ── $(APP_DIR)/ — the Flutter desktop inbox ────────────────────────────
# The app talks to ALL THREE servers above: :$(FAST_PORT) for triage,
# extraction and storyline membership, :$(MODEL_PORT) for drafts and storyline
# names, :$(EMBED_PORT) for conversation embeddings. None is required to run it
# — with a server down the work that needs it simply parks and retries on the
# next sync — but `make model`, `make fast` and `make embed` are what make it do
# anything intelligent. Override the URLs with --dart-define=LLAMA_URL=... /
# --dart-define=FAST_LLAMA_URL=... / --dart-define=EMBED_URL=... .

# Dev-stage Microsoft auth: the app registration's client id, tenant id, and
# (because the shared Azure registration has no public-client platform, and
# no one can reach the portal to add one) the client secret its owning
# backend uses. All three are read at LAUNCH time from a git-ignored
# dotenv-style file and injected as build defines; none is committed and
# none is echoed. A build made this way carries the secret and must not be
# distributed.
#
# MS_ENV names that file — any file with MICROSOFT_CLIENT_ID,
# MICROSOFT_TENANT_ID and MICROSOFT_CLIENT_SECRET lines. The default is a
# .env next to this Makefile; a git-ignored local.mk may point it at
# wherever those values already live. The same file may carry
# BOND_MCP_SERVER_URL — the deployed bond-mcps endpoint, kept out of source
# for the same public-repo reason as the ids.
-include local.mk
MS_ENV ?= $(CURDIR)/.env

# ── the bakeoff: where a bench points ──────────────────────────────────
# Every one of these is `?=` and sits AFTER the include above, so a durable
# override in local.mk wins and a one-off on the command line wins over that.
# The point is that a candidate runtime can be benched with one command and no
# code edit: `make bench BENCH_URL=http://localhost:9000/v1/chat/completions
# BENCH_LABEL=omlx/qwen3-4b-4bit BENCH_MODEL=qwen3-4b`.
#
# BENCH_* is the BULK slot — triage, extraction, membership, the work the fast
# server does today. Defaults to exactly that, so a bench with no overrides
# still measures what ships.
BENCH_URL    ?= http://localhost:$(FAST_PORT)/v1/chat/completions
# Names the run, and lands in the result filename. Name the weights as well as
# the runtime: two quantizations of one model produce two otherwise identical
# tables.
BENCH_LABEL  ?= llamacpp/$(notdir $(FAST_HF))
# llama-server ignores this; an MLX-based server routes on it.
BENCH_MODEL  ?= qwen3.8
# PROSE_* is the other slot — drafts and storyline names, the 27B's work, and
# the side an A/B compares a candidate against.
PROSE_URL    ?= http://localhost:$(MODEL_PORT)/v1/chat/completions
PROSE_LABEL  ?= llamacpp/$(notdir $(MODEL_HF))
PROSE_MODEL  ?= qwen3.8
# Where a run drops its JSON result. Absolute, because `flutter test` runs with
# $(APP_DIR) as its working directory. tmp/ is git-ignored.
BENCH_OUT    ?= $(CURDIR)/tmp/bench
# Discarded calls before the clock starts: llama.cpp measured 6.8 tok/s cold
# against 130 warm here, and one cold call in the sample replaces the median
# rather than nudging it.
BENCH_WARMUP ?= 1
# 1 for a candidate that always reasons (R1-Distill has no enable_thinking to
# honour): the benches then PRINT the leak count instead of failing on it.
BENCH_THINK  ?= 0
# The contract check that runs before every bench below. 0 skips it — for a
# server already verified this session, or to see how a failing candidate
# actually behaves rather than being stopped at the door.
BENCH_VERIFY ?= 1
# Which concurrencies `make drain` races, in order. The fast server must be
# started with AT LEAST max(K) slots (`make fast FAST_SLOTS=4`) or the high
# rounds measure queue-wait rather than batching, which is the opposite of the
# thing being measured.
BENCH_K      ?= 1,3

# Single-quoted values, every one: a label carries spaces and parentheses, and
# an unquoted --dart-define would hand the shell a second word to run.
BENCH_DEFINES := \
  --dart-define=BENCH_URL='$(BENCH_URL)' \
  --dart-define=BENCH_LABEL='$(BENCH_LABEL)' \
  --dart-define=BENCH_MODEL='$(BENCH_MODEL)' \
  --dart-define=PROSE_URL='$(PROSE_URL)' \
  --dart-define=PROSE_LABEL='$(PROSE_LABEL)' \
  --dart-define=PROSE_MODEL='$(PROSE_MODEL)' \
  --dart-define=BENCH_OUT='$(BENCH_OUT)' \
  --dart-define=BENCH_WARMUP=$(BENCH_WARMUP) \
  --dart-define=BENCH_THINK=$(if $(filter-out 0,$(BENCH_THINK)),true,false) \
  --dart-define=BENCH_K='$(BENCH_K)'

# ── the bakeoff: oMLX, the candidate runtime ───────────────────────────
# oMLX is an MLX-based OpenAI-compatible server, and unlike llama-server it is
# MULTI-MODEL: one process discovers every model in ~/.omlx/models and in the
# HuggingFace cache, and the request body's `model` field picks between them.
# So there is one server here, not one per slot — BENCH_MODEL/PROSE_MODEL are
# what route a bench at the bulk or the prose weights.
#
# Deliberately outside the 8080-8083 range the llama.cpp servers use, so a
# bakeoff can hold both runtimes up at once and compare them without a restart
# between rows.
OMLX_PORT      ?= 8090
# oMLX's `balanced` memory guard picked a 14.0GB ceiling on this 64GB M1 Max,
# which refuses the ~15GB 27B-4bit outright. An explicit ceiling replaces the
# tier: 24GB leaves the 4B and the 27B resident together and still sits well
# under the ~52GB Metal budget, so the multi-model LRU never has to evict one
# to answer for the other.
OMLX_GUARD_GB  ?= 24
# --max-concurrent-requests, and it carries FAST_SLOTS' warning: `make drain`
# races BENCH_K concurrencies at once, so anything below max(BENCH_K) turns the
# high rounds into a measurement of queue-wait rather than of batching.
OMLX_SLOTS     ?= 8
# The dylib search path xgrammar needs to actually load. Homebrew's
# `--with-grammar` install pairs xgrammar 0.2.3 with a tvm_ffi whose loader
# looks only in tvm_ffi's own directories plus DYLD_LIBRARY_PATH/PATH — never
# in the xgrammar package directory where libxgrammar_bindings.dylib lives, and
# that dylib in turn needs libtvm_ffi.dylib from tvm_ffi/lib. Both directories,
# in that order, are what make the import succeed. The symptom when it is
# missing is not a crash: oMLX falls back to asking for the schema in the
# prompt, structured output stops being constrained, and `make bench-verify`
# fails its enum probe. python3.11 is pinned by the formula's own venv.
OMLX_XG_LIBS   := /opt/homebrew/opt/omlx/libexec/lib/python3.11/site-packages/xgrammar:/opt/homebrew/opt/omlx/libexec/lib/python3.11/site-packages/tvm_ffi/lib
# The whole launch command in one overridable variable: when oMLX's CLI moves,
# this is the single seam to fix, and a one-off experiment can replace it
# wholesale on the command line.
#
# `env` rather than a plain assignment, for two independent reasons: `nohup
# VAR=x cmd` treats the assignment itself as the command name, and SIP strips
# exported DYLD_* variables when make execs /bin/sh. Handing the assignment to
# `env` as an argv word, which then execs the (unprotected) Homebrew python,
# survives both.
OMLX_SERVE     ?= env DYLD_LIBRARY_PATH=$(OMLX_XG_LIBS) omlx serve --port $(OMLX_PORT) --memory-guard-gb $(OMLX_GUARD_GB) --max-concurrent-requests $(OMLX_SLOTS)

# Same port guard as `fast:`, matching on *omlx* rather than *llama-server*:
# the process shows up as the formula's python running /opt/homebrew/bin/omlx,
# so the pattern catches both halves of that command line.
#
# Same split between the launch line and the wait line, and for the same
# reason: make runs any line containing $(MAKE) even under `make -n`, so
# folding them together would make a dry run start a real server.
omlx:
	@pid=$$(lsof -nP -iTCP:$(OMLX_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -n "$$pid" ]; then \
	   cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	   case "$$cmd" in \
	     *omlx*) exit 0 ;; \
	     *) printf "  $(YELLOW)!$(RESET) :$(OMLX_PORT) is held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd"; \
	        printf "    not ours to reuse — free it, or: make omlx OMLX_PORT=<other>\n"; \
	        exit 1 ;; \
	   esac; \
	 fi; \
	 mkdir -p $(LOG_DIR); \
	 printf "→ omlx serve on :$(OMLX_PORT)  (all cached models, guard $(OMLX_GUARD_GB)GB, $(OMLX_SLOTS) slots)\n"; \
	 nohup $(OMLX_SERVE) \
	   > $(LOG_DIR)/omlx-$(OMLX_PORT).log 2>&1 &
	@$(MAKE) --no-print-directory _wait-omlx

# Port-based only, for the reason `stop:` is — except the name that would be
# caught by a fallback here is a Homebrew python, which is very much not ours
# to kill by name.
omlx-stop:
	@pid=$$(lsof -nP -iTCP:$(OMLX_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	 if [ -z "$$pid" ]; then \
	   printf "  $(RED)[down]$(RESET) nothing holds :$(OMLX_PORT)\n"; \
	   exit 0; \
	 fi; \
	 cmd=$$(ps -p $$pid -o command= 2>/dev/null); \
	 case "$$cmd" in \
	   *omlx*) ;; \
	   *) printf "  $(YELLOW)[skip]$(RESET) :$(OMLX_PORT) held by a foreign process (pid %s): %s\n" "$$pid" "$$cmd" >&2; \
	      exit 0 ;; \
	 esac; \
	 printf "  stopping omlx serve :$(OMLX_PORT) (pid %s)\n" "$$pid"; \
	 kill -TERM $$pid 2>/dev/null || true; \
	 for i in 1 2 3 4 5 6 7 8 9 10; do \
	   rem=$$(lsof -nP -iTCP:$(OMLX_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	   [ -z "$$rem" ] && break; \
	   sleep 1; \
	 done; \
	 rem=$$(lsof -nP -iTCP:$(OMLX_PORT) -sTCP:LISTEN -t 2>/dev/null); \
	 if [ -n "$$rem" ]; then \
	   printf "  $(RED)✗$(RESET) :$(OMLX_PORT) still held after 10s (pid %s)\n" "$$rem"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) :$(OMLX_PORT) free\n"

# Emits --dart-define=MS_CLIENT_ID/MS_TENANT_ID/MS_CLIENT_SECRET=... for each
# value that can be read; emits nothing for any that cannot (sign-in then
# refuses with a config error; a missing secret alone means public-client
# behavior).
define APP_SECRET_DEFINE
$$(CID=$$(grep -m1 '^MICROSOFT_CLIENT_ID=' $(MS_ENV) 2>/dev/null | cut -d= -f2-); \
   TID=$$(grep -m1 '^MICROSOFT_TENANT_ID=' $(MS_ENV) 2>/dev/null | cut -d= -f2-); \
   SECRET=$$(grep -m1 '^MICROSOFT_CLIENT_SECRET=' $(MS_ENV) 2>/dev/null | cut -d= -f2-); \
   MCPURL=$$(grep -m1 '^BOND_MCP_SERVER_URL=' $(MS_ENV) 2>/dev/null | cut -d= -f2-); \
   if [ -n "$$CID" ]; then printf -- '--dart-define=MS_CLIENT_ID=%s ' "$$CID"; fi; \
   if [ -n "$$TID" ]; then printf -- '--dart-define=MS_TENANT_ID=%s ' "$$TID"; fi; \
   if [ -n "$$MCPURL" ]; then printf -- '--dart-define=BOND_MCP_SERVER_URL=%s ' "$$MCPURL"; fi; \
   if [ -n "$$SECRET" ]; then printf -- '--dart-define=MS_CLIENT_SECRET=%s' "$$SECRET"; fi)
endef

# Points the APP itself — not a bench — at other servers or other model names,
# so adopting a candidate that won the bakeoff is a launch flag rather than an
# edit to llm_client.dart.
#
# Emitted only for the vars that are SET, which is the whole reason this is
# nine lines instead of one: an empty define is not the same as no define.
# `--dart-define=LLAMA_URL=` makes String.fromEnvironment read '' — the app
# would POST to nowhere instead of falling back to its default.
APP_LLM_DEFINES :=
ifneq ($(strip $(LLAMA_URL)),)
APP_LLM_DEFINES += --dart-define=LLAMA_URL='$(LLAMA_URL)'
endif
ifneq ($(strip $(FAST_LLAMA_URL)),)
APP_LLM_DEFINES += --dart-define=FAST_LLAMA_URL='$(FAST_LLAMA_URL)'
endif
ifneq ($(strip $(EMBED_URL)),)
APP_LLM_DEFINES += --dart-define=EMBED_URL='$(EMBED_URL)'
endif
ifneq ($(strip $(LLAMA_MODEL)),)
APP_LLM_DEFINES += --dart-define=LLAMA_MODEL='$(LLAMA_MODEL)'
endif
ifneq ($(strip $(FAST_LLAMA_MODEL)),)
APP_LLM_DEFINES += --dart-define=FAST_LLAMA_MODEL='$(FAST_LLAMA_MODEL)'
endif

app-install:
	@cd $(APP_DIR) && $(FLUTTER) pub get

app-run:
	@cd $(APP_DIR) && $(FLUTTER) run -d macos $(APP_SECRET_DEFINE) $(APP_LLM_DEFINES)

app-test:
	@cd $(APP_DIR) && $(FLUTTER) test

# Regenerates Drift's code (*.g.dart) and migration snapshots. The output is
# COMMITTED: app-analyze and app-test must stay green from a clean checkout
# without running codegen, so a schema change that skips this target fails
# loudly in review instead of silently drifting from the generated code.
app-gen:
	@cd $(APP_DIR) && dart run build_runner build --delete-conflicting-outputs

# The schema-bump sequence, in the only order that leaves a clean tree. Run
# this FIRST after editing schema.drift + bumping schemaVersion, then app-gen.
#
# make-migrations records the new version into drift_schemas/, but it also
# rewrites every test/drift/bond/generated/schema_v*.dart snapshot WITH data
# classes — ~30k lines that do not compile here, because the
# `to_json AS recipientsJson` column rename does not survive into them (the
# generated class declares `final String toJson;`, colliding with the
# inherited `toJson()` method in every file). The second command regenerates
# the snapshots in this repo's committed style (no data classes), restoring
# v1..vN byte-for-byte and emitting the new version to match.
app-migrations:
	@cd $(APP_DIR) && dart run drift_dev make-migrations
	@cd $(APP_DIR) && dart run drift_dev schema generate drift_schemas/bond/ test/drift/bond/generated/

# Does the target server uphold the contract every bench below assumes?
#
# This replaced the `curl /health` guards the benches used to open with, which
# answered a question nobody was asking: /health said a PROCESS was listening
# and nothing about whether it accepts this app's request body, honours a JSON
# schema, constrains decoding, or reports the tokens a throughput number is
# divided by. A candidate runtime may not even serve /health. This runs the
# real prompts and the real schemas and fails with the actionable sentence.
#
# It is also the one live test that asserts — see the file's own header for why
# a contract is not a judgement.
bench-verify:
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_target_verify_test.dart --run-skipped --plain-name 'bulk slot' $(BENCH_DEFINES)

# The same, for the prose slot: naming and drafting, and `draft_reply`'s nested
# options array, which is the schema a partial grammar implementation chokes on.
bench-verify-prose:
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_target_verify_test.dart --run-skipped --plain-name 'prose slot' $(BENCH_DEFINES)

# Live, not a gate: replays the fixture corpus through the real task prompts
# and prints a latency table. The test file is @Skip'd so `make app-test` never
# depends on a server being up; --run-skipped is what actually runs it here.
#
# Runs against the BULK slot, not :$(MODEL_PORT): after phase 3 triage and
# extraction are the fast server's work, so benching them anywhere else would
# be measuring a path the app no longer takes.
#
# The `:` arm of every $(if) below is load-bearing — an empty command after an
# @ is a make error, so BENCH_VERIFY=0 needs a no-op to expand to.
bench:
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify,:)
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_bench_live_test.dart --run-skipped $(BENCH_DEFINES)

# The prose slot's own bench: five storylines named and five replies drafted,
# every answer printed verbatim. No scorecard — a title and a draft are judged
# by reading them, which is why this one prints more than it measures.
bench-prose:
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify-prose,:)
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_prose_live_test.dart --run-skipped $(BENCH_DEFINES)

# Side-by-side: the same corpus through triage and extraction on BOTH servers,
# printing where the 4B and the 27B disagree and what each cost. Live and never
# a gate — agreement is a judgement about labels, not a defect to fail on.
#
# Both slots are verified, because both are measured: a comparison against an
# unverified server is a comparison against a number, not a runtime.
ab:
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify,:)
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify-prose,:)
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_ab_live_test.dart --run-skipped $(BENCH_DEFINES)

# The membership eval set through the confirm task on BOTH servers, printing
# where each lands against the answer a person would give. Live and never a
# gate, for `ab`'s reason: a verdict is a judgement, not a defect to fail on.
ab-membership:
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify,:)
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify-prose,:)
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_membership_live_test.dart --run-skipped $(BENCH_DEFINES)

# The drain race live: one round per concurrency in BENCH_K (default 1,3) over
# the same backlog on the bulk server, which needs parallel slots to show
# anything — start it with FAST_SLOTS >= max(K) or the high rounds measure
# queue-wait instead. The check that re-verified the atomic-claim redesign
# against real inference, and the only bench that can see batching at all.
drain:
	@$(if $(filter-out 0,$(BENCH_VERIFY)),$(MAKE) --no-print-directory bench-verify,:)
	@cd $(APP_DIR) && $(FLUTTER) test test/llm_drain_live_test.dart --run-skipped $(BENCH_DEFINES)

# Two runs, side by side. The benches above each leave a JSON file in
# $(BENCH_OUT); this is what turns two of them into a decision.
bench-compare:
	@test -n "$(A)" -a -n "$(B)" || { \
	   printf "$(RED)✗$(RESET) usage: make bench-compare A=<a.json> B=<b.json>\n"; \
	   printf "    results land in $(BENCH_OUT)\n"; exit 1; }
	@cd $(APP_DIR) && dart run tool/bench_compare.dart '$(A)' '$(B)'

app-analyze:
	@cd $(APP_DIR) && $(FLUTTER) analyze

# ── vendored sqlite-vec sources ────────────────────────────────────────
# The four C/H files under $(VEC_SRC) are COMMITTED, not fetched at build
# time. `flutter test` and `flutter build` compile them through the
# sqlite_vec_ffi hook package, and a clean checkout has to build with no
# network at all — a build hook that downloads is a build that fails on a
# plane, in CI without egress, and the day a release asset is renamed.
#
# So this target exists only to (re-)vendor, and it verifies what it fetched.
# Note WHY the pins are literals here rather than read from the release: the
# sqlite-vec release publishes a checksums.txt that covers the prebuilt
# loadable binaries ONLY — the amalgamation tarball is not in it. There is
# nothing upstream to check against, so these two SHA-256 values were measured
# by hand at vendor time and any re-vendor is checked against them. A mismatch
# means the asset changed under the tag, which is a thing to investigate, not
# to wave through.
#
# sqlite-vec.c includes <sqlite3ext.h>, which the amalgamation does NOT ship.
# Those headers come from SQLite's own amalgamation zip, and the version must
# TRACK the SQLite the app actually links: the sqlite3 Dart package compiles
# its own SQLite from source in its build hook, and sqlite3 3.5.2 pulls
# sqlite-amalgamation-3500200. Bumping the sqlite3 package means bumping
# SQLITE_AMALGAMATION here too, or the extension is compiled against one
# API-routines struct and loaded into another.
VEC_VERSION     := 0.1.9
VEC_SHA256      := 3acd67cb4aff080c7050926fd3cf8227905fe5b7ee3829d8ee5024ab1283cf61
SQLITE_AMALGAMATION := sqlite-amalgamation-3500200
SQLITE_SHA256   := 387991de2834b5da2894119ff4173a9ea0779ea55ebcf53d9a40b24d1dc2484e
VEC_URL := https://github.com/asg017/sqlite-vec/releases/download/v$(VEC_VERSION)/sqlite-vec-$(VEC_VERSION)-amalgamation.tar.gz
SQLITE_URL := https://sqlite.org/2025/$(SQLITE_AMALGAMATION).zip
VEC_SRC := $(APP_DIR)/packages/sqlite_vec_ffi/src

vec-vendor:
	@tmp=$$(mktemp -d) || exit 1; \
	 trap 'rm -rf "$$tmp"' EXIT; \
	 printf "$(BLUE)==>$(RESET) [1/2] sqlite-vec $(VEC_VERSION) amalgamation\n"; \
	 curl -sfL -o "$$tmp/vec.tar.gz" "$(VEC_URL)" || { \
	   printf "  $(RED)✗$(RESET) download failed: $(VEC_URL)\n"; exit 1; }; \
	 got=$$(shasum -a 256 "$$tmp/vec.tar.gz" | awk '{print $$1}'); \
	 if [ "$$got" != "$(VEC_SHA256)" ]; then \
	   printf "  $(RED)✗$(RESET) SHA256 mismatch for sqlite-vec-$(VEC_VERSION)-amalgamation.tar.gz\n"; \
	   printf "        want $(VEC_SHA256)\n"; \
	   printf "        got  %s\n" "$$got"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) %s\n" "$$got"; \
	 printf "$(BLUE)==>$(RESET) [2/2] $(SQLITE_AMALGAMATION) headers\n"; \
	 curl -sfL -o "$$tmp/sqlite.zip" "$(SQLITE_URL)" || { \
	   printf "  $(RED)✗$(RESET) download failed: $(SQLITE_URL)\n"; exit 1; }; \
	 got=$$(shasum -a 256 "$$tmp/sqlite.zip" | awk '{print $$1}'); \
	 if [ "$$got" != "$(SQLITE_SHA256)" ]; then \
	   printf "  $(RED)✗$(RESET) SHA256 mismatch for $(SQLITE_AMALGAMATION).zip\n"; \
	   printf "        want $(SQLITE_SHA256)\n"; \
	   printf "        got  %s\n" "$$got"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) %s\n" "$$got"; \
	 mkdir -p $(VEC_SRC); \
	 tar -xzf "$$tmp/vec.tar.gz" -C "$$tmp" sqlite-vec.c sqlite-vec.h || exit 1; \
	 unzip -qo "$$tmp/sqlite.zip" \
	   "$(SQLITE_AMALGAMATION)/sqlite3.h" "$(SQLITE_AMALGAMATION)/sqlite3ext.h" \
	   -d "$$tmp" || exit 1; \
	 cp "$$tmp/sqlite-vec.c" "$$tmp/sqlite-vec.h" $(VEC_SRC)/; \
	 cp "$$tmp/$(SQLITE_AMALGAMATION)/sqlite3.h" \
	    "$$tmp/$(SQLITE_AMALGAMATION)/sqlite3ext.h" $(VEC_SRC)/; \
	 for f in sqlite-vec.c sqlite-vec.h sqlite3.h sqlite3ext.h; do \
	   printf "  $(GREEN)✓$(RESET) %8s  $(VEC_SRC)/%s\n" \
	     "$$(du -h $(VEC_SRC)/$$f | cut -f1)" "$$f"; \
	 done; \
	 printf "  $(YELLOW)!$(RESET) these are committed — include them in the diff\n"

app-build:
	@cd $(APP_DIR) && $(FLUTTER) build macos --release $(APP_SECRET_DEFINE) $(APP_LLM_DEFINES)
	@printf "  $(GREEN)✓$(RESET) $(APP_DIR)/build/macos/Build/Products/Release/bond_inbox.app\n"

# This exists because a corrupt download does NOT announce itself. A
# concurrent writer once clobbered the 19GB blob mid-pull and every cheap
# check passed afterwards: the file was full length, llama-server mmap'd it
# and loaded without an error, the port bound, /health returned 200 — and the
# model emitted endless '0's. Hashing is the only reliable detector.
#
# It is also nearly free to do: HF's cache is content-addressed, so each file
# in blobs/ is named by its own SHA256 and the expected hash is the basename.
# No manifest to fetch, no network.
verify:
	@test -d $(MODEL_CACHE)/blobs || { \
	   printf "$(RED)✗$(RESET) no model downloaded yet — run: make setup\n"; exit 1; }
	@printf "  hashing %s of blobs, takes a minute…\n" \
	   "$$(du -sh $(MODEL_CACHE)/blobs 2>/dev/null | cut -f1)"
	@bad=0; n=0; \
	 for f in $(MODEL_CACHE)/blobs/*; do \
	   [ -f "$$f" ] || continue; \
	   n=$$((n + 1)); \
	   want=$$(basename "$$f"); \
	   got=$$(shasum -a 256 "$$f" | awk '{print $$1}'); \
	   size=$$(du -h "$$f" | cut -f1); \
	   if [ "$$got" = "$$want" ]; then \
	     printf "  $(GREEN)✓$(RESET) %6s  %s\n" "$$size" "$$want"; \
	   else \
	     printf "  $(RED)✗$(RESET) %6s  %s\n" "$$size" "$$want"; \
	     printf "        got %s\n" "$$got"; \
	     bad=1; \
	   fi; \
	 done; \
	 if [ $$n -eq 0 ]; then \
	   printf "$(RED)✗$(RESET) no model downloaded yet — run: make setup\n"; exit 1; \
	 fi; \
	 if [ $$bad -ne 0 ]; then \
	   printf "  $(RED)corrupt download — run: make clean-model && make model$(RESET)\n"; \
	   exit 1; \
	 fi; \
	 printf "  $(GREEN)✓$(RESET) %s blob(s) match their SHA256\n" "$$n"

# Refuses to run while llama-server is alive, and not just out of tidiness:
# the weights are mmap'd, so rm-ing them under a live server unlinks the
# directory entries while the process keeps the inodes pinned — the ~19GB
# stays consumed until it exits, and a re-download racing the still-open old
# file is precisely how you manufacture the silent corruption `make verify`
# exists to catch.
clean-model:
	@if pgrep -x llama-server >/dev/null 2>&1; then \
	   printf "  $(RED)✗$(RESET) llama-server is running — make stop first\n"; \
	   exit 1; \
	 fi
	@if [ ! -d $(MODEL_CACHE) ]; then \
	   printf "  nothing to remove — no $(MODEL_CACHE)\n"; \
	   exit 0; \
	 fi; \
	 printf "  removing %s (%s)\n" "$(MODEL_CACHE)" \
	   "$$(du -sh $(MODEL_CACHE) 2>/dev/null | cut -f1)"; \
	 rm -rf $(MODEL_CACHE); \
	 printf "  $(GREEN)✓$(RESET) removed — the next 'make model' re-downloads ~19GB\n"

# Not a plain timeout: on a cold machine llama-server spends many minutes
# pulling ~19GB of weights BEFORE it opens the port, so failing here is the
# expected first-run outcome and the message says so rather than reading as
# a crash.
_wait-model:
	@for i in $$(seq 1 $(WAIT_TIMEOUT)); do \
	   pid=$$(lsof -nP -iTCP:$(MODEL_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	   if [ -n "$$pid" ]; then \
	     printf "  $(GREEN)✓$(RESET) model bound :$(MODEL_PORT) (pid $$pid)\n"; \
	     exit 0; \
	   fi; \
	   sleep 1; \
	 done; \
	 printf "  $(YELLOW)!$(RESET) model has not bound :$(MODEL_PORT) after $(WAIT_TIMEOUT)s\n"; \
	 printf "    On the FIRST run this is EXPECTED, not a failure: llama-server\n"; \
	 printf "    downloads ~19GB of weights for $(MODEL_HF)\n"; \
	 printf "    before it binds the port.\n"; \
	 printf "    Watch it:   make logs\n"; \
	 printf "    'make status' flips to [up] once loading finishes.\n"; \
	 exit 1

# The embedding model is ~600MB rather than ~19GB, so unlike _wait-model a
# timeout here really is a failure worth reading the log over.
_wait-embed:
	@for i in $$(seq 1 $(WAIT_TIMEOUT)); do \
	   pid=$$(lsof -nP -iTCP:$(EMBED_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	   if [ -n "$$pid" ]; then \
	     printf "  $(GREEN)✓$(RESET) embed bound :$(EMBED_PORT) (pid $$pid)\n"; \
	     exit 0; \
	   fi; \
	   sleep 1; \
	 done; \
	 printf "  $(YELLOW)!$(RESET) embed has not bound :$(EMBED_PORT) after $(WAIT_TIMEOUT)s\n"; \
	 printf "    On the FIRST run it is downloading $(EMBED_HF)\n"; \
	 printf "    (~600MB) — much smaller than the chat model, so give it a\n"; \
	 printf "    moment and re-run. Otherwise the log has the reason:\n"; \
	 printf "    tail -f $(LOG_DIR)/model-$(EMBED_PORT).log\n"; \
	 exit 1

# Between the two: ~4.3GB is a real download but not a $(SETUP_WAIT)-sized one,
# so a timeout here is worth a look at the log rather than assumed to be the
# first run.
_wait-fast:
	@for i in $$(seq 1 $(WAIT_TIMEOUT)); do \
	   pid=$$(lsof -nP -iTCP:$(FAST_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	   if [ -n "$$pid" ]; then \
	     printf "  $(GREEN)✓$(RESET) fast bound :$(FAST_PORT) (pid $$pid)\n"; \
	     exit 0; \
	   fi; \
	   sleep 1; \
	 done; \
	 printf "  $(YELLOW)!$(RESET) fast has not bound :$(FAST_PORT) after $(WAIT_TIMEOUT)s\n"; \
	 printf "    On the FIRST run it is downloading $(FAST_HF)\n"; \
	 printf "    (~4.3GB) — give it a few minutes and re-run. Otherwise the\n"; \
	 printf "    log has the reason:\n"; \
	 printf "    tail -f $(LOG_DIR)/model-$(FAST_PORT).log\n"; \
	 exit 1

# The one wait loop that asks the APP rather than the kernel. oMLX's uvicorn
# binds the port immediately and then spends ~70s on startup before
# /v1/chat/completions answers, so the lsof probe the three loops above use
# would report "up" a minute early — and a bench launched against a bound but
# unready server collects connection-level 503s and calls them the candidate's
# numbers. A 200 from /v1/models is the earliest honest signal.
_wait-omlx:
	@for i in $$(seq 1 $(WAIT_TIMEOUT)); do \
	   code=$$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$(OMLX_PORT)/v1/models 2>/dev/null); \
	   if [ "$$code" = "200" ]; then \
	     printf "  $(GREEN)✓$(RESET) omlx answering :$(OMLX_PORT) (after %ss)\n" "$$i"; \
	     exit 0; \
	   fi; \
	   sleep 1; \
	 done; \
	 printf "  $(YELLOW)!$(RESET) omlx has not answered :$(OMLX_PORT) after $(WAIT_TIMEOUT)s\n"; \
	 printf "    Nothing is downloading here — oMLX serves models that are\n"; \
	 printf "    ALREADY in the HuggingFace cache, so a missing model is a\n"; \
	 printf "    silent absence rather than a wait. Pull one first and see\n"; \
	 printf "    docs/model-bakeoff.md for the hf command and the serving ids.\n"; \
	 printf "    The log has the reason:\n"; \
	 printf "    tail -f $(LOG_DIR)/omlx-$(OMLX_PORT).log\n"; \
	 exit 1
