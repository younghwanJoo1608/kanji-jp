#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8

require "date"
require "json"
require "nokogiri"
require "open-uri"
require "optparse"
require "set"
require "time"
require "uri"
require "yaml"

KANJIPEDIA_BASE_URL = "https://www.kanjipedia.jp"
KOTOBANK_BASE_URL = "https://kotobank.jp"
DEFAULT_REPORT = "_migration_reports/kanji_word_source_report.json"
DEFAULT_CACHE = "_migration_reports/kanji_word_source_report_cache.json"
PROJECT_REFERENCES = %w[국어대사전 코지엔 대사천 신한어림 자통 신자원 한자원 대한화사전 자통망].freeze
SOURCE_REFERENCE_ORDER = %w[국어대사전 코지엔 대사천].freeze
SMALL_KANA_FOLD = {
  "ぁ" => "あ", "ぃ" => "い", "ぅ" => "う", "ぇ" => "え", "ぉ" => "お",
  "ゃ" => "や", "ゅ" => "ゆ", "ょ" => "よ", "ゎ" => "わ"
}.freeze
VOICED_KANA = {
  "か" => "が", "き" => "ぎ", "く" => "ぐ", "け" => "げ", "こ" => "ご",
  "さ" => "ざ", "し" => "じ", "す" => "ず", "せ" => "ぜ", "そ" => "ぞ",
  "た" => "だ", "ち" => "ぢ", "つ" => "づ", "て" => "で", "と" => "ど",
  "は" => "ば", "ひ" => "び", "ふ" => "ぶ", "へ" => "べ", "ほ" => "ぼ"
}.freeze
HAND_VOICED_KANA = {
  "は" => "ぱ", "ひ" => "ぴ", "ふ" => "ぷ", "へ" => "ぺ", "ほ" => "ぽ"
}.freeze

WordCandidate = Struct.new(:word, :reading, :reasons, :raw_label, :url, :jukujikun, keyword_init: true)

