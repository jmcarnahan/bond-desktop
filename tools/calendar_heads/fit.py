#!/usr/bin/env python3
"""Fit the Day bar's command head on the decision encoder's raw vectors.

The command head is a second linear head on the decision model's encoder
(plan section 1.1, docs/pipeline/14-calendar.md "Commands"): the typed command
goes to the decision server exactly as the app's `DecisionClient.embedRaw`
sends it, the raw mean-pooled vector comes back, and a multinomial logistic
regression names the action. The app applies the result in Dart
(`CommandHeads.apply`), so this file writes only numbers, in the shape
`CommandHeads.load` accepts:

  {"format": "bond-command-heads/1", "encoder_qhash": <qhash>,
   "encoder_model": <model>, "input": "raw-text/1",
   "fields": {"action": {"options": [...ten wire words...],
                         "weight": [[...dim...] x 10], "bias": [...10...],
                         "temperature": T}},
   "fitted": {"n_train", "n_heldout", "heldout_acc",
              "lexicon_heldout_acc": null, ...}}

Steps:

  0. Read the installed decision heads (`--decide-heads`, the
     `decide-heads.json` beside the GGUF `make decide` serves) for the two
     things that name the encoder: its question hash (`qhash`, written as
     `encoder_qhash`) and the model's own name (`model`, written as
     `encoder_model`). The app refuses the head when the installed heads name
     another model, so a head is tied to the model it was fitted on, not only
     to its question set.
  1. Embed. The server is asked the identity question the app asks first
     (`/tokenize` of "a" with the specials must be ModernBERT's [CLS] ... [SEP])
     and then `/v1/embeddings` with `embd_normalize: -1`, in batches of 32.
     A vector of another width, or one whose norm is ~1 (the server ignored
     the field), stops the fit: a head fitted on those would be fitted on the
     wrong numbers.
  2. Fit. L2-regularised softmax regression by gradient descent (Adam) on
     standardised features, the weights folded back onto the RAW vector so
     the app needs no scaler. The L2 weight is chosen from a small grid by
     5-fold cross-validation on train; the temperature is then fitted by
     minimising the negative log-likelihood on one fold the weights did not
     see.
  3. Evaluate on the held-out file: accuracy, per-class recall, the most
     frequent confusions, and how many answers clear the app's 0.80 bar.
     With --heldout-hard, the accuracy on that harder set too (indirect
     phrasings and typos sharing no template with train), recorded as
     fitted.heldout_hard_acc; it chooses nothing.
  4. Write the file -- under tmp/ by default, never straight into the app's
     asset: the owner reads the adoption line the Dart leg prints and ships
     the head with `make calendar-heads-adopt`. The lexicon's held-out
     accuracy is the Dart side's number
     (`test/calendar_command_heldout_test.dart`), so it is left null.

Prints counts, accuracies and enum words only -- never a command's text.
Exits non-zero when the installed heads cannot be read, the server is down,
is not the decision model, answers the wrong width or out-of-range indexes,
or normalises.

numpy only; the server is spoken to with urllib.
"""

import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

import numpy as np

# The head's options, in `CommandAction` order without `unknown`. The Dart
# loader refuses a file whose options differ in any way.
ACTIONS = [
    "create",
    "move",
    "cancel",
    "rsvp_yes",
    "rsvp_no",
    "rsvp_maybe",
    "find_time",
    "ask_free",
    "ask_agenda",
    "ask_person",
]

# The encoder's width, and ModernBERT's specials (`DecisionClient.clsId`,
# `sepId`).
WIDTH = 1024
CLS_ID, SEP_ID = 50281, 50282

BATCH = 32
L2_GRID = (1e-3, 1e-2, 1e-1)
FOLDS = 5
# The app's bar (`DecisionCommandClassifier.bar`), for the coverage line.
BAR = 0.80


def fail(message):
    print(f"calendar-heads: {message}", file=sys.stderr)
    sys.exit(1)


def post(url, body, bearer=None):
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    request = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        fail(f"the decision server answered HTTP {e.code} at {url}")
    except (urllib.error.URLError, OSError):
        fail(f"no decision server answering at {url} -- run make decide "
             f"(or point DECIDE_URL at one)")
    except ValueError:
        fail(f"the decision server at {url} did not answer with JSON")


