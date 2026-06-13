# Security Policy

RCQ is a privacy- and censorship-resistance-focused messenger. We take security
reports seriously and welcome good-faith research.

## Reporting a vulnerability

**Please report security issues privately — do NOT open a public GitHub issue
for a vulnerability.**

- **Email:** security@rcq.app
- **In-app:** message the maintainers at RCQ UIN **#911** (end-to-end encrypted).

Please include:
- a description of the issue and its impact,
- the affected component (iOS app, Android app, backend `api.rcq.app`, relays),
- the app version / commit, device + OS, and
- steps to reproduce (a proof-of-concept is appreciated).

If you wish to encrypt your report by email and we have not yet published a PGP
key, send a first contact and we will establish an encrypted channel, or use the
in-app E2E path above.

## Our commitment

- We will **acknowledge** your report within **72 hours**.
- We will give you an **assessment and a remediation timeline** within **7 days**.
- We practice **coordinated disclosure**: we ask for up to **90 days** to ship and
  roll out a fix before public disclosure, and we are happy to disclose sooner
  once a fix is deployed and users have had a chance to update.
- With your permission, we will **credit** you in the release notes / a security
  acknowledgements list.

## Scope

**In scope**
- The iOS app (this repo), the Android app (`github.com/rcq-messenger/rcq-android`).
- The backend API (`api.rcq.app`) and self-host "island" server.
- The relay / circumvention transport and the relay broker.
- The cryptographic protocols (sealed sender, the v=1/v=2 message envelopes,
  sender keys, the federation home-island records, the relay-config + broker
  signatures).

**Out of scope**
- Volumetric denial-of-service / traffic flooding.
- Social engineering of our team or users; physical attacks.
- Vulnerabilities in third-party dependencies that are already public and have an
  upstream fix (please still tell us so we can bump them).
- Reports from automated scanners with no demonstrated impact.

## Safe harbor

We will not pursue or support legal action against researchers who, in good
faith:
- make a reasonable effort to avoid privacy violations, data destruction, and
  service degradation,
- only interact with accounts they own or have explicit permission to test, and
- give us a reasonable time to remediate before public disclosure.

If in doubt, ask first via the contacts above.

## Verifying what you run

The iOS app is fully open source under **AGPL-3.0** — you can read every line and
build it yourself from this repository. Note that App Store / TestFlight binaries
are re-signed and (FairPlay) re-encrypted by Apple, so an App Store build is **not
byte-reproducible** the way our Android release is; the guarantee on iOS is source
transparency, not binary reproduction. (The Android app additionally offers
reproducible release builds — see that repo's `docs/REPRODUCIBLE-BUILDS.md`.)

Our threat model and honest security boundaries are documented separately (what
is protected today, and the known metadata gaps we are closing) — see the
project transparency materials.