options = {
  dir: "_kanji_8",
  report: DEFAULT_REPORT,
  cache: DEFAULT_CACHE,
  max_words: 12,
  limit: nil,
  sleep: 0.0
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/kanji_word_source_report.rb [options]"
  opts.on("--dir DIR", "Stage directory to read. Default: _kanji_8") { |value| options[:dir] = value }
  opts.on("--report PATH", "JSON report path. Default: #{DEFAULT_REPORT}") { |value| options[:report] = value }
  opts.on("--cache PATH", "JSON lookup cache path. Default: #{DEFAULT_CACHE}") { |value| options[:cache] = value }
  opts.on("--max-words N", Integer, "Maximum selected Kanjipedia study words per kanji. Default: 12") { |value| options[:max_words] = value }
  opts.on("--limit N", Integer, "Limit kanji files for testing.") { |value| options[:limit] = value }
  opts.on("--sleep SECONDS", Float, "Delay between network requests. Default: 0") { |value| options[:sleep] = value }
end.parse!

def strip_variation_selectors(text)
  text.to_s.gsub(/[\uFE00-\uFE0F\u{E0100}-\u{E01EF}]/, "")
end

def hiragana_to_katakana(text)
  text.to_s.tr("ぁ-ゖ", "ァ-ヶ")
end

def katakana_to_hiragana(text)
  text.to_s.tr("ァ-ヶ", "ぁ-ゖ")
end

def normalize_reading(text)
  text.to_s
      .sub(/[（(]その他表記[）)].*\z/, "")
      .tr("ァ-ヶ", "ぁ-ゖ")
      .tr("－‐‑‒–—―", "-")
      .gsub(/[-・･\s]/, "")
      .strip
end

def fold_small_kana(text)
  text.to_s.chars.map { |char| SMALL_KANA_FOLD.fetch(char, char) }.join
end

def sokuon_reading_variant(kana)
  return nil if kana.length < 2

  %w[つ ち く き].include?(kana[-1]) ? "#{kana[0...-1]}っ" : nil
end

def voiced_reading_variants(kana)
  chars = kana.to_s.chars
  return [] if chars.empty?

  variants = [kana]
  variants << ([VOICED_KANA[chars[0]]] + chars[1..]).join if VOICED_KANA[chars[0]]
  variants << ([HAND_VOICED_KANA[chars[0]]] + chars[1..]).join if HAND_VOICED_KANA[chars[0]]
  variants.uniq
end

def yomi_reading_variants(reading)
  normalized = normalize_reading(reading)
  bases = [normalized, fold_small_kana(normalized)].uniq.reject(&:empty?)
  bases += bases.filter_map { |base| sokuon_reading_variant(base) }
  bases.flat_map { |base| voiced_reading_variants(base) }.uniq
end

def reading_contains_yomi?(reading, yomi)
  normalized_reading = normalize_reading(reading)
  yomi_reading_variants(yomi).any? { |variant| normalized_reading.include?(variant) }
end

def clean_word(text)
  text.to_s
      .gsub(/[△▲▽▼]/, "")
      .gsub(/[〈〉《》「」]/, "")
      .gsub(/\s+/, "")
      .strip
end

def clean_node_text(node)
  node&.text.to_s.gsub(/\s+/, " ").strip
end

def fetch_html(url, sleep_seconds:)
  sleep sleep_seconds if sleep_seconds.positive?
  Nokogiri::HTML(URI.open(url, "User-Agent" => "Mozilla/5.0", read_timeout: 20), nil, "UTF-8")
end

def load_json(path)
  return {} unless File.exist?(path)

  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue JSON::ParserError
  {}
end

def write_json(path, data)
  dir = File.dirname(path)
  Dir.mkdir(dir) unless Dir.exist?(dir)
  File.write(path, JSON.pretty_generate(data), encoding: "UTF-8")
end

def kanjipedia_word_search_url(word)
  query = URI.encode_www_form(
    k: word,
    kt: "1",
    wt: "1",
    ky: "1",
    wy: "1",
    sk: "partial",
    t: "kotoba"
  )
  "#{KANJIPEDIA_BASE_URL}/search?#{query}"
end

def kanjipedia_char_word_search_url(char)
  kanjipedia_word_search_url(strip_variation_selectors(char))
end

def search_page_urls(first_doc, first_url, base_url)
  urls = Set[first_url]
  first_doc.css(".pagerSection a[href]").each do |link|
    href = link["href"].to_s
    next unless href.include?("t=kotoba")

    urls << URI.join(base_url, href).to_s
  end
  urls.to_a
end

def kanjipedia_candidates_for_query(query, sleep_seconds:)
  first_url = kanjipedia_word_search_url(query)
  first_doc = fetch_html(first_url, sleep_seconds: sleep_seconds)
  search_page_urls(first_doc, first_url, KANJIPEDIA_BASE_URL).each_with_object([]) do |url, candidates|
    doc = url == first_url ? first_doc : fetch_html(url, sleep_seconds: sleep_seconds)
    doc.css("#resultKotobaList a[href^='/kotoba/']").each do |link|
      raw_label = clean_node_text(link)
      word = clean_word(raw_label.sub(/[（(][^）)]*[）)]\z/, ""))
      reading = normalize_reading(raw_label[/[（(]([^）)]*)[）)]\z/, 1])
      next if word.empty?

      candidates << WordCandidate.new(
        word: word,
        reading: reading,
        reasons: [],
        raw_label: raw_label,
        url: URI.join(KANJIPEDIA_BASE_URL, link["href"].to_s).to_s,
        jukujikun: raw_label.include?("〈") || raw_label.include?("《")
      )
    end
  end.uniq { |candidate| candidate.url }
end

def kanjipedia_candidates_for_char(char, sleep_seconds:)
  first_url = kanjipedia_char_word_search_url(char)
  first_doc = fetch_html(first_url, sleep_seconds: sleep_seconds)
  search_page_urls(first_doc, first_url, KANJIPEDIA_BASE_URL).each_with_object([]) do |url, candidates|
    doc = url == first_url ? first_doc : fetch_html(url, sleep_seconds: sleep_seconds)
    doc.css("#resultKotobaList a[href^='/kotoba/']").each do |link|
      raw_label = clean_node_text(link)
      word = clean_word(raw_label.sub(/[（(][^）)]*[）)]\z/, ""))
      reading = normalize_reading(raw_label[/[（(]([^）)]*)[）)]\z/, 1])
      next if word.empty?

      candidates << WordCandidate.new(
        word: word,
        reading: reading,
        reasons: [],
        raw_label: raw_label,
        url: URI.join(KANJIPEDIA_BASE_URL, link["href"].to_s).to_s,
        jukujikun: raw_label.include?("〈") || raw_label.include?("《")
      )
    end
  end.uniq { |candidate| candidate.url }
