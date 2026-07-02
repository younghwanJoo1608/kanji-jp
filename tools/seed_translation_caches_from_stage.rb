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
  translated_dir: "_kanji_8",
  word_report: "_migration_reports/kanji_word_source_report.json",
  meaning_out: "_data/kanji_meaning_translations.yml",
  word_out: "_data/kanji_word_translations.yml",
  missing_out: "_migration_reports/translation_cache_missing.json"
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/seed_translation_caches_from_stage.rb [options]"
  opts.on("--source-dir DIR", "Japanese source stage. Default: #{options[:source_dir]}") { |v| options[:source_dir] = v }
  opts.on("--translated-dir DIR", "Translated stage to use as Codex-review seed. Default: #{options[:translated_dir]}") { |v| options[:translated_dir] = v }
  opts.on("--word-report PATH", "Exact word source report. Default: #{options[:word_report]}") { |v| options[:word_report] = v }
  opts.on("--meaning-out PATH", "Meaning translation YAML. Default: #{options[:meaning_out]}") { |v| options[:meaning_out] = v }
  opts.on("--word-out PATH", "Word translation YAML. Default: #{options[:word_out]}") { |v| options[:word_out] = v }
  opts.on("--missing-out PATH", "Missing translation report JSON. Default: #{options[:missing_out]}") { |v| options[:missing_out] = v }
end.parse!

def read_page(path)
  text = File.read(path, encoding: "UTF-8")
  front = text[/\A---\n(.*?)\n---/m, 1]
  YAML.safe_load(front, permitted_classes: [Date], aliases: true) || {}
end

def write_yaml(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, data.to_yaml(line_width: -1), encoding: "UTF-8")
end

def load_yaml(path)
  return {} unless File.exist?(path)

  YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true) || {}
end

def write_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(data), encoding: "UTF-8")
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

def normalize_reading(text)
  text.to_s.tr("ァ-ヶ", "ぁ-ゖ").tr("－‐‑‒–—―", "-").gsub(/[-・･\s]/, "").strip
end

meaning_cache = load_yaml(options[:meaning_out])
meaning_missing = []

Dir[File.join(options[:source_dir], "*.md")].sort.each do |source_path|
  source_page = read_page(source_path)
  translated_path = File.join(options[:translated_dir], File.basename(source_path))
  translated_page = File.exist?(translated_path) ? read_page(translated_path) : {}
  char = source_page["char"].to_s
  source_rows = flatten_meaning_rows(source_page["meanings"])
  translated_rows = flatten_meaning_rows(translated_page["meanings"])

  source_rows.each_with_index do |row, index|
    source = row["meaning"].to_s.strip
    existing = meaning_cache.dig(char, source)
    next if existing && !bad_translation?(existing)

    translated = translated_rows[index]&.fetch("meaning", "").to_s.strip
    if bad_translation?(translated)
      meaning_missing << {
        "char" => char,
        "source" => source,
        "example" => row["example"],
        "reason" => translated.empty? ? "empty" : "bad_seed"
      }
      next
    end

    meaning_cache[char] ||= {}
    meaning_cache[char][source] = translated
  end
end

word_cache = load_yaml(options[:word_out])
word_missing = []
translated_pages = Dir[File.join(options[:translated_dir], "*.md")].each_with_object({}) do |path, pages|
  page = read_page(path)
  pages[page["char"].to_s] = page
end
report = JSON.parse(File.read(options[:word_report], encoding: "UTF-8"))

report.fetch("kanji", []).each do |entry|
  char = entry["char"].to_s
  translated_compounds = translated_pages.fetch(char, {}).fetch("compounds", [])
  entry.fetch("compounds", []).each do |compound|
    source = compound["source"] || {}
    next unless source["status"] == "matched"

    gloss_ja = source["gloss_ja"].to_s.strip
    word = compound["word"].to_s
    existing = word_cache.dig(char, word, gloss_ja)
    next if existing && !bad_translation?(existing)

    reading = normalize_reading(compound["resolved_reading"] || compound["requested_reading"])
    seed = translated_compounds.find do |row|
      row["word"].to_s == word && normalize_reading(row["reading"]) == reading
    end
    translated = seed&.fetch("gloss", "").to_s.strip
    if bad_translation?(translated)
      word_missing << {
        "char" => char,
        "word" => word,
        "reading" => compound["resolved_reading"] || compound["requested_reading"],
        "gloss_ja" => gloss_ja,
        "source" => source["source"],
        "reference" => source["reference"],
        "reason" => translated.empty? ? "empty" : "bad_seed"
      }
      next
    end

    word_cache[char] ||= {}
    word_cache[char][word] ||= {}
    word_cache[char][word][gloss_ja] = translated
  end
end

write_yaml(options[:meaning_out], meaning_cache)
write_yaml(options[:word_out], word_cache)
write_json(options[:missing_out], {
  "summary" => {
    "meaning_cached" => meaning_cache.values.sum(&:length),
    "meaning_missing" => meaning_missing.length,
    "word_cached" => word_cache.values.sum { |by_word| by_word.values.sum(&:length) },
    "word_missing" => word_missing.length
  },
  "meaning_missing" => meaning_missing,
  "word_missing" => word_missing
})

puts JSON.pretty_generate(JSON.parse(File.read(options[:missing_out], encoding: "UTF-8"))["summary"])
