# Sounds

Short UI cues played by `Services/SoundService.swift`. One file per case of
`SoundService.Cue`; the basenames below are what `filename(for:)` resolves.

| File                    | Cue                      | Provenance      |
| ----------------------- | ------------------------ | --------------- |
| `message_incoming.aif`  | inbound message          | ⚠ UNRESOLVED    |
| `contact_online.aif`    | contact came online      | ⚠ UNRESOLVED    |
| `contact_offline.aif`   | contact went offline     | ⚠ UNRESOLVED    |
| `message_sent.aif`      | soft click on send       | ⚠ UNRESOLVED    |
| `join-me.mp3`           | you joined an audio room | ours            |
| `join-all.mp3`          | someone joined the room  | ours            |

`preload()` tries `aif`, `aiff`, `wav`, `m4a`, `mp3` in that order, so any of
those extensions works. Keep each cue under two seconds. Missing files are
skipped silently: deleting a cue makes the app quieter, never broken.

## ⚠ The four `.aif` files are not ours

They have shipped since the initial public release and their licence has never
been established. They are recognisably another product's cues. Unlike the
KOLOBOK set, which at least has a stated non-commercial grant, these have no
grant at all, so this is the weaker of the two asset positions, not the
stronger one.

Two ways out, both fine, and the choice is a product call:

* replace them with commissioned or CC0 originals, or
* delete the four files. `preload()` skips what is absent, so the app simply
  stops making those noises.

What is not an option is shipping them to a commercial store while this
paragraph is still true and nobody has decided anything.

## Where these files may come from

Only two sources are acceptable:

1. Original recordings commissioned or made for RCQ, or
2. Assets under a licence that permits commercial redistribution inside a
   closed-store binary (CC0 / public domain, or an explicit written grant).

Record the provenance of every file you add in the top-level `NOTICE` in the
same commit, with the licence and where it came from.

## What is not acceptable

Do not source these from another product's sound pack, and in particular do not
lift them from ICQ. RCQ ships through the App Store and Google Play and is
moving to a paid model, so "it was on an archive site" is not a licence, and a
messenger whose entire pitch is trustworthiness cannot be casual about someone
else's copyright.

An earlier version of this file told the reader to go and find the original ICQ
pack. That instruction was wrong and has been removed.

The chimes may be *evocative* of a door opening and closing, since that is a UI
idiom rather than an asset. Getting there means recording a door, not copying a
recording of one.
