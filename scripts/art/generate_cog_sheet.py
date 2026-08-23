#!/usr/bin/env python3
"""Render the Firm character sheet with nano-banana (Gemini image generation).

One call, one sheet: five Softmax cogs in a row — the MANAGER in office kit
and the four MACHINE OPERATORS in the four seat colours, each carrying a
large, distinct prop so the role reads at board scale with every label
hidden. The sheet is the committed source of truth for the sprites; run
`split_cog_sheet.py` to key, split and pad it into `data/cog_*.png`.

    GEMINI_API_KEY=... python3 scripts/art/generate_cog_sheet.py

The key is only ever the `x-goog-api-key` header: never a URL parameter,
never written to a file, never echoed.
"""

import base64
import json
import os
import urllib.request

MODEL = "gemini-2.5-flash-image"
ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    f"{MODEL}:generateContent"
)
REFERENCE = "data/soldier_red_front.png"
OUT = "scripts/art/source/cogs_sheet.png"

PROMPT = """Using this wheeled robot character ("cog": boxy screen face with two
glowing round eyes, riveted shoulders, two big rubber wheels) as the exact
character design reference, draw FIVE of these cogs side by side in ONE row,
evenly spaced with a clear gap between each, all the same size, full body,
front-facing, same clean cartoon rendering, same lighting.
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows, no gradients, no floor, no ground line - it will be chroma-keyed out.

1st from the left - THE MANAGER: violet/purple (#A86FD6) plating, a crisp white
shirt collar and a dark necktie on its chest panel, a peaked manager's cap, and
it holds a big brown clipboard with a white sheet of paper in one hand and a
rolled paper memo in the other. Office worker, no tools.

The other four are FACTORY MACHINE OPERATORS, identical in kit and different
only in body colour. Each wears a bright safety-yellow hard hat, a tool belt
with a chunky spanner hanging from it, and holds a large steel wrench raised in
one hand:
2nd - operator with RED (#E0523A) plating.
3rd - operator with BLUE (#3F7CC4) plating.
4th - operator with GREEN (#45A85E) plating.
5th - operator with YELLOW (#DDC531) plating.

No text, no letters, no numbers, no labels anywhere in the image."""


def main() -> None:
    reference = base64.b64encode(open(REFERENCE, "rb").read()).decode()
    body = {
        "contents": [
            {
                "parts": [
                    {"inline_data": {"mime_type": "image/png", "data": reference}},
                    {"text": PROMPT},
                ]
            }
        ],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": os.environ["GEMINI_API_KEY"],
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    part = next(
        p for p in payload["candidates"][0]["content"]["parts"] if "inlineData" in p
    )
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
