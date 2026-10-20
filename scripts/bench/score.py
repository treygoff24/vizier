#!/usr/bin/env python3
"""Score a live-engine bench: results.jsonl from `Vizier --bench-live`, references.jsonl from
`Vizier --bench-judge`. Prints aggregates only, never transcript text, so it is safe on real takes.

usage: python3 -I scripts/bench/score.py <results.jsonl> <references.jsonl> [vocabulary.txt]

Word error rate is pooled (all edits over all reference words) in two forms:
  words   lowercase, punctuation stripped: did it hear the right words
  typed   case and punctuation kept: is the pasted text right as typed
Filler sounds (um, uh, er, ah, hmm, mm) are dropped from both sides first; Vizier's filler filter
removes them before paste. The words form also treats spelling conventions as equal, as standard
speech-recognition scoring does: accents, "gonna"/"going to", "'cause"/"because", "alright"/"all
right", "ok"/"okay", "etc"/"et cetera", and number words zero to twenty against their digits. A
judge's reference copies one engine's conventions in some takes and another's elsewhere, so without
this a spelling choice counts as a mishearing. Term recall counts vocabulary terms the reference contains and the
engine spelled exactly. Latency is milliseconds from the end of the audio to the final text.
"""
import json
import re
import sys
import unicodedata
from collections import defaultdict

FILLERS = {"um", "uh", "er", "ah", "hmm", "mm", "erm", "uhm"}
NUMBERS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
           "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
EQUIVALENT = {
    "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"], "cause": ["because"],
    "cuz": ["because"], "alright": ["all", "right"], "ok": ["okay"], "etc": ["et", "cetera"],
    **{word: [str(n)] for n, word in enumerate(NUMBERS)},
}


def plain(word):
    return "".join(c for c in unicodedata.normalize("NFKD", word) if not unicodedata.combining(c))


def tokens(text, typed):
    words = text.split()
    out = []
    for w in words:
        bare = re.sub(r"[^\w']", "", w.lower())
        if bare in FILLERS:
            continue
        if typed:
            out.append(w)
        else:
            for part in re.split(r"[-/]", plain(w.lower())):
                part = re.sub(r"[^\w']", "", part).strip("'")
                if part and part not in FILLERS:
                    out.extend(EQUIVALENT.get(part, [part]))
    return out


def edits(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def main():
    results = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
    refs = {r["id"]: r["reference"] for r in (json.loads(l) for l in open(sys.argv[2]) if l.strip()) if r.get("reference")}
    vocab = []
    if len(sys.argv) > 3:
        vocab = [l.strip() for l in open(sys.argv[3]) if l.strip() and not l.lstrip().startswith("#")]

    engines = sorted({r["engine"] for r in results})
    by = defaultdict(dict)
    for r in results:
        by[r["engine"]][r["id"]] = r
    scored_ids = sorted(i for i in refs if all(i in by[e] and by[e][i].get("text") is not None for e in engines))
    print(f"clips with a reference and a final from every engine: {len(scored_ids)} of {len({r['id'] for r in results})}")
    print()
    header = f"{'engine':28} {'words WER':>9} {'typed WER':>9} {'terms':>11} {'p50 ms':>7} {'p90 ms':>7} {'p99 ms':>7} {'max ms':>7} {'failed':>6}"
    print(header)
    per_clip = defaultdict(dict)
    for e in engines:
        totals = {"words": [0, 0], "typed": [0, 0]}
        hits = seen = 0
        for i in scored_ids:
            hyp = by[e][i]["text"]
            for kind in totals:
                ref_t, hyp_t = tokens(refs[i], kind == "typed"), tokens(hyp, kind == "typed")
                d = edits(ref_t, hyp_t)
                totals[kind][0] += d
                totals[kind][1] += len(ref_t)
                if kind == "words":
                    per_clip[i][e] = d
            for term in vocab:
                if re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", refs[i], re.IGNORECASE):
                    seen += 1
                    hits += bool(re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", hyp))
        lat = [r["final_ms"] for r in by[e].values() if r.get("final_ms") is not None]
        failed = sum(1 for r in by[e].values() if r.get("final_ms") is None)
        w = 100 * totals["words"][0] / max(1, totals["words"][1])
        t = 100 * totals["typed"][0] / max(1, totals["typed"][1])
        terms = f"{hits}/{seen}" if seen else "-"
        print(f"{e:28} {w:8.2f}% {t:8.2f}% {terms:>11} {pct(lat, .5):>7} {pct(lat, .9):>7} {pct(lat, .99):>7} {max(lat) if lat else '-':>7} {failed:>6}")
    print()
    for a in engines:
        for b in engines:
            if a < b:
                wins = sum(1 for i in scored_ids if per_clip[i][a] < per_clip[i][b])
                losses = sum(1 for i in scored_ids if per_clip[i][a] > per_clip[i][b])
                print(f"{a} vs {b}: fewer word errors on {wins} clips, more on {losses}, tied on {len(scored_ids) - wins - losses}")
    print()
    for e in engines:
        errs = [r["error"] for r in by[e].values() if r.get("error")]
        if errs:
            kinds = defaultdict(int)
            for x in errs:
                kinds[re.sub(r"\d+", "N", x)[:80]] += 1
            print(f"{e} failures: " + "; ".join(f"{k} x{v}" for k, v in kinds.items()))
    ref_words = sum(len(tokens(refs[i], False)) for i in scored_ids)
    print(f"reference words: {ref_words}; audio seconds: {round(sum(by[engines[0]][i]['audio_s'] for i in scored_ids))}")


if __name__ == "__main__":
    main()