def tokenize_url(embeddings_url):
    for suffix in ("/v1/embeddings", "/embeddings"):
        if embeddings_url.endswith(suffix):
            return embeddings_url[: -len(suffix)] + "/tokenize"
    fail("--decide-url must end in /v1/embeddings")


def check_identity(url, model, bearer):
    """The app's identity probe: the embedding model answers 1024 raw numbers
    too, and only the tokenizer tells the two apart."""
    answer = post(tokenize_url(url),
                  {"model": model, "content": "a", "add_special": True},
                  bearer)
    tokens = answer.get("tokens") if isinstance(answer, dict) else None
    if not tokens or tokens[0] != CLS_ID or tokens[-1] != SEP_ID:
        fail("the server is not the decision model: its tokenizer is not "
             "ModernBERT's")


def embed(url, model, texts, bearer):
    """Raw vectors for `texts`, in order, checked the way the app checks
    them."""
    out = []
    for start in range(0, len(texts), BATCH):
        chunk = texts[start:start + BATCH]
        answer = post(url, {
            "model": model,
            # One text goes as a string, as the app sends it; a batch as a
            # list of strings.
            "input": chunk[0] if len(chunk) == 1 else chunk,
            "embd_normalize": -1,
        }, bearer)
        data = answer.get("data") if isinstance(answer, dict) else None
        if not isinstance(data, list) or len(data) != len(chunk):
            fail("the decision server answered the wrong number of vectors")
        vectors = [None] * len(chunk)
        for position, item in enumerate(data):
            index = item.get("index", position) if isinstance(item, dict) \
                else None
            # An index outside the batch, or one given twice, would put a
            # vector against the wrong command's label.
            if (not isinstance(index, int) or isinstance(index, bool)
                    or not 0 <= index < len(chunk)
                    or vectors[index] is not None):
                fail("the decision server answered a vector with a bad index")
            vectors[index] = item.get("embedding")
        for v in vectors:
            if not isinstance(v, list) or len(v) != WIDTH:
                fail(f"the decision server answered a vector of "
                     f"{len(v) if isinstance(v, list) else 'no'} numbers, "
                     f"not {WIDTH}")
        out.extend(vectors)
    x = np.asarray(out, dtype=np.float64)
    norms = np.linalg.norm(x, axis=1)
    if np.any(np.abs(norms - 1.0) <= 1e-3):
        fail("the decision server normalised its vectors (embd_normalize: -1 "
             "ignored); the head reads only raw vectors")
    return x


def read_decide_heads(path):
    """The installed decision heads' question hash and model name -- what the
    command head is tied to. Only those two fields and the width are read."""
    try:
        with open(path) as handle:
            heads = json.load(handle)
    except FileNotFoundError:
        fail(f"no decision heads at {path} -- run make decide-install (or "
             f"point DECIDE_DIR at the installed model)")
    except (OSError, ValueError):
        fail(f"the decision heads at {path} could not be read as JSON")
    if not isinstance(heads, dict):
        fail(f"the decision heads at {path} are not a JSON object")
    qhash, model = heads.get("qhash"), heads.get("model")
    if not isinstance(qhash, str) or not qhash:
        fail(f"the decision heads at {path} carry no qhash")
    if not isinstance(model, str) or not model.strip():
        fail(f"the decision heads at {path} name no model")
    if heads.get("hidden") != WIDTH:
        fail(f"the decision heads at {path} are {heads.get('hidden')} wide, "
             f"not {WIDTH}")
    return qhash, model


def read_jsonl(path):
    rows = []
    with open(path) as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    for r in rows:
        if r.get("action") not in ACTIONS:
            fail(f"{path}: a line is labelled {r.get('action')!r}, not one "
                 f"of the ten actions")
    return [r["text"] for r in rows], np.array(
        [ACTIONS.index(r["action"]) for r in rows])