end

def proverb_or_idiom_candidate?(candidate)
  text = candidate.raw_label.to_s
  return true if text.match?(/[、。]/)
  return true if text.length > 14 && text.match?(/[ぁ-ゖ]/)

  false
end

def kanji_only?(text)
  text.to_s.match?(/\A\p{Han}+\z/)
end

def extract_meaning_examples(rows)
  rows.each_with_object([]) do |row, examples|
    if row["meanings"].is_a?(Array)
      examples.concat(extract_meaning_examples(row["meanings"]))
    else
      examples << row["example"] unless row["example"].to_s.empty?
      examples.concat(extract_meaning_examples(row.fetch("submeanings", [])))
    end
  end.uniq
end

def kunyomi_word(char, reading)
  raw = reading.to_s.strip
  return nil if raw.empty?

  if raw.include?("-")
    stem, suffix = raw.split("-", 2)
    joiner = stem.include?("…") ? "…" : ""
    clean_word("#{char}#{joiner}#{suffix}")
  else
    clean_word(char)
  end
end

def compound_yomi(word, reading, page, jukujikun:)
  return "숙자훈" if jukujikun

  normalized_reading = normalize_reading(reading)
  page.fetch("kunyomi", []).each do |item|
    raw = item["reading"].to_s
    surface = normalize_reading(raw)
    stem = raw.split("-", 2).first.to_s
    stem_surface = normalize_reading(stem)
    next if stem_surface.empty?

    return stem if !surface.empty? && normalized_reading.start_with?(surface)
    return stem if normalized_reading.start_with?(stem_surface)
    return stem if reading_contains_yomi?(reading, stem)
  end

  page.fetch("onyomi", []).each do |item|
    yomi = item["reading"].to_s
    return yomi if !yomi.empty? && reading_contains_yomi?(reading, yomi)
  end

  ""
end

def select_study_candidates(candidates, page, max_words:)
  examples = extract_meaning_examples(page.fetch("meanings", [])).map { |word| clean_word(word) }
  kunyomi = page.fetch("kunyomi", []).map { |item| normalize_reading(item["reading"]) }.reject(&:empty?)
  char = strip_variation_selectors(page["char"])
  selected = []

  add = lambda do |candidate, reason|
    return if selected.any? { |row| row.url == candidate.url }
    return if proverb_or_idiom_candidate?(candidate)

    candidate.reasons << reason unless candidate.reasons.include?(reason)
    selected << candidate
  end

  candidates.each { |candidate| add.call(candidate, "meaning-example") if examples.include?(candidate.word) }
  candidates.each { |candidate| add.call(candidate, "kunyomi") if kunyomi.include?(candidate.reading) }
  candidates.each { |candidate| add.call(candidate, "jukujikun") if candidate.jukujikun }
  candidates.each do |candidate|
    break if selected.length >= max_words
    next unless candidate.word.start_with?(char)
    next if candidate.word.length > 5
    next if compound_yomi(candidate.word, candidate.reading, page, jukujikun: candidate.jukujikun).empty?

    add.call(candidate, "kanjipedia-study")
  end
  candidates.each do |candidate|
    break if selected.length >= max_words
    next unless candidate.word.include?(char)
    next if candidate.word.start_with?(char)
    next if candidate.word.length > 5
    next if kanji_only?(candidate.word) && candidate.word.length == 4
    next if compound_yomi(candidate.word, candidate.reading, page, jukujikun: candidate.jukujikun).empty?

    add.call(candidate, "kanjipedia-study")
  end

  selected.first(max_words)
end

