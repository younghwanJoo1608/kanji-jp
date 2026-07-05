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

## Harness Boundaries

Keep harness responsibilities separate:

- Search/extraction harnesses collect source candidates and raw dictionary text.
  They write only reports or temporary extraction folders, never `_kanji` or
  `_kanji_8`.
- Audit/validation harnesses inspect existing data and write only reports.
  They must never rewrite `meaning`, `gloss`, `reading`, or `reference`.
- Translation cache work creates or updates `_data/kanji_meaning_translations.yml`
  and `_data/kanji_word_translations.yml` from Codex-reviewed translations.
- Mutation/generation harnesses are the only tools allowed to write stage data.
  They must read explicit source reports and translation caches.

Before any tool writes `_kanji_8` or another stage directory, create a snapshot:

```powershell
bundle exec ruby tools\snapshot_kanji_stage.rb --dir _kanji_8
```

Snapshots live under `_migration_snapshots/<timestamp>/` and include a
`manifest.json`. A mutation harness must refuse to write stage data unless a
fresh snapshot or an explicit snapshot path is part of the run.

## Main Harness

Use:

```powershell
bundle exec ruby tools\kanji_grade_harness.rb --grade 8 --show missing
```

Before translation or mutation, build a source report only:

```powershell
bundle exec ruby tools\kanji_word_source_report.rb --dir _kanji_8 --report _migration_reports\kanji_word_source_report.json --cache _migration_reports\kanji_word_source_report_cache.json
```

The source report harness reads stage files and web sources, then writes JSON
reports only. It must not modify `_kanji_8`. It resolves compound candidates in
this order:

1. Kanjipedia exact `word` match, with exact normalized `reading` when present.
2. Kotobank exact `word` match, with exact normalized `reading` when present.
3. `unresolved`, to be rendered later as `※뜻 확인 필요` only by a mutation or
   generation harness.

For Kotobank matches, prefer dictionary sources that already exist in the
project icon/reference set, such as `국어대사전`, `대사천`, `자통`, `신한어림`,
`신자원`, `한자원`, `대한화사전`, `코지엔`, and `자통망`. If no project
dictionary article exists but Kotobank has an exact `word + reading` match in an
external dictionary, keep the match with `reference_priority: "external"` in the
source report. Do not mark it unresolved merely because the dictionary is
external; unresolved means neither Kanjipedia nor Kotobank had an exact match.

Before broad generation, verify the translation caches against the latest
Japanese source stage:

```powershell
bundle exec ruby tools\audit_translation_cache_coverage.rb --source-dir _translation_source_8_ja --fail-on-missing
```

This audit writes only `_migration_reports/translation_cache_coverage_audit.json`.
It checks actual `char + word + gloss` coverage using the same word-cache
fallback matching as the generation harness. Entries already marked
`※뜻 확인 필요` are counted as unresolved source rows, not translation misses.

Useful generation command:

```powershell
bundle exec ruby tools\kanji_grade_harness.rb --grade 8 --write-stage missing --snapshot _migration_snapshots\<timestamp> --kanjipedia --kanjipedia-words --kotobank-fallback --meaning-translations _data\kanji_meaning_translations.yml --word-translations _data\kanji_word_translations.yml
```

Common options:

- `--grade 8`: scrape grade 8 from Jitenon. `pre2`, `jun2`, `準2`, and `준2`
  map to preliminary grade URLs.
- `--show all|missing|staged|completed`: audit what exists.
- `--write-stage missing|staged|all`: write only non-completed rows to the
  stage folder.
- `--snapshot PATH`: required when `--write-stage` targets a real `_kanji_*`
  stage directory.
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
- `--allow-untranslated`: explicitly allow Japanese meanings/glosses to be
  written. Use this only for extraction drafts, never for final stage output.

When `--write-stage` is used with `--kanjipedia` or `--kanjipedia-words`, the
harness treats missing Korean translations as failures by default. This prevents
Japanese source text from silently becoming stage data. Codex should translate
missing Japanese meanings/glosses into the YAML caches, then rerun generation.

Translation policy:

- Do not use Google Translate, `translate.googleapis.com`, browser machine
  translation, or any other automatic translation service for final
  `meaning`/`gloss` text.
- Codex must translate Japanese meanings/glosses directly, using the kanji,
  word, reading, examples, and dictionary context.
