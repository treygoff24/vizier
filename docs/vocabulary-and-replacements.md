# Vocabulary and replacements

Two plain text files in `~/.config/vizier/` teach Vizier your words. Settings › Words opens them in your editor, and writes a starter copy first if one is missing. Both are re-read on every take.

|  | `vocabulary.txt` | `replacements.txt` |
|---|---|---|
| Purpose | Tell the recognizer which words to expect | Rewrite the text after it is transcribed |
| When it acts | Before and during recognition, as a hint | After transcription and cleanup, as the last step |
| Which modes | Cloud modes only | Every mode |

## vocabulary.txt

One term per line. Names, products, acronyms and unusual words work well.

```text
# People and projects
Nguyen
Kubernetes
AcmeCloud
```

- Lines starting with `#` are comments; blank lines are skipped.
- Duplicates are removed, ignoring case.
- A hint is not a guarantee. The recognizer may still choose a common word.
- At most 1,000 terms. More than that is a config error, and Vizier keeps running the last good file.

How each engine uses the list:

| Engine | What it gets |
|---|---|
| Gemini (live and batch) | All terms |
| ElevenLabs Scribe realtime | The first 50 terms of 20 characters or fewer |
| ElevenLabs Scribe batch | The first 100 terms shorter than 49 characters and of five words or fewer |
| Apple speech | Nothing; Apple's recognizer does not use the list |
| Local whisper | Nothing |

Put the terms you care about most first. Terms sent to a cloud provider leave your Mac; see [privacy](privacy.md).

## replacements.txt

One rule per line:

```text
variant, another variant -> replacement
```

```text
# Fix terms the recognizer spells wrong
kuber nettys, cooper netties -> Kubernetes
acme cloud -> AcmeCloud
```

- The line is split at the first `->`. The left side is one or more variants separated by commas; the right side is the replacement.
- Matching ignores case and matches whole words, using Unicode word boundaries. For Chinese, Japanese, Thai and other scripts without spaces, a variant matches as a substring.
- When variants overlap, the longest wins. Vizier scans the text once from left to right, so a replacement is never matched again by another rule.
- The replacement is inserted literally, as you typed it, including its capitalization.
- Lines starting with `#` and blank lines are ignored.

Errors reject the whole file: the same variant on two lines, a line without `->`, or an empty side. The error names the line (`replacements.txt line N`) and shows in the alert; the last good rules keep running until you fix the file.

Replacements run in every mode, including Apple and Local, and after the cleanup pass and filler filter. If you use Gemini Clean, the rules are also sent to the cleanup model as pairs (heard word, intended word), so it can use them; see [privacy](privacy.md).

## Tips

- If a word is wrong in cloud modes, try vocabulary first; if it is still wrong, or you use Apple mode, add a replacement.
- After editing, use Re-run in History on a recent take to see the effect without speaking again.
