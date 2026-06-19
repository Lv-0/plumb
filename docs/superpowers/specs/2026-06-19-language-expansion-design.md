# Language Expansion Design — Mainstream Languages + English-First README

- **Date:** 2026-06-19
- **Status:** Approved for implementation
- **Objective:**
  1. 增加主流语言支持 (App UI from zh/en/ja → **en/zh/es/fr/ja**)
  2. GitHub README 切换成优先展示英语，允许切换中文、西班牙语、法文、日语 README
- **Approach:** Extend the in-code `L10n` table (Approach B from the prior localization work) with two new languages; restructure README files so English is the default `README.md`.

---

## 1. Background

Two prior sessions established:
- **App localization** (`docs/superpowers/specs/2026-06-18-ui-localization-design.md`): a code-resolved `L10n` string table in `Sources/Plumb/Localization.swift` covering **zh / en / ja** across 38 keys. `AppLanguage.resolve(from:)` maps `Locale.preferredLanguages` → one of `.zh/.en/.ja` (fallback `.en`). `CFBundleLocalizations` is declared in `scripts/build_app.sh`. All 7 UI files migrated to `L10n.*` accessors.
- **README**: `README.md` is Chinese (default), `README.en.md` is English. A two-language switcher links them at top and bottom.

## 2. Scope Decision

Part 2 of the objective names **Spanish (es)** and **French (fr)** READMEs. For documentation to not mislead users, the App UI must support the same languages. The merged, consistent language set is:

> **en (default) · zh · es · fr · ja** — five languages.

Japanese is retained (added two days ago; removing it would be a regression). No languages beyond these five (YAGNI).

---

## 3. Part 1 — App UI: add `.es` and `.fr`

### 3.1 `AppLanguage` enum (`Sources/Plumb/Localization.swift`)

- Add cases `.es`, `.fr`.
- Resolver switch gains `"es" → .es`, `"fr" → .fr`. Region/script variants (`es-MX`, `fr-CA`, `es-419`) collapse to base language via the existing `Locale(identifier:).language.languageCode` logic. Fallback remains `.en`.

### 3.2 `L10n.table`

- Add two dictionaries `.es` and `.fr`, each with **all 38 `Key.allCases`** entries, fully translated. Existing `.en/.zh/.ja` dictionaries untouched.
- Call-site accessor signatures (`L10n.centerNow`, etc.) are unchanged → **zero call-site edits**, zero migration risk.

### 3.3 `scripts/build_app.sh`

- `CFBundleLocalizations` array: add `<string>es</string>` and `<string>fr</string>`. `CFBundleDevelopmentRegion` stays `en`.

### 3.4 Tests (`Tests/PlumbTests/LocalizationTests.swift`)

- The table-completeness test iterates languages via a literal list `[.zh, .en, .ja]`. **Extend it to `[.zh, .en, .es, .fr, .ja]`** so the two new tables are auto-verified for completeness (every key present + non-empty).
- Add resolver cases: `["es-MX"] → .es`, `["fr-CA"] → .fr`, `["de-DE","es-ES"] → .es` (fallback-to-Spanish within list), `["fr"] → .fr`, `["es","fr"] → .es` (first preference wins).

---

## 4. Part 2 — README: English-default + 5-language switching

GitHub renders `README.md` as the repo landing page. Make English the default.

### 4.1 File layout

| File | Source of content | Role |
|---|---|---|
| `README.md` | current `README.en.md` content | **English default** (repo landing page) |
| `README.zh.md` | current `README.md` content (Chinese) | Chinese variant |
| `README.es.md` | new — Spanish translation of English | Spanish variant |
| `README.fr.md` | new — French translation of English | French variant |
| `README.ja.md` | new — Japanese translation of English | Japanese variant |
| `README.en.md` | **deleted** (folded into `README.md`) | removed — English is now the default name |

### 4.2 Unified language switcher

Every README carries the same 5-language bar at top (under badges) and bottom. The **current language is bold plain text** (no link); the other four are links:

- In `README.md` (English):
  `English · [简体中文](./README.zh.md) · [Español](./README.es.md) · [Français](./README.fr.md) · [日本語](./README.ja.md)`
- In `README.zh.md`: `简体中文 · [English](./README.md) · [Español](...) · [Français](...) · [日本語](...)`
- (and so on, rotating the bold entry per file)

### 4.3 Anchor integrity

GitHub auto-generates heading anchors **per file**. Each README's internal TOC/links (`[About](#about)`, `[简介](#简介)`) must match **that file's own headings**. All five files share the same section *structure*; only the heading text differs by language. Verified per-file during implementation.

### 4.4 Unchanged

- Image/asset paths (`assets/AppIcon-base.png`, `assets/setting.png`, `assets/layout.png`) — shared, untouched.
- Badge URLs, code blocks, script paths — identical across all five.
- `CLAUDE.md` — not a user-facing README; left as-is.

---

## 5. Out of scope (YAGNI)

- No `readme-i18n` automation / sync tooling — five hand-maintained files.
- No additional languages (de, ko, pt, …).
- No in-app language picker — auto-follow system remains the contract.
- No translation of `CLAUDE.md` or `docs/`.

---

## 6. Verification (Done criteria)

- [ ] `Localization.swift`: `AppLanguage` has 5 cases; resolver maps es/fr; `L10n.table` has 5 complete dictionaries.
- [ ] `LocalizationTests`: completeness test covers all 5 languages; new es/fr resolver cases pass.
- [ ] `build_app.sh`: `CFBundleLocalizations` lists zh/en/es/fr/ja; script runs, `plutil -lint` OK.
- [ ] `swift build` + `swift test` green.
- [ ] 5 README files exist: `README.md` (en), `README.zh.md`, `README.es.md`, `README.fr.md`, `README.ja.md`; `README.en.md` removed.
- [ ] Each README's top + bottom switcher bar lists all 5 languages with the current one bold/unlinked.
- [ ] README internal anchor links resolve to headings within the same file (spot-checked per file).
- [ ] All changes committed.