def softmax(logits):
    z = logits - logits.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def fit_softmax(x, y, l2, steps=1500, lr=0.05):
    """Weights (k x d) and bias (k) on standardised `x`, by Adam on the mean
    cross-entropy plus `l2` * ||W||^2 / 2."""
    n, d = x.shape
    k = len(ACTIONS)
    onehot = np.eye(k)[y]
    w = np.zeros((k, d))
    b = np.zeros(k)
    m_w, v_w = np.zeros_like(w), np.zeros_like(w)
    m_b, v_b = np.zeros_like(b), np.zeros_like(b)
    beta1, beta2, eps = 0.9, 0.999, 1e-8
    for t in range(1, steps + 1):
        p = softmax(x @ w.T + b)
        g = (p - onehot) / n
        grad_w = g.T @ x + l2 * w
        grad_b = g.sum(axis=0)
        m_w = beta1 * m_w + (1 - beta1) * grad_w
        v_w = beta2 * v_w + (1 - beta2) * grad_w ** 2
        m_b = beta1 * m_b + (1 - beta1) * grad_b
        v_b = beta2 * v_b + (1 - beta2) * grad_b ** 2
        c1, c2 = 1 - beta1 ** t, 1 - beta2 ** t
        w -= lr * (m_w / c1) / (np.sqrt(v_w / c2) + eps)
        b -= lr * (m_b / c1) / (np.sqrt(v_b / c2) + eps)
    return w, b


class Scaler:
    """Standardises for the fit, and folds a fitted head back onto raw
    vectors: W_raw = W / sigma, b_raw = b - W_raw . mu."""

    def __init__(self, x):
        self.mu = x.mean(axis=0)
        self.sigma = x.std(axis=0)
        self.sigma[self.sigma < 1e-8] = 1.0

    def apply(self, x):
        return (x - self.mu) / self.sigma

    def fold(self, w, b):
        w_raw = w / self.sigma
        return w_raw, b - w_raw @ self.mu


def fit_raw(x, y, l2):
    scaler = Scaler(x)
    w, b = fit_softmax(scaler.apply(x), y, l2)
    return scaler.fold(w, b)


def folds_of(y, rng):
    """Stratified fold number per row."""
    fold = np.empty(len(y), dtype=int)
    for c in range(len(ACTIONS)):
        rows = np.flatnonzero(y == c)
        rng.shuffle(rows)
        fold[rows] = np.arange(len(rows)) % FOLDS
    return fold


