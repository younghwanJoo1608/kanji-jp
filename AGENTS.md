# Kanji JP Codex Notes

This project contains a Codex-built harness for staging kanji page data by
Kanken grade. Read this before running or changing `tools/kanji_grade_harness.rb`.

## Branch Context

- Primary working branch: `codex/kanji-blog-ui-refactor`.
- Completed kanji live in `_kanji`.
- Stage output folders are grade-specific: `_kanji_8`, `_kanji_7`,
  `_kanji_6`, and so on. Preliminary grades use `jun`, for example
  `_kanji_jun2`.
- Do not overwrite files already in `_kanji`. The harness only writes stage
  files. Existing stage files may be overwritten.
- Kanji page filenames must stay as Unicode hex filenames, such as `5316.md`
  for `化`.

## Main Harness

Use:

```powershell
bundle exec ruby tools\kanji_grade_harness.rb --grade 8 --show missing
```

Useful generation command:

```powershell
bundle exec ruby tools\kanji_grade_harness.rb --grade 8 --write-stage missing --kanjipedia --kanjipedia-words --kotobank-fallback
```

Common options:

- `--grade 8`: scrape grade 8 from Jitenon. `pre2`, `jun2`, `準2`, and `준2`
  map to preliminary grade URLs.
- `--show all|missing|staged|completed`: audit what exists.
- `--write-stage missing|staged|all`: write only non-completed rows to the
  stage folder.
- `--limit N`: limit generated files while testing.
- `--sleep SECONDS`: delay between detail requests.
- `--kanjipedia`: enrich readings and meanings from Kanjipedia.
- `--kanjipedia-words`: select useful compounds from Kanjipedia word search.
- `--kotobank-fallback`: when required words are missing from Kanjipedia, fetch
  their gloss from Kotobank.
- `--meaning-translations PATH` and `--word-translations PATH`: YAML caches for
  Codex-curated Korean translations.
- `--require-meaning-translations` and `--require-word-translations`: fail if a
  Korean translation is missing.

## Source Priority

### Kanji List And Basic Metadata

Use Jitenon as the grade authority.

- Example grade 8 URL: `https://kanji.jitenon.jp/cat/kyu08`.
- The URL suffix changes by grade. Preliminary grades append `j`, for example
  `kyu02j`.
- Scrape basic fields from Jitenon:
  `char`, `unicode`, `radical`, `strokes`, `kanken`, `jis`, `onyomi`,
  `kunyomi`.
- Do not take meanings, words, or idioms from Jitenon.

Reading normalization:

- Onyomi must be Katakana.
- Kunyomi must be Hiragana.
- Jitenon okurigana parentheses become hyphenated kunyomi:
  `か(わる)` -> `か-わる`.

### Kanji Meanings And Extra Readings

Use Kanjipedia individual kanji pages.

- Resolve pages via one-character exact search:
  `https://www.kanjipedia.jp/search?k=<char>&kt=1&sk=perfect`.
- Add readings found on Kanjipedia only when they are missing from Jitenon.
- Kanjipedia `外` readings are non-joyo readings. Store them with empty `type`.
- Joyo readings use `type: "상용"`.

Meaning structure:

- Store ordinary numbered meanings as:
  `{ meaning, example }`.
- If a meaning has `(ア)`, `(イ)`, etc., store them under `submeanings`.
- If meanings are grouped by source form or reading, such as `(A)［豫］`,
  store a three-level structure:

```yaml
meanings:
  - reading: "豫"
    meanings:
      - meaning: "..."
        example: "..."
```

Ignore Kanjipedia synonym/antonym tails such as `類` and `対`.

After extracting Japanese meanings, Codex should translate them into Korean with
the kanji's actual usage in mind. Then apply genre tags where appropriate.

Genre tags currently include:

- `[불교]`
- `[생물]`
- `[지명]`
- `[나라]`
- `[단위]`

## Word Strategy

Use Kanjipedia word search first.

Search with the target kanji included anywhere and with all word/reading filters
enabled. The harness handles multiple Kanjipedia result pages.

Do not collect proverbs or four-character idioms for this workflow.

Select words conservatively:

- Always include words used as kanji meaning examples.
- Always include words corresponding to kunyomi with okurigana. Example:
  `ひろ-がる` becomes `広がる`.
- Include important jukujikun words.
- Include other words that help Kanken study or where the target kanji carries
  important semantic weight.
- Avoid collecting too many words; default maximum is 12 selected Kanjipedia
  words, before required Kotobank fallbacks.

Word fields:

- `word`: headword, including okurigana where present.
- `reading`: full word reading. Follow the same kana rule: onyomi in Katakana,
  kunyomi in Hiragana, mixed readings preserving that distinction when possible.
- `gloss`: Korean translated meaning, with genre tags where needed.
- `yomi`: only the target kanji's reading in that word, for grouping on the
  hosted page.
- `variation`: alternate spelling from Kanjipedia `表記`.
- `replace`: Kanjipedia `書きかえ`, for example `台風` has `颱風`.
- `reference`: only for advanced vocabulary dictionary references. Do not fill
  this from ordinary Kanjipedia notes.

Word genre tags:

- If a word has one meaning, or every numbered meaning shares the same genre,
  put the tag at the beginning of `gloss`.
- If only a specific numbered meaning needs a genre, put the tag right after
  that number.
- Example:
  `① 일반 의미. ② [불교] 불교에서 쓰는 말.`

## Kotobank Fallback

Use Kotobank only when a required word is missing from Kanjipedia. Required words
are meaning example words and kunyomi-derived words.

Dictionary priority:

1. `精選版 日本国語大辞典`
2. `デジタル大辞泉`

Example:

- `広がる`: `https://kotobank.jp/word/%E5%BA%83%E3%81%8C%E3%82%8B-614349`

Kotobank fallback provides only `word`, `reading`, `gloss`, `yomi`, and possible
`genre`. It does not provide `variation`, `replace`, or `reference`.

## Validation

Before committing harness changes, run:

```powershell
bundle exec ruby -c tools\kanji_grade_harness.rb
bundle exec jekyll build
```

For data generation, test with a small limit first:

```powershell
bundle exec ruby tools\kanji_grade_harness.rb --grade 8 --write-stage staged --limit 1 --kanjipedia --kanjipedia-words --kotobank-fallback
```

Review generated Markdown before broad generation, especially:

- Unicode filename and `unicode` field.
- IVS handling in `char` and display text.
- Onyomi/Kunyomi kana form.
- Kanjipedia meaning hierarchy.
- Korean meaning quality and genre tag placement.
- Word `yomi`, `variation`, and `replace`.