def add_candidate(map, word:, reading:, reason:, raw_label: "", url: "", jukujikun: false)
  cleaned_word = clean_word(word)
  normalized_reading = normalize_reading(reading)
  return if cleaned_word.empty?

  if normalized_reading.empty?
    existing = map.values.find { |candidate| candidate.word == cleaned_word && !candidate.reading.to_s.empty? }
    if existing
      existing.reasons << reason unless existing.reasons.include?(reason)
      return
    end
  else
    empty_key = "#{cleaned_word}\t"
    if map[empty_key]
      existing_empty = map.delete(empty_key)
      existing_empty.reasons.each do |existing_reason|
        reason = existing_reason if reason.to_s.empty?
      end
      raw_label = existing_empty.raw_label if raw_label.to_s.empty?
      url = existing_empty.url if url.to_s.empty?
      jukujikun ||= existing_empty.jukujikun
    end
  end

  key = "#{cleaned_word}\t#{normalized_reading}"
  row = map[key] ||= WordCandidate.new(
    word: cleaned_word,
    reading: normalized_reading,
    reasons: [],
    raw_label: raw_label,
    url: url,
    jukujikun: jukujikun
  )
  row.reasons << reason unless row.reasons.include?(reason)
  if defined?(existing_empty) && existing_empty
    existing_empty.reasons.each { |existing_reason| row.reasons << existing_reason unless row.reasons.include?(existing_reason) }
  end
  row.raw_label = raw_label if row.raw_label.to_s.empty? && !raw_label.to_s.empty?
  row.url = url if row.url.to_s.empty? && !url.to_s.empty?
  row.jukujikun ||= jukujikun
end

def collect_candidates(page, max_words:, sleep_seconds:)
  map = {}
  char = strip_variation_selectors(page["char"])

  page.fetch("compounds", []).each do |item|
    add_candidate(map, word: item["word"], reading: item["reading"], reason: "existing", jukujikun: item["yomi"].to_s == "숙자훈")
  end

  page.fetch("kunyomi", []).each do |item|
    word = kunyomi_word(char, item["reading"])
    add_candidate(map, word: word, reading: normalize_reading(item["reading"]), reason: "kunyomi") if word
  end

  extract_meaning_examples(page.fetch("meanings", [])).each do |word|
    add_candidate(map, word: word, reading: "", reason: "meaning-example")
  end

  select_study_candidates(
    kanjipedia_candidates_for_char(char, sleep_seconds: sleep_seconds),
    page,
    max_words: max_words
  ).each do |candidate|
    reason = candidate.reasons.empty? ? "kanjipedia-study" : candidate.reasons.first
    add_candidate(
      map,
      word: candidate.word,
      reading: candidate.reading,
      reason: reason,
      raw_label: candidate.raw_label,
      url: candidate.url,
      jukujikun: candidate.jukujikun
    )
  end

  map.values.sort_by { |candidate| [candidate.word, candidate.reading] }
end

def clean_word_gloss_text(text)
  cleaned = text.to_s.gsub(/\s+/, " ").strip
  cleaned = cleaned.gsub(/[（(]出典：[^）)]*[）)]/, "")
  cleaned = cleaned.gsub(/[［\[]出典[^］\]]*[］\]][^。]*。?/, "")
  cleaned = cleaned.gsub(/[［\[]例[^］\]]*[］\]][^。]*。?/, "")
  cleaned = cleaned.gsub(/「[^」]*―[^」]*」/, "")
  cleaned = cleaned.gsub(/「[^」]*[。！？][^」]*」/, "")
  cleaned = cleaned.gsub(/「[^」]*(?:です|ます|した|だった|である|になる|となる|がある|がいる)[^」]*」/, "")
  cleaned.gsub(/\s+/, " ").strip
end

def kanjipedia_meaning_text(node)
  return "" unless node

  node.css("rt").remove
  clean_node_text(node)
end

def extract_word_variation(doc)
  text = clean_node_text(doc.at_css("#kotobaExplanationSection p.hyouki"))
  return "" if text.empty?

  text.scan(/「([^」]+)」/).flatten.join("・")
end

def extract_word_replace(doc)
  node = doc.at_css("#kotobaExplanationSection > p:not(.hyouki):not(.sankou)")
  has_rewrite = node&.css("img")&.any? { |img| img["alt"].to_s == "書きかえ" }
  return "" unless has_rewrite

  text = clean_node_text(node)
  text[/「([^」]+)」の書きかえ字/, 1].to_s.strip
