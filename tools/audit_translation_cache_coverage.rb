#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "optparse"
require "yaml"

PLACEHOLDER = "※뜻 확인 필요"
JP_RE = /[ぁ-ゖァ-ヺ]/

options = {
  source_dir: "_translation_source_8_ja",
  meaning_translations: "_data/kanji_meaning_translations.yml",
  word_translations: "_data/kanji_word_translations.yml",
  report: "_migration_reports/translation_cache_coverage_audit.json",
  fail_on_missing: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/audit_translation_cache_coverage.rb [options]"
  opts.on("--source-dir DIR", "Japanese source stage to audit. Default: #{options[:source_dir]}") { |v| options[:source_dir] = v }
  opts.on("--meaning-translations PATH", "Meaning translation YAML. Default: #{options[:meaning_translations]}") { |v| options[:meaning_translations] = v }
  opts.on("--word-translations PATH", "Word translation YAML. Default: #{options[:word_translations]}") { |v| options[:word_translations] = v }
  opts.on("--report PATH", "Output JSON report. Default: #{options[:report]}") { |v| options[:report] = v }
  opts.on("--fail-on-missing", "Exit non-zero when uncovered or bad cache entries are found.") { options[:fail_on_missing] = true }
end.parse!

def read_page(path)
  text = File.read(path, encoding: "UTF-8")
  front = text[/\A---\n(.*?)\n---/m, 1]
  YAML.safe_load(front, permitted_classes: [Date], aliases: true) || {}
end

def load_yaml(path)
  return {} unless File.exist?(path)

  YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true) || {}
end

def write_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(data), encoding: "UTF-8")
end

def strip_variation_selectors(text)
  text.to_s.gsub(/[\uFE00-\uFE0F\u{E0100}-\u{E01EF}]/, "")
end

def compact_translation_source(text)
  text.to_s.gsub(/\s+/, "")
end

def translation_source_fingerprint(text)
  compact_translation_source(text).gsub(/[ぁ-ゖァ-ヺー]/, "")
end

def bad_translation?(text)
  value = text.to_s.strip
  value.empty? || value.include?(PLACEHOLDER) || value.match?(JP_RE)
end

def flatten_meaning_rows(rows, acc = [])
  rows.to_a.each do |row|
    if row["meanings"].is_a?(Array)
      flatten_meaning_rows(row["meanings"], acc)
    else
      acc << row
      flatten_meaning_rows(row["submeanings"], acc) if row["submeanings"].is_a?(Array)
    end
  end
  acc
end

def meaning_translation_for(translations, char, meaning_ja)
  by_char = translations[strip_variation_selectors(char)] || translations[char]
  return by_char[meaning_ja] if by_char.is_a?(Hash)

  translations[meaning_ja]
end

def fuzzy_source_translation(source_map, gloss_ja)
  source = compact_translation_source(gloss_ja)
  source_fingerprint = translation_source_fingerprint(gloss_ja)
  return "" if source.length < 3 && source_fingerprint.length < 3

  matches = source_map.filter_map do |key, value|
    compact_key = compact_translation_source(key)
    key_fingerprint = translation_source_fingerprint(key)
    next if compact_key.length < 3 && key_fingerprint.length < 3
    next unless compact_key.start_with?(source) ||
                source.start_with?(compact_key) ||
                key_fingerprint.start_with?(source_fingerprint) ||
                source_fingerprint.start_with?(key_fingerprint)

    [compact_key.length + key_fingerprint.length, value]
  end
  return "" if matches.empty?

  matches.max_by(&:first).last
end

def word_translation_for(translations, char, word, gloss_ja)
  by_char = translations[strip_variation_selectors(char)] || translations[char]
  if by_char.is_a?(Hash)
    by_word = by_char[word]
    if by_word.is_a?(Hash)
      return by_word[gloss_ja] if by_word.key?(gloss_ja)

      return fuzzy_source_translation(by_word, gloss_ja)
    end
    return by_word if by_word.is_a?(String)
    return by_char[gloss_ja]
  end

  translations[gloss_ja]
end

meaning_translations = load_yaml(options[:meaning_translations])
word_translations = load_yaml(options[:word_translations])

missing_meanings = []
bad_meanings = []
missing_words = []
bad_words = []
unresolved_words = []
stats = Hash.new(0)

Dir[File.join(options[:source_dir], "*.md")].sort.each do |path|
  page = read_page(path)
  char = page["char"].to_s
  unicode = page["unicode"].to_s

  flatten_meaning_rows(page["meanings"]).each do |row|
    source = row["meaning"].to_s.strip
    next if source.empty?

    stats[:meaning_sources] += 1
    translated = meaning_translation_for(meaning_translations, char, source)
    if translated.to_s.strip.empty?
      missing_meanings << {
        "file" => path,
        "char" => char,
        "unicode" => unicode,
        "meaning_ja" => source,
        "example" => row["example"]
      }
    elsif bad_translation?(translated)
      bad_meanings << {
        "file" => path,
        "char" => char,
        "unicode" => unicode,
        "meaning_ja" => source,
        "translation" => translated
      }
    end
  end

  Array(page["compounds"]).each do |row|
    word = row["word"].to_s
    gloss = row["gloss"].to_s.strip
    next if word.empty? || gloss.empty?

    stats[:word_sources] += 1
    if gloss.include?(PLACEHOLDER)
      unresolved_words << {
        "file" => path,
        "char" => char,
        "unicode" => unicode,
        "word" => word,
        "reading" => row["reading"],
        "gloss" => gloss
      }
      next
    end

    translated = word_translation_for(word_translations, char, word, gloss)
    if translated.to_s.strip.empty?
      missing_words << {
        "file" => path,
        "char" => char,
        "unicode" => unicode,
        "word" => word,
        "reading" => row["reading"],
        "gloss_ja" => gloss,
        "reference" => row["reference"]
      }
    elsif bad_translation?(translated)
      bad_words << {
        "file" => path,
        "char" => char,
        "unicode" => unicode,
        "word" => word,
        "reading" => row["reading"],
        "gloss_ja" => gloss,
        "translation" => translated,
        "reference" => row["reference"]
      }
    end
  end
end

report = {
  "summary" => {
    "source_dir" => options[:source_dir],
    "pages" => Dir[File.join(options[:source_dir], "*.md")].length,
    "meaning_sources" => stats[:meaning_sources],
    "word_sources" => stats[:word_sources],
    "unresolved_word_sources" => unresolved_words.length,
    "missing_meanings" => missing_meanings.length,
    "bad_meaning_translations" => bad_meanings.length,
    "missing_words" => missing_words.length,
    "bad_word_translations" => bad_words.length
  },
  "missing_meanings" => missing_meanings,
  "bad_meaning_translations" => bad_meanings,
  "missing_words" => missing_words,
  "bad_word_translations" => bad_words,
  "unresolved_word_sources" => unresolved_words
}

write_json(options[:report], report)
puts JSON.pretty_generate(report["summary"])

if options[:fail_on_missing] &&
   (missing_meanings.any? || bad_meanings.any? || missing_words.any? || bad_words.any?)
  exit 1
end
