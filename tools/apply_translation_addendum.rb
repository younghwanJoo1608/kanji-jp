#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"
require "yaml"

options = {
  addendum: "_migration_reports/codex_translation_addendum.yml",
  meaning_out: "_data/kanji_meaning_translations.yml",
  word_out: "_data/kanji_word_translations.yml"
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/apply_translation_addendum.rb [options]"
  opts.on("--addendum PATH", "Translation addendum YAML. Default: #{options[:addendum]}") { |v| options[:addendum] = v }
  opts.on("--meaning-out PATH", "Meaning translation YAML. Default: #{options[:meaning_out]}") { |v| options[:meaning_out] = v }
  opts.on("--word-out PATH", "Word translation YAML. Default: #{options[:word_out]}") { |v| options[:word_out] = v }
end.parse!

def load_yaml(path)
  return {} unless File.exist?(path)

  YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true) || {}
end

def write_yaml(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, data.to_yaml(line_width: -1), encoding: "UTF-8")
end

def deep_merge!(target, source)
  source.each do |key, value|
    if value.is_a?(Hash) && target[key].is_a?(Hash)
      deep_merge!(target[key], value)
    else
      target[key] = value
    end
  end
  target
end

addendum = load_yaml(options[:addendum])
meaning = load_yaml(options[:meaning_out])
word = load_yaml(options[:word_out])

deep_merge!(meaning, addendum.fetch("meanings", {}))
deep_merge!(word, addendum.fetch("words", {}))

write_yaml(options[:meaning_out], meaning)
write_yaml(options[:word_out], word)

puts "meaning=#{meaning.values.sum(&:length)}"
puts "word=#{word.values.sum { |by_word| by_word.values.sum(&:length) }}"
