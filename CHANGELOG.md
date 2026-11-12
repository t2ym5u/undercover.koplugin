# Changelog

## [1.1.4] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.1.3] - 2026-11-09

### Fixed
- A language tried once in the game's Language menu no longer sticks for
  good: the game follows KOReader's language (French when KOReader is in
  French), and a language picked in the game holds until KOReader's language
  changes. A language picked with an earlier version is forgotten once.

## [1.1.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.1.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.1.0] - 2026-11-03

### Changed
- No repeats across sessions: a word pair or a place is not dealt again —
  even after closing the game or starting a new one — until every one of the
  selected packs has been played; then only those packs start over. The
  pairs and places already played in the saved game are carried over.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Undercover for 3–12 players on one reader passed round the table, with a hand-over screen between players and tap-to-show / tap-to-hide secrets.
- Undercover mode (civilians, 1–3 undercovers, optional Mr. White who may guess the civilians' word when eliminated, with a case-, accent- and typo-tolerant comparison) and Spy mode (one spy, a shared place with roles, the spy may name the place).
- Player names remembered, scores across rounds, optional discussion timer, saved game in progress.
- 1460 French / 1293 English word pairs and 365 French / 362 English spy places with roles, in six themed packs selectable in the menu (History & legends, Geography & monuments, Pop culture, Food, Kids, Mix & laughs).
- Interface in English, French, Spanish and German; content in French or English.