end

def find_kanjipedia_source(word, reading, sleep_seconds:)
  candidates = kanjipedia_candidates_for_query(word, sleep_seconds: sleep_seconds).select do |candidate|
    candidate.word == clean_word(word)
  end
  candidates = candidates.select { |candidate| candidate.reading == normalize_reading(reading) } unless reading.to_s.empty?
  return { "status" => "not_found" } if candidates.empty?
  return { "status" => "ambiguous", "candidates" => candidates.map { |c| candidate_payload(c) } } if reading.to_s.empty? && candidates.length > 1

  candidate = candidates.first
  doc = fetch_html(candidate.url, sleep_seconds: sleep_seconds)
  detail_word = clean_word(clean_node_text(doc.at_css("#kotobaArea p")))
  detail_word = candidate.word if detail_word.empty?
  detail_reading = normalize_reading(clean_node_text(doc.at_css("#kotobaArea .kotobaYomi")))
  detail_reading = candidate.reading if detail_reading.empty?
  return { "status" => "word_mismatch", "candidate" => candidate_payload(candidate), "detail_word" => detail_word } unless detail_word == clean_word(word)
  return { "status" => "reading_mismatch", "candidate" => candidate_payload(candidate), "detail_reading" => detail_reading } unless reading.to_s.empty? || detail_reading == normalize_reading(reading)

  gloss_node = doc.at_css("#kotobaExplanationSection > p:not(.hyouki):not(.sankou)")
  gloss_ja = clean_word_gloss_text(kanjipedia_meaning_text(gloss_node))
  {
    "status" => "matched",
    "source" => "kanjipedia",
    "word" => detail_word,
    "reading" => detail_reading,
    "reading_display" => display_reading(detail_reading, word, nil),
    "gloss_ja" => gloss_ja,
    "url" => candidate.url,
    "raw_label" => candidate.raw_label,
    "variation" => extract_word_variation(doc),
    "replace" => extract_word_replace(doc)
  }
rescue StandardError => e
  { "status" => "error", "error" => "#{e.class}: #{e.message}" }
end

def candidate_payload(candidate)
  {
    "word" => candidate.word,
    "reading" => candidate.reading,
    "raw_label" => candidate.raw_label,
    "url" => candidate.url
  }
end

def kotobank_search_url(word)
  "#{KOTOBANK_BASE_URL}/search?#{URI.encode_www_form(q: word, t: "all")}"
end

def kotobank_result_spellings(label)
  bracket = label.to_s[/[【［]([^】］]+)[】］]/, 1].to_s
  return [] if bracket.empty?

  bracket.split(/[／\/・･]/).map { |part| clean_word(part) }.reject(&:empty?)
end

def kotobank_result_reading(label)
  raw = label.to_s[/\A[ぁ-ゖァ-ヺー・･\s\-－‐‑‒–—―]+/].to_s
  raw = raw.sub(/[ァ-ヺ].*\z/, "") if raw.match?(/\A[ぁ-ゖ]/)
  normalize_reading(raw)
end

def kotobank_result_matches_word?(label, word)
  normalized_word = clean_word(word)
  spellings = kotobank_result_spellings(label)
  return true if spellings.include?(normalized_word)

  kanji = normalized_word.scan(/\p{Han}/)
  kana_suffix = normalized_word.sub(/\A\p{Han}+/, "")
  kanji.length == 1 && !kana_suffix.empty? && spellings.include?(kanji.first)
end

def kotobank_candidates_for_query(word, sleep_seconds:)
  url = kotobank_search_url(word)
  doc = fetch_html(url, sleep_seconds: sleep_seconds)
  doc.css('a[href^="/word/"]').filter_map do |link|
    label = clean_node_text(link)
    next unless kotobank_result_matches_word?(label, word)

    {
      "word" => clean_word(word),
      "reading" => kotobank_result_reading(label),
      "raw_label" => label,
      "url" => URI.join(KOTOBANK_BASE_URL, link["href"].to_s).to_s
    }
  end.uniq { |item| item["url"] }
end