def nll(logits, y, temperature):
    p = softmax(logits / temperature)
    return -np.mean(np.log(p[np.arange(len(y)), y] + 1e-12))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--decide-url",
                        default="http://127.0.0.1:8083/v1/embeddings",
                        help="the decision server's FULL /v1/embeddings URL")
    parser.add_argument("--model", default="bond-decide")
    parser.add_argument(
        "--train", default="app/test/fixtures/calendar_commands/train.jsonl")
    parser.add_argument(
        "--heldout",
        default="app/test/fixtures/calendar_commands/heldout.jsonl")
    parser.add_argument(
        "--heldout-hard", default=None,
        help="optional: a harder held-out set (indirect phrasings, typos) "
             "whose accuracy is printed and recorded as "
             "fitted.heldout_hard_acc; never used to choose anything")
    parser.add_argument(
        "--decide-heads",
        default=os.path.expanduser(
            "~/Library/Application Support/com.bondinbox.app/models/"
            "local_bond-decide/decide-heads.json"),
        help="the installed decision heads file (make decide-install's "
             "decide-heads.json); its qhash and model are copied into the "
             "head as encoder_qhash and encoder_model")
    parser.add_argument(
        "--out", default="tmp/calendar_heads/command_heads.json",
        help="where the fitted head is written; the app's asset only "
             "through make calendar-heads-adopt")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    # A key for a decision server that wants one, from the environment so it
    # is never on a command line or in a log.
    bearer = os.environ.get("DECIDE_BEARER") or None
    rng = np.random.default_rng(args.seed)

    encoder_qhash, encoder_model = read_decide_heads(args.decide_heads)
    train_text, y_train = read_jsonl(args.train)
    held_text, y_held = read_jsonl(args.heldout)
    hard_text, y_hard = (read_jsonl(args.heldout_hard) if args.heldout_hard
                         else ([], None))

    check_identity(args.decide_url, args.model, bearer)
    x_train = embed(args.decide_url, args.model, train_text, bearer)
    x_held = embed(args.decide_url, args.model, held_text, bearer)
    x_hard = (embed(args.decide_url, args.model, hard_text, bearer)
              if hard_text else None)
    print(f"embedded {len(train_text)} train and {len(held_text)} held-out "
          f"commands ({WIDTH} wide, raw)")

    # (2) The L2 weight by 5-fold cross-validation on train.
    fold = folds_of(y_train, rng)
    best = None
    for l2 in L2_GRID:
        correct = 0
        for f in range(FOLDS):
            fit_rows, val_rows = fold != f, fold == f
            w, b = fit_raw(x_train[fit_rows], y_train[fit_rows], l2)
            predicted = (x_train[val_rows] @ w.T + b).argmax(axis=1)
            correct += int((predicted == y_train[val_rows]).sum())
        accuracy = correct / len(y_train)
        print(f"  l2 {l2:g}: cv accuracy = {accuracy:.3f}")
        if best is None or accuracy > best[1]:
            best = (l2, accuracy)
    l2 = best[0]

    # The temperature on a fold the weights did not see.
    fit_rows, val_rows = fold != 0, fold == 0
    w, b = fit_raw(x_train[fit_rows], y_train[fit_rows], l2)
    logits = x_train[val_rows] @ w.T + b
    grid = np.exp(np.linspace(np.log(0.05), np.log(20.0), 121))
    temperature = float(min(grid, key=lambda t: nll(logits, y_train[val_rows],
                                                    t)))
    print(f"chosen l2 = {l2:g}, temperature = {temperature:.3f}")

    # The head itself, on all of train.
    w, b = fit_raw(x_train, y_train, l2)

    # (3) Held out.
    probabilities = softmax((x_held @ w.T + b) / temperature)
    predicted = probabilities.argmax(axis=1)
    accuracy = float((predicted == y_held).mean())
    print(f"head heldout accuracy = {accuracy:.3f} (n={len(y_held)})")
    for c, action in enumerate(ACTIONS):
        rows = y_held == c
        if rows.any():
            hits = int((predicted[rows] == c).sum())
            print(f"  {action:<11} {hits / rows.sum():.3f} "
                  f"({hits}/{int(rows.sum())})")
    confusions = {}
    for gold, said in zip(y_held, predicted):
        if gold != said:
            key = (ACTIONS[gold], ACTIONS[said])
            confusions[key] = confusions.get(key, 0) + 1
    if confusions:
        print("most frequent confusions (gold -> head):")
        for (gold, said), count in sorted(confusions.items(),
                                          key=lambda kv: -kv[1])[:8]:
            print(f"  {gold} -> {said}: {count}")
    confident = probabilities.max(axis=1) >= BAR
    if confident.any():
        above = float((predicted[confident] == y_held[confident]).mean())
        print(f"above the {BAR:.2f} bar: {int(confident.sum())}/{len(y_held)}"
              f", accuracy there = {above:.3f}")
    else:
        print(f"above the {BAR:.2f} bar: 0/{len(y_held)}")

    # The harder held-out set, when given: reported only, after every choice
    # above was made without it.
    hard_accuracy = None
    if x_hard is not None:
        hard_predicted = softmax((x_hard @ w.T + b) / temperature).argmax(axis=1)
        hard_accuracy = float((hard_predicted == y_hard).mean())
        print(f"head heldout_hard accuracy = {hard_accuracy:.3f} "
              f"(n={len(y_hard)})")
        for c, action in enumerate(ACTIONS):
            rows = y_hard == c
            if rows.any():
                hits = int((hard_predicted[rows] == c).sum())
                print(f"  {action:<11} {hits / rows.sum():.3f} "
                      f"({hits}/{int(rows.sum())})")

    # (4) The file, in `CommandHeads.load`'s shape.
    head = {
        "format": "bond-command-heads/1",
        "encoder_qhash": encoder_qhash,
        "encoder_model": encoder_model,
        "input": "raw-text/1",
        "fields": {
            "action": {
                "options": ACTIONS,
                "weight": [[float(f"{v:.7g}") for v in row] for row in w],
                "bias": [float(f"{v:.7g}") for v in b],
                "temperature": temperature,
            },
        },
        "fitted": {
            "n_train": int(len(y_train)),
            "n_heldout": int(len(y_held)),
            "heldout_acc": accuracy,
            "lexicon_heldout_acc": None,
            **({"n_heldout_hard": int(len(y_hard)),
                "heldout_hard_acc": hard_accuracy}
               if hard_accuracy is not None else {}),
            "l2": l2,
            "seed": args.seed,
            "date": datetime.date.today().isoformat(),
        },
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as handle:
        json.dump(head, handle, separators=(",", ":"))
        handle.write("\n")
    print(f"wrote {args.out} (encoder {encoder_model}, question set "
          f"{encoder_qhash}); ship it with make calendar-heads-adopt after "
          f"reading the adoption line below")


if __name__ == "__main__":
    main()
