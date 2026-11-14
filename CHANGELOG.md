# Changelog

All notable changes to WhistleMute are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-13

Soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Standalone: doesn't need Nucleus.

For players: the whistle emote is silent for you, whoever whistles, you or another player. Only your own game is changed; other players hear everything as before.

### Added

- Sets the whistle sound's volume to 0 on this machine once per map, and reads it back. If the sound isn't loaded yet it retries 3 times, 5 s apart.
- Log lines `[WhistleMute] loaded`, `MUTED`, `MISS` and `WARN` in `UE4SS.log`.