def xpath_literal(value)
  text = value.to_s
  return "'#{text}'" unless text.include?("'")
  return "\"#{text}\"" unless text.include?('"')

  "concat(#{text.split("'").map { |part| "'#{part}'" }.join(%q{, "'", })})"
end

def dictionary_reference_from_article(article)
  classes = article["class"].to_s.split
  return "국어대사전" if classes.include?("nikkokuseisen")
  return "대사천" if classes.include?("daijisen")
  return "코지엔" if classes.include?("kojien") || classes.include?("koujien")

  heading = clean_node_text(article.at_css("h2"))
  return "국어대사전" if heading.include?("日本国語大辞典")
  return "대사천" if heading.include?("大辞泉")
  return "코지엔" if heading.include?("広辞苑")
  return "자통" if heading.include?("字通")
  return "신한어림" if heading.include?("新漢語林")
  return "신자원" if heading.include?("新字源")
  return "한자원" if heading.include?("漢字源")
  return "대한화사전" if heading.include?("大漢和辞典") || heading.include?("大漢和辭典")

  heading
end

def kotobank_article_matches_target?(article, word, reading)
  labels = article.css("h3, h4").map { |node| clean_node_text(node) }.reject(&:empty?)
  return false if labels.empty?

  normalized_reading = normalize_reading(reading)
  labels.any? do |label|
    kotobank_result_matches_word?(label, word) &&
      (normalized_reading.empty? || kotobank_result_reading(label) == normalized_reading)
  end
end

def preferred_kotobank_article(doc, word: nil, reading: nil)
  articles = doc.css("article.dictype")
  if word
    matched_articles = articles.select { |article| kotobank_article_matches_target?(article, word, reading) }
    articles = matched_articles unless matched_articles.empty?
  end

  SOURCE_REFERENCE_ORDER.each do |reference|
    article = articles.find { |candidate| dictionary_reference_from_article(candidate) == reference }
    return article if article
  end
  articles.first
end

def article_for_kotobank_url(doc, url, word: nil, reading: nil)
  fragment = url.to_s.split("#", 2)[1]
  preferred = preferred_kotobank_article(doc, word: word, reading: reading)
  return preferred if preferred && PROJECT_REFERENCES.include?(dictionary_reference_from_article(preferred))

  if fragment && !fragment.empty?
    marker = doc.at_xpath("//*[@id=#{xpath_literal(fragment)}]")
    article = marker&.ancestors&.find { |node| node.name == "article" && node["class"].to_s.include?("dictype") }
    return article if article
  end
  preferred || preferred_kotobank_article(doc)
end

