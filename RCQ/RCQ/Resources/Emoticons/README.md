# Emoticons

Drop the classic ICQ emoticon GIFs/PNGs here. Filenames must match the asset names
referenced in `Utils/Emoticons.swift`. Strip extensions when adding to Assets.xcassets,
or place loose `.png` files directly here and the bundle will pick them up by name.

Required asset names (one per emoticon, regardless of how many shortcodes map to it):

```
smile
biggrin
wink
sad
tongue
cry
shocked
cool
kiss
heart
neutral
confused
skeptical
angry
rofl
```

Source: search archive.org for **"ICQ emoticons"** — full GIF packs are commonly
indexed. Convert animated GIFs to PNG (or static GIF) at 32x32 px for the panel; if you
want animation in chat, use `WebPImage` or a UIKit-backed view (out of scope for v1).

Until the pack is added, `EmoticonText` falls back to rendering the literal shortcode,
and the picker grid shows shortcodes as text.
