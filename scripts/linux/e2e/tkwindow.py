#!/usr/bin/env python3
"""A Tk window with a text box that writes its whole content to a file after every change.
Usage: tkwindow.py OUTPUT_FILE. Stands in for "an ordinary X11 app that receives a paste"."""
import sys
import tkinter as tk

out = sys.argv[1]
root = tk.Tk()
root.title("vizier-e2e")
root.geometry("600x300+0+0")
text = tk.Text(root, width=60, height=10)
text.pack(fill="both", expand=True)

def dump(_event=None):
    if text.edit_modified():
        with open(out + ".tmp", "w", encoding="utf-8") as handle:
            handle.write(text.get("1.0", "end-1c"))
        import os
        os.replace(out + ".tmp", out)
        text.edit_modified(False)

text.bind("<<Modified>>", dump)
root.update()
root.focus_force()
text.focus_force()
with open(out + ".ready", "w") as handle:
    handle.write("ready")
root.mainloop()
