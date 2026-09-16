#!/usr/bin/env python3
"""Offline retrieval evaluation against a synthetic, intent-labelled corpus."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time

MODES = ("search", "recall", "hook-off", "hook-on", "hook-selective")
SLUG = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)*\Z")
K = 5


def load_corpus(path):
    corpus = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(corpus, dict) or corpus.get("schema_version") != 1:
        raise ValueError("corpus schema_version must be 1")
    memories, cases = corpus["memories"], corpus["cases"]
    if not isinstance(memories, list) or not isinstance(cases, list) or not memories or not cases:
        raise ValueError("corpus needs memories and cases")
    slugs = set()
    for memory in memories:
        if not isinstance(memory, dict):
            raise ValueError("memory must be an object")
        slug = memory["slug"]
        if not isinstance(slug, str) or not SLUG.fullmatch(slug) or slug in slugs:
            raise ValueError("invalid or duplicate memory slug")
        slugs.add(slug)
        for field in ("name", "description", "type", "status", "body"):
            if not isinstance(memory[field], str):
                raise ValueError("memory fields must be strings")
        for field in ("name", "description"):
            if any(c in memory[field] for c in '\n\r"\\'):
                raise ValueError("memory name/description must be simple single-line scalars")
        if memory["type"] not in ("project", "reference", "feedback", "user"):
            raise ValueError("unsupported memory type")
        if memory["status"] not in ("active", "stale", "superseded", "archived"):
            raise ValueError("unsupported memory status")
        if not isinstance(memory["tags"], list) or not all(isinstance(t, str) for t in memory["tags"]):
            raise ValueError("tags must be a string list")
        if any(not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", tag) for tag in memory["tags"]):
            raise ValueError("tags must be kebab-case")
    ids = set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("case must be an object")
        for field in ("id", "category", "query", "prompt", "rationale"):
            if not isinstance(case[field], str) or not case[field].strip():
                raise ValueError("case fields must be nonempty strings")
        if case["id"] in ids:
            raise ValueError("duplicate case id")
        ids.add(case["id"])
        relevant = case["relevant"]
        if not isinstance(relevant, list) or not all(isinstance(s, str) for s in relevant):
            raise ValueError("relevant must be a slug list")
        if len(set(relevant)) != len(relevant) or not set(relevant) <= slugs:
            raise ValueError("duplicate or unknown relevance label")
    return corpus


def metrics(retrieved, relevant):
    """P@5 uses five slots, including empty slots; negatives scored separately."""
    top = retrieved[:K]
    hits = len(set(top) & set(relevant))
    return {
        "precision_at_5": hits / K if relevant else None,
        "recall_at_5": hits / len(relevant) if relevant else None,
        "returned_precision_at_5": (hits / len(top) if top else 0.0) if relevant else None,
        "no_hit_correct": not retrieved if not relevant else None,
    }


def percentile95(values):
    return sorted(values)[math.ceil(0.95 * len(values)) - 1]


def clean_environment():
    # Explicit store isolation also prevents inherited hook budgets/configuration
    # from silently changing the measurement. Never consult the user's store.
    return {k: v for k, v in os.environ.items()
            if not k.startswith(("KNOWLEDGE_", "KM_", "GIT_"))
            and k not in ("BASH_ENV", "ENV")}


def materialize(corpus, root):
    # A real empty local repository satisfies the store resolver; no commits,
    # credentials, network, or live memory writer are involved in fixture setup.
    subprocess.run(["git", "init", "-q", str(root)], check=True,
                   env=clean_environment(), stdin=subprocess.DEVNULL,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    store = root / ".agents" / "memory"
    store.mkdir(parents=True, mode=0o700)
    (root / ".gitignore").write_text(".agents/memory/\n", encoding="utf-8")
    index = []
    for memory in corpus["memories"]:
        # The memory parser supports block lists, not YAML/JSON flow lists.
        quote = lambda value: json.dumps(value, ensure_ascii=False)
        content = ("---\nschema_version: 1\n"
                   f"name: {quote(memory['name'])}\n"
                   f"description: {quote(memory['description'])}\n"
                   + ("tags:\n" + "".join(f"  - {tag}\n" for tag in memory["tags"]) if memory["tags"] else "")
                   +
                   f"metadata:\n  type: {memory['type']}\n"
                   f"status: {memory['status']}\n"
                   "created: 2026-01-01\nupdated: 2026-01-02\n---\n"
                   + memory["body"] + "\n")
        path = store / (memory["slug"] + ".md")
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)
        index.append(f"- [{memory['name']}]({memory['slug']}.md) — {memory['description']}\n")
    index_path = store / "MEMORY.md"
    index_path.write_text("".join(index), encoding="utf-8")
    index_path.chmod(0o600)
    return store


def parse_slugs(mode, output):
    if mode == "search":
        rows = [line.split("\t") for line in output.splitlines()]
        if any(len(row) != 5 for row in rows):
            raise ValueError("unexpected search TSV format")
        slugs = [row[1] for row in rows]
    elif mode == "recall":
        if not output.startswith("# recall: untrusted context"):
            raise ValueError("missing recall envelope")
        slugs = re.findall(r"^## ([a-z0-9_]+) \(score ", output, re.M)
    else:
        if output and not output.startswith("# knowledge recall: untrusted background context"):
            raise ValueError("unexpected hook envelope")
        slugs = re.findall(r"^- \[([a-z0-9_]+)\]", output, re.M)
    if len(slugs) != len(set(slugs)):
        raise ValueError("duplicate retrieved slug")
    return slugs


def invoke(scripts, store, case, mode, timeout):
    environment = clean_environment()
    environment["KNOWLEDGE_MEMORY_HOME"] = str(store)
    payload = b""
    if mode.startswith("hook-"):
        environment.update(KNOWLEDGE_AUTO_RECALL="prompt", KNOWLEDGE_AUTO_RECALL_LIMIT="5",
                           KNOWLEDGE_AUTO_RECALL_TERMS="4", KNOWLEDGE_AUTO_RECALL_BUDGET="4000",
                           KNOWLEDGE_AUTO_RECALL_GRAPH="false" if mode == "hook-off" else "true",
                           KNOWLEDGE_AUTO_RECALL_GRAPH_MODE="selective" if mode == "hook-selective" else "all")
        command = ["bash", str(scripts / "inject-recall.sh"), "--prompt"]
        payload = json.dumps({"prompt": case["prompt"]}).encode("utf-8")
    else:
        command = ["bash", str(scripts / "memory-search.sh"), "--store", str(store), "--limit", "5"]
        if mode == "recall":
            command.append("--recall")
        command.extend(["--", case["query"]])
    start = time.perf_counter()
    # Terminate the whole helper tree on timeout, including scorer children.
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environment,
                          cwd=store.parent.parent, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(payload, timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    elapsed = (time.perf_counter() - start) * 1000
    if result.returncode:
        raise ValueError(f"{case['id']}/{mode}: helper exited {result.returncode}: "
                         + result.stderr.decode("utf-8", errors="replace")[:300])
    output = result.stdout.decode("utf-8")
    slugs = parse_slugs(mode, output)
    degraded = bool(re.search(r"^degraded:", output + result.stderr.decode("utf-8"), re.M))
    return slugs, elapsed, len(result.stdout), degraded, output


def aggregate(rows):
    result = {"cases": len(rows), "positive_cases": sum(r["recall_at_5"] is not None for r in rows),
              "negative_cases": sum(r["no_hit_correct"] is not None for r in rows)}
    for key in ("precision_at_5", "recall_at_5", "returned_precision_at_5", "no_hit_correct"):
        values = [row[key] for row in rows if row[key] is not None]
        result[key if key != "no_hit_correct" else "no_hit_accuracy"] = statistics.mean(values) if values else None
    times = [value for row in rows for value in row["latency_ms_samples"]]
    sizes = [value for row in rows for value in row["stdout_bytes_samples"]]
    result.update(latency_ms_median=statistics.median(times), latency_ms_p95=percentile95(times),
                  stdout_bytes_mean=statistics.mean(sizes), stdout_bytes_max=max(sizes))
    return result


def evaluate(args):
    corpus_hash = hashlib.sha256(args.corpus.read_bytes()).hexdigest()
    helper_names = ("memory-search.sh", "search-query.py", "recall-graph.py", "inject-recall.sh", "memory-backlinks.sh", "memory-lint.sh", "lib.sh")
    hashes = {name: hashlib.sha256((args.scripts / name).read_bytes()).hexdigest() for name in helper_names}
    corpus = load_corpus(args.corpus)
    known = {m["slug"] for m in corpus["memories"]}
    rows = []
    with tempfile.TemporaryDirectory(prefix="knowledge-eval-") as temporary:
        store = materialize(corpus, Path(temporary))
        lint = subprocess.run(["bash", str(args.scripts / "memory-lint.sh"), "--store", str(store)],
                              capture_output=True, env=clean_environment(), stdin=subprocess.DEVNULL,
                              timeout=args.timeout)
        if lint.returncode:
            raise ValueError("materialized corpus failed memory-lint: "
                             + (lint.stdout + lint.stderr).decode("utf-8", errors="replace")[:2000])
        for case in corpus["cases"]:
            for mode in args.modes:
                samples = []
                reference = None
                for iteration in range(args.warmup + args.repeats):
                    sample = invoke(args.scripts, store, case, mode, args.timeout)
                    if not set(sample[0]) <= known:
                        raise ValueError("helper returned a slug outside the synthetic corpus")
                    if reference is not None and sample[4] != reference:
                        raise ValueError(f"nondeterministic output: {case['id']}/{mode}")
                    reference = sample[4]
                    if iteration >= args.warmup:
                        samples.append(sample)
                slugs = samples[0][0]
                rows.append(dict(case_id=case["id"], category=case["category"], mode=mode,
                                 relevant=case["relevant"], retrieved=slugs, retrieved_at_5=slugs[:K],
                                 degraded=samples[0][3], **metrics(slugs, case["relevant"]),
                                 latency_ms_samples=[s[1] for s in samples],
                                 stdout_bytes_samples=[s[2] for s in samples]))
    if corpus_hash != hashlib.sha256(args.corpus.read_bytes()).hexdigest() or any(
            hashes[name] != hashlib.sha256((args.scripts / name).read_bytes()).hexdigest() for name in helper_names):
        raise ValueError("corpus or helper changed during evaluation; rerun with stable inputs")
    return {"schema_version": 1, "corpus_sha256": corpus_hash,
            "helper_sha256": hashes, "environment": {"system": platform.system(),
                "machine": platform.machine(), "python": platform.python_version()},
            "settings": {"k": K, "repeats": args.repeats, "warmup": args.warmup,
                         "timeout_seconds": args.timeout, "hook_terms": 4, "hook_byte_budget": 4000},
            "summary": {mode: aggregate([r for r in rows if r["mode"] == mode]) for mode in args.modes},
            "by_category": {mode: {category: aggregate([r for r in rows if r["mode"] == mode and r["category"] == category])
                for category in sorted({r["category"] for r in rows})} for mode in args.modes},
            "results": rows}


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=here / "fixtures" / "retrieval-eval.json")
    parser.add_argument("--scripts", type=Path, default=here, help="provider scripts directory to measure")
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--output", type=Path, help="write JSON here instead of stdout")
    args = parser.parse_args()
    if args.repeats < 1 or args.warmup < 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("repeats must be positive, warmup nonnegative, timeout finite and positive")
    if len(args.modes) != len(set(args.modes)):
        parser.error("modes must be unique")
    args.scripts = args.scripts.resolve()
    try:
        report = evaluate(args)
        rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.write_text(rendered, encoding="utf-8")
        else:
            sys.stdout.write(rendered)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print(f"evaluation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
