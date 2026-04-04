#!/usr/bin/env python3
"""
Rare Clojure-family + categorical VM embedding pipeline.
Uses Gemini embedding API (gemini-embedding-001) to embed source chunks
from 11 languages into a shared vector space.

Languages:
  Lisp-family:    Shen (.shen), Carp (.carp), Hy (.hy), Fennel (.fnl),
                  Janet (.janet), LFE (.lfe), Ferret (ferret.org)
  Clojure-native: jank (.jank), nanoclj-zig (.zig)
  Blockchain VMs: chialisp (.py CLVM), Geb (.lisp), Juvix (.juvix)

Usage:
  GEMINI_API_KEY=... python3 embed.py [--dim 768] [--out embeddings.jsonl]
"""

import os, sys, json, time, glob, hashlib
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

API_KEY = os.environ.get("GEMINI_API_KEY", "")
MODEL = "gemini-embedding-001"
ENDPOINT = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:embedContent"
CHUNK_SIZE = 1800  # tokens ~= chars/4, stay under 2048 token limit
OVERLAP = 200
DIM = int(sys.argv[sys.argv.index("--dim") + 1]) if "--dim" in sys.argv else 768
OUT = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "embeddings.jsonl"

CORPORA = {
    "shen":      {"dir": "shen",      "exts": [".shen"],   "family": "lisp"},
    "carp":      {"dir": "carp",      "exts": [".carp"],   "family": "lisp"},
    "jank":      {"dir": "jank",      "exts": [".jank"],   "family": "clojure"},
    "ferret":    {"dir": "ferret",    "exts": [".org"],    "family": "clojure"},
    "hy":        {"dir": "hy",        "exts": [".hy"],     "family": "lisp"},
    "fennel":    {"dir": "fennel",    "exts": [".fnl"],    "family": "lisp"},
    "janet":     {"dir": "janet",     "exts": [".janet"],  "family": "lisp"},
    "lfe":       {"dir": "lfe",       "exts": [".lfe"],    "family": "lisp"},
    "chialisp":  {"dir": "chialisp",  "exts": [".py"],     "family": "blockchain"},
    "geb":       {"dir": "geb",       "exts": [".lisp"],   "family": "categorical"},
    "juvix":     {"dir": "juvix",     "exts": [".juvix"],  "family": "categorical"},
    "nanoclj":   {"dir": "../src",    "exts": [".zig"],    "family": "clojure"},
}

def chunk_text(text, size=CHUNK_SIZE, overlap=OVERLAP):
    chunks = []
    i = 0
    while i < len(text):
        end = min(i + size, len(text))
        chunks.append(text[i:end])
        i += size - overlap
    return chunks

def embed_text(text, task_type="RETRIEVAL_DOCUMENT"):
    if not API_KEY:
        return None
    body = json.dumps({
        "model": f"models/{MODEL}",
        "content": {"parts": [{"text": text[:8000]}]},
        "outputDimensionality": DIM,
        "taskType": task_type,
    }).encode()
    req = Request(
        f"{ENDPOINT}?key={API_KEY}",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urlopen(req) as resp:
            data = json.loads(resp.read())
            return data.get("embedding", {}).get("values")
    except HTTPError as e:
        print(f"  API error {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
        if e.code == 429:
            time.sleep(5)
            return embed_text(text, task_type)  # retry once
        return None

def collect_files(lang, info):
    base = Path(__file__).parent / info["dir"]
    files = []
    for ext in info["exts"]:
        files.extend(base.rglob(f"*{ext}"))
    # skip .git, node_modules, test fixtures
    files = [f for f in files if ".git/" not in str(f) and "node_modules" not in str(f)]
    return sorted(files)

def main():
    if not API_KEY:
        print("WARNING: No GEMINI_API_KEY set. Will collect chunks but skip embedding.", file=sys.stderr)
        print("Set GEMINI_API_KEY=... to enable embedding.", file=sys.stderr)

    total_chunks = 0
    total_embedded = 0
    stats = {}

    with open(OUT, "w") as out:
        for lang, info in CORPORA.items():
            files = collect_files(lang, info)
            lang_chunks = 0
            print(f"\n{'='*60}")
            print(f"  {lang} ({info['family']}) — {len(files)} files")
            print(f"{'='*60}")

            for fpath in files:
                try:
                    text = fpath.read_text(errors="replace")
                except:
                    continue
                if len(text.strip()) < 50:
                    continue

                chunks = chunk_text(text)
                for ci, chunk in enumerate(chunks):
                    chunk_id = hashlib.sha256(f"{lang}:{fpath}:{ci}".encode()).hexdigest()[:16]
                    record = {
                        "id": chunk_id,
                        "lang": lang,
                        "family": info["family"],
                        "file": str(fpath.relative_to(Path(__file__).parent)),
                        "chunk_idx": ci,
                        "text": chunk[:500],  # truncated for JSONL readability
                        "text_len": len(chunk),
                    }

                    if API_KEY:
                        vec = embed_text(chunk)
                        if vec:
                            record["embedding"] = vec
                            total_embedded += 1
                        time.sleep(0.05)  # rate limit: ~20 req/s

                    out.write(json.dumps(record) + "\n")
                    lang_chunks += 1
                    total_chunks += 1

            stats[lang] = {"files": len(files), "chunks": lang_chunks}
            print(f"  → {len(files)} files, {lang_chunks} chunks")

    print(f"\n{'='*60}")
    print(f"  TOTALS: {total_chunks} chunks, {total_embedded} embedded")
    print(f"  Output: {OUT}")
    print(f"{'='*60}")

    # Write summary
    with open("embed_stats.json", "w") as f:
        json.dump({
            "model": MODEL,
            "dimensions": DIM,
            "total_chunks": total_chunks,
            "total_embedded": total_embedded,
            "languages": stats,
            "comparison_note": (
                "CLVM (Chia) = minimal untyped Lisp VM, tree-rewriting, ~40 opcodes. "
                "Geb (Anoma) = categorical IR (bicartesian closed), STLC→VampIR circuits. "
                "Juvix = Haskell-like frontend → Geb/Nock/Cairo/WASM/native. "
                "nanoclj-zig = Clojure dialect in Zig, persistent data, miniKanren, bytecode VM."
            ),
        }, f, indent=2)

if __name__ == "__main__":
    main()
