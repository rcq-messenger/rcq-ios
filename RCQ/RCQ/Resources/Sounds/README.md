# Sounds

Short UI cues played by `Services/SoundService.swift`. One file per case of
`SoundService.Cue`; the basenames below are what `filename(for:)` resolves.

| Filename            | Cue                | Shipping? |
| ------------------- | ------------------ | --------- |
| `message_incoming`  | inbound message    | no        |
| `contact_online`    | contact came online  | no      |
| `contact_offline`   | contact went offline | no      |
| `message_sent`      | soft click on send | no        |
| `join-me`           | you joined an audio room | yes |
| `join-all`          | someone joined the room  | yes |

`preload()` tries `aif`, `aiff`, `wav`, `m4a`, `mp3` in that order, so any of
those extensions works. Keep each cue under two seconds. Missing files are
skipped silently, which is why the four unshipped cues cost nothing today.

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