- Machine-translated draft text must not be committed as final kanji data.
- If Codex cannot determine a required word meaning from Kanjipedia/Kotobank,
  keep the word and use `※뜻 확인 필요` in `gloss`.

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
- This also applies to non-joyo, classical, and kanbun-style kunyomi. Do not
  drop readings just because they look uncommon. If `なお…-ごとし` appears,
  preserve the ellipsis in the generated target, such as `由…ごとし`, and report
  it for review if Kanjipedia/Kotobank cannot resolve it.
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
  It is required for every compound. The harness must fail rather than write a
  compound whose `yomi` is empty.
- `variation`: alternate spelling from Kanjipedia `表記`.
- `replace`: Kanjipedia `書きかえ`, for example `台風` has `颱風`.
- `reference`: dictionary/source marker. Use advanced dictionary names for
  manually verified advanced vocabulary and for Kotobank fallback entries by
  recording the actual dictionary article that matched, such as `국어대사전`.
  Do not use `코토방크` as a reference value: Kotobank is only the search
  platform, not the dictionary source. Do not fill `reference` from ordinary
  Kanjipedia entries.
- `genre`: deprecated. Do not write this field. Genre is represented only by
  tags inside `meaning` or `gloss`, such as `[생물]`.

Word genre tags:

- If a word has one meaning, or every numbered meaning shares the same genre,
  put the tag at the beginning of `gloss`.
- If only a specific numbered meaning needs a genre, put the tag right after
  that number.
- Example:
  `① 일반 의미. ② [불교] 불교에서 쓰는 말.`

Do not keep examples or source citations inside word `gloss`. Kanjipedia and
Kotobank may include quoted examples or source notes; the harness cleans these
before translation lookup, and Codex translations should remain definition-only.

## Kotobank Fallback

Use Kotobank only when a required word is missing from Kanjipedia. Required words
are meaning example words and kunyomi-derived words.

Dictionary priority:

1. `精選版 日本国語大辞典`
2. `デジタル大辞泉`

Example:

- `広がる`: `https://kotobank.jp/word/%E5%BA%83%E3%81%8C%E3%82%8B-614349`

Kotobank fallback provides `word`, `reading`, `gloss`, `yomi`, and `reference`.
The `reference` must be the matched dictionary name inside Kotobank, not
`코토방크`. For example, `精選版 日本国語大辞典` is stored as `국어대사전`.
It does not provide `variation`, `replace`, or deprecated `genre`.

For kunyomi-derived fallback targets, the dictionary headword reading must match
the target reading. Do not reuse a broad kanji-entry gloss for a specific word
reading. This is especially important when:

- `word` is the same single character as the target kanji, such as `洋(なだ)`.
- The same written word has multiple readings, with or without okurigana.

If the direct Kotobank URL opens a page whose heading reading does not match the
target reading, search Kotobank results for the same written form and the exact
target reading. Use that result only if the result label's reading matches. If
no such result exists, treat the target as unresolved and use `※뜻 확인 필요`
instead of copying another reading's gloss. If the source page is only a general
kanji entry, also treat it as unresolved unless a human has explicitly supplied
a trusted advanced-dictionary reference.

Known trap: Kotobank has `美い（読み）うっつい`, whose gloss is
`きれいだ。かわいい。`. Do not use that entry for the generated kunyomi target
`美い(よい)`. The written headword matches, but the reading does not.

If a required meaning-example word or kunyomi target cannot be resolved from
either Kanjipedia or Kotobank, keep the word in `compounds` and set:

```yaml
gloss: "※뜻 확인 필요"
```

This marker is intentional and searchable. Do not silently drop unresolved
classical, non-joyo, or rare readings.

## Validation

Before committing harness changes, run:

```powershell
bundle exec ruby -c tools\kanji_grade_harness.rb
bundle exec jekyll build
```

For data generation, test with a small limit first:

```powershell
bundle exec ruby tools\kanji_grade_harness.rb --grade 8 --write-stage staged --snapshot _migration_snapshots\<timestamp> --limit 1 --kanjipedia --kanjipedia-words --kotobank-fallback --meaning-translations _data\kanji_meaning_translations.yml --word-translations _data\kanji_word_translations.yml
```

Review generated Markdown before broad generation, especially:

- Unicode filename and `unicode` field.
- IVS handling in `char` and display text.
- Onyomi/Kunyomi kana form.
- Kanjipedia meaning hierarchy.
- Korean meaning quality and genre tag placement.
- Word `yomi`, `variation`, and `replace`.
