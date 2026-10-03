#!/usr/bin/env python3
"""A stand-in for pw-record: streams 16 kHz mono s16le from a raw file to stdout in 100 ms chunks at
real-time pace (0.5 s of leading silence first), then keeps the pipe open writing silence until it
is killed. Usage: recorder.py SPEECH.raw. VIZIER_E2E_MUTATE=silence streams silence instead."""
import os, sys, time

RATE, CHUNK = 16000, 1600  # samples per second, samples per 100 ms
data = open(sys.argv[1], "rb").read()
if os.environ.get("VIZIER_E2E_MUTATE") == "silence":
    data = bytes(len(data))
silence = bytes(CHUNK * 2)
out = sys.stdout.buffer
step, nxt = 0.1, time.monotonic()
stream = silence * 5 + data
for i in range(0, len(stream), CHUNK * 2):
    chunk = stream[i:i + CHUNK * 2]
    out.write(chunk.ljust(CHUNK * 2, b"\0")); out.flush()
    nxt += step; time.sleep(max(0, nxt - time.monotonic()))
while True:
    out.write(silence); out.flush()
    nxt += step; time.sleep(max(0, nxt - time.monotonic()))