def clean_kotobank_gloss(text, word)
  cleaned = text.to_s.gsub(/\s+/, " ").strip
  cleaned = cleaned.gsub(/〘[^〙]*〙/, "")
  cleaned = cleaned.gsub(
    /\[初出の実例\].*?(?=(?:[①②③④⑤⑥⑦⑧⑨⑩]|[（(][ァ-ヶ][）)]|\[語誌\]|#{Regexp.escape(word)}の補助注記|\z))/,
    ""
  )
  cleaned = cleaned.sub(/\[語誌\].*\z/, "")
  cleaned = cleaned.sub(/#{Regexp.escape(word)}の補助注記.*\z/, "")
  cleaned = cleaned.sub(/\[可能\].*\z/, "")
  cleaned = cleaned.sub(/\[用法\].*\z/, "")
  cleaned = cleaned.sub(/\[類語\].*\z/, "")
  clean_word_gloss_text(cleaned)
end

def find_kotobank_source(word, reading, sleep_seconds:)
  candidates = kotobank_candidates_for_query(word, sleep_seconds: sleep_seconds)
  candidates = candidates.select { |candidate| candidate["reading"] == normalize_reading(reading) } unless reading.to_s.empty?
  return { "status" => "not_found" } if candidates.empty?
  return { "status" => "ambiguous", "candidates" => candidates } if reading.to_s.empty? && candidates.length > 1

  candidate = candidates.first
  page_url = candidate["url"].split("#", 2).first
  doc = fetch_html(page_url, sleep_seconds: sleep_seconds)
  article = article_for_kotobank_url(doc, candidate["url"], word: word, reading: candidate["reading"])
  return { "status" => "no_dictionary_article", "candidate" => candidate } unless article

  reference = dictionary_reference_from_article(article)
  gloss_ja = clean_kotobank_gloss(clean_node_text(article.at_css("section.description")), word)
  return { "status" => "empty_gloss", "candidate" => candidate, "reference" => reference } if gloss_ja.empty?

  {
    "status" => "matched",
    "source" => "kotobank",
    "word" => clean_word(word),
    "reading" => candidate["reading"],
    "reading_display" => display_reading(candidate["reading"], word, nil),
    "gloss_ja" => gloss_ja,
    "url" => candidate["url"],
    "raw_label" => candidate["raw_label"],
    "reference" => reference,
    "reference_priority" => PROJECT_REFERENCES.include?(reference) ? "project" : "external"
  }
rescue StandardError => e
  { "status" => "error", "error" => "#{e.class}: #{e.message}" }
end

def display_reading(normalized_reading, word, yomi)
  return "" if normalized_reading.to_s.empty?
  return normalized_reading if yomi == "숙자훈" || yomi.to_s.match?(/[ぁ-ゖ]/) || word.to_s.match?(/[ぁ-ゖ]/)

  hiragana_to_katakana(normalized_reading)
end

def resolve_source(candidate, cache, sleep_seconds:)
  cache_key = "#{candidate.word}\t#{candidate.reading}"
  return cache[cache_key] if cache[cache_key]

  kanjipedia = find_kanjipedia_source(candidate.word, candidate.reading, sleep_seconds: sleep_seconds)
  result = if kanjipedia["status"] == "matched"
             kanjipedia
           else
             kotobank = find_kotobank_source(candidate.word, candidate.reading, sleep_seconds: sleep_seconds)
             if kotobank["status"] == "matched"
               kotobank.merge("kanjipedia_status" => kanjipedia["status"])
             else
               {
                 "status" => "unresolved",
                 "word" => candidate.word,
                 "reading" => candidate.reading,
                 "kanjipedia" => kanjipedia,
                 "kotobank" => kotobank
               }
             end
           end
  cache[cache_key] = result
end

def read_page(path)
  text = File.read(path, encoding: "UTF-8")
  front_matter = text[/\A---\n(.*?)\n---/m, 1]
  YAML.safe_load(front_matter, permitted_classes: [Date], aliases: true) || {}
end

files = Dir.glob(File.join(options[:dir], "*.md")).sort
files = files.first(options[:limit]) if options[:limit]
cache = load_json(options[:cache])

kanji_reports = files.map.with_index do |path, index|
  page = read_page(path)
  warn "[#{index + 1}/#{files.length}] #{path} #{page["char"]}"
  candidates = collect_candidates(page, max_words: options[:max_words], sleep_seconds: options[:sleep])
  compound_reports = candidates.map do |candidate|
    source = resolve_source(candidate, cache, sleep_seconds: options[:sleep])
    yomi = compound_yomi(candidate.word, source["reading"] || candidate.reading, page, jukujikun: candidate.jukujikun)
    resolved_reading = source["reading"].to_s.empty? ? candidate.reading : source["reading"]
    {
      "word" => candidate.word,
      "requested_reading" => candidate.reading,
      "resolved_reading" => resolved_reading,
      "resolved_reading_display" => display_reading(resolved_reading, candidate.word, yomi),
      "reasons" => candidate.reasons,
      "jukujikun" => candidate.jukujikun,
      "yomi" => yomi,
      "source" => source
    }
  end

  {
    "file" => path,
    "char" => page["char"],
    "unicode" => page["unicode"],
    "candidate_count" => compound_reports.length,
    "compounds" => compound_reports
  }
end

summary = Hash.new(0)
kanji_reports.each do |kanji|
  summary["kanji"] += 1
  summary["candidates"] += kanji["candidate_count"]
  kanji["compounds"].each do |row|
    source = row["source"]
    summary[source["source"] || source["status"]] += 1
  end
end

report = {
  "generated_at" => Time.now.iso8601,
  "dir" => options[:dir],
  "max_words" => options[:max_words],
  "summary" => summary,
  "kanji" => kanji_reports
}

write_json(options[:cache], cache)
write_json(options[:report], report)
puts JSON.pretty_generate(summary)
