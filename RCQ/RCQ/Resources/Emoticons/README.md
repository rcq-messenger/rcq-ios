# Emoticons

Animated GIF emoticons bundled with the app and rendered by
`Utils/Emoticons.swift`. The table there is the authority: every entry's
`asset` field must match a file in this directory, minus the extension.

Two groups, both already present:

* the default palette, mirroring the Android palette in `Emoticon.kt` so that a
  `:code:` sent from one platform renders on the other;

Only `:asset:` codes are parsed. Text shortcuts like `:)` and `8-)`
deliberately are not, because they collide with ordinary text (`8-)` in
arithmetic, `:/` in URLs).

Adding one means: drop the GIF here, add the `Entry` in `Utils/Emoticons.swift`,
add the identical entry to Android's `Emoticon.kt`, and record its provenance in
the top-level `NOTICE`. All four, in the same commit. An emoticon that exists on
one platform renders as a literal `:code:` on the other.

## Provenance and licence

These are KOLOBOK smiles, a mid-2000s community set. The grant they are usually
redistributed under is non-commercial with attribution respected, which is why
`NOTICE` names them and points a rights-holder at security@rcq.app.

⚠ That grant does not stretch to cover a paid product. Before RCQ charges for
anything, we need explicit written permission from the rights-holder covering
commercial use and redistribution through the App Store and Google Play, or
these files have to be replaced with commissioned originals.

## What is not acceptable

Do not add emoticons taken from another messenger's asset pack, and in
particular not from ICQ. An earlier version of this file told the reader to
find an ICQ pack on an archive site. That instruction was wrong and has been
removed; this repository is public, and an instruction to infringe sitting in
it is worse than the infringement it invites.
