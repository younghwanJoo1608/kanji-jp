#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

TAGS = %w[불교 생물 지명 나라 단위].freeze

RULES = [
  {
    tag: "단위",
    confidence: "strong",
    patterns: [
      /[[:space:]]단위[.。]/,
      /단위의 이름/,
      /세는 말/,
      /단위로 하는/,
      /단위로 한다/,
      /(?:수|길이|거리|면적|넓이|부피|용량|화폐|비율|시간|각도|무게)의 단위/,
      /(?:약|1)[^.。]*(?:리터|미터|센티미터|cm|mm|g|아르|헥타르|평방|제곱|입방)/
    ]
  },
  {
    tag: "지명",
    confidence: "strong",
    patterns: [
      /の国」의 (?:약칭|다른 이름|다른 말)/,
      /노쿠니「[^」]+」의 (?:약칭|다른 이름|다른 말)/,
      /현재의 .*현/,
      /현에 해당/,
      /옛 국명의 하나/
    ]
  },
  {
    tag: "나라",
    confidence: "strong",
    patterns: [
      /일본日本의 약칭/,
      /아메리카.*약칭/,
      /미합중국/,
      /일본과 미합중국/
    ]
  },
  {
    tag: "불교",
    confidence: "strong",
    patterns: [
      /불교/,
      /불상/,
      /비불/,
      /불감/,
      /불도/,
      /불사/,
      /사찰/,
      /사원(?:에서|의 (?:탑|이름))/,
      /승려/,
      /비구니/,
      /부처(?:가|님|의 덕|의 세계|를|・|나 보살)/,
      /보살(?!피)/,
      /귀의(?:하다|를|를 나타냄|\.|,|$)/,
      /극락정토/,
      /정토/,
      /중생/,
      /피안/,
      /출세간/,
      /법요/,
      /불회/
    ]
  },
  {
    tag: "생물",
    confidence: "strong",
    patterns: [
      /포유동물/,
      /조류의 총칭/,
      /어류(?:의 총칭|와 패류)/,
      /곤충류의 총칭/,
      /곤충의 총칭/,
      /선태식물/,
      /벼과/,
      /국화과/,
      /장미과/,
      /뽕나무과/,
      /개과/,
      /소과/,
      /말과의/,
      /연체동물/,
      /절지동물/,
      /홍조류/,
      /녹조류/
    ]
  }
].freeze

options = {
  apply: false,
  confidence: "strong"
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/tag_audit.rb [--apply] [--all] [files...]"
  opts.on("--apply", "Insert missing tags in-place for matching rules.") { options[:apply] = true }
  opts.on("--all", "Reserved for future weaker rules; currently same as strong.") { options[:confidence] = "all" }
  opts.on("-h", "--help", "Show this help.") do
    puts opts
    exit
  end
end.parse!

paths = ARGV.empty? ? Dir["_kanji/*.md"] : ARGV
paths = paths.flat_map { |path| File.directory?(path) ? Dir[File.join(path, "*.md")] : path }

def quoted_field(line)
  match = line.match(/\b(meaning|gloss):\s*"((?:\\"|[^"])*)"/)
  return nil unless match

  {
    field: match[1],
    text: match[2],
    start_index: match.begin(2),
    end_index: match.end(2)
  }
end

def existing_tag?(text, tag)
  text.include?("[#{tag}]") || (tag == "지명" && text.include?("[나라]"))
end

def any_existing_tag?(text)
  TAGS.any? { |tag| text.include?("[#{tag}]") }
end

def segments(text)
  matches = text.to_enum(:scan, /(\(\d+\)|[①②③④⑤⑥⑦⑧⑨⑩])\s*/).map do
    Regexp.last_match
  end
  return [] if matches.empty?

  matches.each_with_index.map do |match, index|
    content_start = match.end(0)
    content_end = index + 1 < matches.length ? matches[index + 1].begin(0) : text.length
    {
      marker_start: match.begin(0),
      content_start: content_start,
      content: text[content_start...content_end]
    }
  end
end

def insert_tag(text, rule)
  tag = rule[:tag]
  return text if existing_tag?(text, tag)

  segments(text).each do |segment|
    next unless rule[:patterns].any? { |pattern| segment[:content].match?(pattern) }

    return text.dup.insert(segment[:content_start], "[#{tag}] ")
  end

  prefix_patterns = [
    /\A(\(\d+\)\s*)/,
    /\A([①②③④⑤⑥⑦⑧⑨⑩]\s*)/
  ]

  prefix_patterns.each do |pattern|
    return text.sub(pattern, "\\1[#{tag}] ") if text.match?(pattern)
  end

  "[#{tag}] #{text}"
end

def rule_for(text)
  return nil if any_existing_tag?(text)

  RULES.find do |rule|
    next unless rule[:patterns].any? { |pattern| text.match?(pattern) }

    rule
  end
end

changes = []
paths.sort.each do |path|
  original = File.read(path, encoding: "UTF-8")
  lines = original.lines
  changed = false

  lines.each_with_index do |line, index|
    field = quoted_field(line)
    next unless field

    rule = rule_for(field[:text])
    next unless rule

    replacement = insert_tag(field[:text], rule)
    changes << {
      path: path,
      line: index + 1,
      field: field[:field],
      tag: rule[:tag],
      text: field[:text],
      replacement: replacement
    }

    next unless options[:apply]

    line[field[:start_index]...field[:end_index]] = replacement
    lines[index] = line
    changed = true
  end

  File.write(path, lines.join, encoding: "UTF-8") if options[:apply] && changed
end

if changes.empty?
  puts "No missing strong tag candidates found."
  exit
end

changes.each do |change|
  puts "#{change[:path]}:#{change[:line]} #{change[:field]} [#{change[:tag]}]"
  puts "  - #{change[:text]}"
  puts "  + #{change[:replacement]}" if options[:apply]
end

puts
puts "#{options[:apply] ? "Applied" : "Found"} #{changes.length} missing tag candidate(s)."
puts "Run with --apply to update files in-place." unless options[:apply]
