# Sounds

Drop the original ICQ sound pack here as plain `.wav` files. Filenames must match the
cases in `SoundService.Cue` exactly (no extension change, no spaces):

| Filename                | Cue                          |
| ----------------------- | ---------------------------- |
| `message_incoming.wav`  | "Uh oh!" inbound message     |
| `contact_online.wav`    | door opening — came online   |
| `contact_offline.wav`   | door closing — went offline  |
| `nudge.wav`             | nudge received               |
| `message_sent.wav`      | soft click on send           |
| `app_startup.wav`       | startup sound on launch      |
| `typing.wav`            | optional, subtle             |

Source: search archive.org for **"ICQ sounds pack"**. Convert any non-WAV files to
16-bit PCM `.wav`, sample rate 22050 or 44100. Keep them short (under 2s each).

Until the pack is added, `SoundService` will silently skip missing files — the rest of
the app continues to work.
