#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"
require "net/http"
require "nokogiri"
require "open-uri"
require "optparse"
require "set"
require "uri"
require "yaml"

DEFAULT_BASE_URL = "https://kanji.jitenon.jp"
DEFAULT_KANJIPEDIA_BASE_URL = "https://www.kanjipedia.jp"
DEFAULT_KOTOBANK_BASE_URL = "https://kotobank.jp"
DEFAULT_FINAL_DIR = "_kanji"
UNRESOLVED_WORD_GLOSS = "※뜻 확인 필요"
UNRESOLVED_WORD_READING = "※読み確認必要"
PROJECT_REFERENCES = %w[국어대사전 코지엔 대사천 신한어림 자통 신자원 한자원 대한화사전 자통망].freeze
SOURCE_REFERENCE_ORDER = %w[국어대사전 코지엔 대사천 신한어림 자통 신자원 한자원 대한화사전 자통망].freeze
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

Grade = Struct.new(:input, :number, :pre, :label, :path_code, keyword_init: true) do
  def url(base_url)
    "#{base_url}/cat/kyu#{path_code}#{pre ? "j" : ""}"
  end
end

ListEntry = Struct.new(:char, :unicode, :url, :readings, keyword_init: true)
WordCandidate = Struct.new(:word, :reading, :url, :raw_label, :jukujikun, keyword_init: true)
RequiredWordTarget = Struct.new(:word, :reading, :reason, :jukujikun, keyword_init: true)

options = {
  grade: "8",
  base_url: DEFAULT_BASE_URL,
  final_dir: DEFAULT_FINAL_DIR,
  stage_dir: nil,
  kanjipedia: false,
  kanjipedia_base_url: DEFAULT_KANJIPEDIA_BASE_URL,
  kanjipedia_cache: nil,
  meaning_translations: nil,
  require_meaning_translations: false,
  kanjipedia_words: false,
  max_words: 12,
  word_translations: nil,
  require_word_translations: false,
  kotobank_fallback: false,
  kotobank_base_url: DEFAULT_KOTOBANK_BASE_URL,
  allow_untranslated: false,
  show: "missing",
  json: nil,
  write_stage: nil,
  snapshot: nil,
  jitenon_search: nil,
  unicode: nil,
  char: nil,
  limit: nil,
  sleep: 1.0
}

OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/kanji_grade_harness.rb [options]"
  opts.on("-g", "--grade GRADE", "Kanken grade, e.g. 8, 9, 10, pre2, 준2, 準2.") { |v| options[:grade] = v }
  opts.on("--base-url URL", "Source site base URL. Default: #{DEFAULT_BASE_URL}") { |v| options[:base_url] = v }
  opts.on("--final-dir DIR", "Completed kanji directory. Default: #{DEFAULT_FINAL_DIR}") { |v| options[:final_dir] = v }
  opts.on("--stage-dir DIR", "Staging kanji directory. Default: _kanji_<grade>") { |v| options[:stage_dir] = v }
  opts.on("--kanjipedia", "Enrich generated files with readings and meanings from kanjipedia.jp.") { options[:kanjipedia] = true }
  opts.on("--kanjipedia-base-url URL", "Kanjipedia base URL. Default: #{DEFAULT_KANJIPEDIA_BASE_URL}") { |v| options[:kanjipedia_base_url] = v }
  opts.on("--kanjipedia-cache PATH", "Optional JSON cache for resolved kanjipedia kanji URLs.") { |v| options[:kanjipedia_cache] = v }
  opts.on("--meaning-translations PATH", "Optional YAML cache mapping kanjipedia Japanese meanings to Korean.") { |v| options[:meaning_translations] = v }
  opts.on("--require-meaning-translations", "Fail if a kanjipedia meaning does not have a Korean translation.") { options[:require_meaning_translations] = true }
  opts.on("--kanjipedia-words", "Enrich generated files with selected compounds from kanjipedia word search.") { options[:kanjipedia_words] = true }
  opts.on("--max-words N", Integer, "Maximum selected kanjipedia words per kanji. Default: 12") { |v| options[:max_words] = v }
  opts.on("--word-translations PATH", "Optional YAML cache mapping kanjipedia Japanese word glosses to Korean.") { |v| options[:word_translations] = v }
  opts.on("--require-word-translations", "Fail if a kanjipedia word gloss does not have a Korean translation.") { options[:require_word_translations] = true }
  opts.on("--kotobank-fallback", "Fetch missing required words from kotobank.jp after kanjipedia word search.") { options[:kotobank_fallback] = true }
  opts.on("--kotobank-base-url URL", "Kotobank base URL. Default: #{DEFAULT_KOTOBANK_BASE_URL}") { |v| options[:kotobank_base_url] = v }
  opts.on("--allow-untranslated", "Allow writing Japanese meanings/glosses when translation cache entries are missing.") { options[:allow_untranslated] = true }
  opts.on("--show MODE", %w[all missing staged completed], "Rows to print. Default: missing") { |v| options[:show] = v }
  opts.on("--json PATH", "Write the audit report as JSON.") { |v| options[:json] = v }
  opts.on("--write-stage MODE", %w[missing staged all], "Write stage files for missing, staged, or all non-completed rows.") { |v| options[:write_stage] = v }
  opts.on("--snapshot PATH", "Required snapshot path when writing a real _kanji_* stage directory.") { |v| options[:snapshot] = v }
  opts.on("--jitenon-search QUERY", "Resolve one kanji through kanji.jitenon.jp search, e.g. 659C or 斜.") { |v| options[:jitenon_search] = v }
  opts.on("--unicode CODE", "Limit work to one Unicode codepoint, e.g. 659C or U+659C.") { |v| options[:unicode] = v }
  opts.on("--char CHAR", "Limit work to one kanji character.") { |v| options[:char] = v }
  opts.on("--limit N", Integer, "Limit generated files.") { |v| options[:limit] = v }
  opts.on("--sleep SECONDS", Float, "Delay between detail page requests. Default: 1.0") { |v| options[:sleep] = v }
  opts.on("-h", "--help", "Show this help.") do
    puts opts
    exit
  end
end.parse!

def parse_grade(value)
  raw = value.to_s.strip
  pre = raw.match?(/\A(?:pre|jun|準|준)/i) || raw.match?(/j\z/i)
  number = raw[/\d+/]&.to_i
  raise ArgumentError, "grade must contain a number: #{value.inspect}" unless number
  raise ArgumentError, "grade must be between 1 and 10: #{value.inspect}" unless (1..10).cover?(number)
  raise ArgumentError, "10級 does not have a 準 grade" if pre && number == 10

  Grade.new(
    input: raw,
    number: number,
    pre: pre,
    label: "#{pre ? "準" : ""}#{number}級",
    path_code: number == 10 ? "10" : format("%02d", number)
  )
end

def default_stage_dir(grade)
  suffix = grade.pre ? "jun#{grade.number}" : grade.number.to_s
  "_kanji_#{suffix}"
end

def fetch_html(url)
  headers = {
    "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  }
  Nokogiri::HTML(URI.open(url, headers))
end

def post_jitenon_search_url(query, base_url)
  code_query = unicode_code_query(query)
  form = if code_query
           { "value" => code_query, "how" => "すべて", "search" => "contain" }
         else
           { "value" => strip_variation_selectors(query).strip, "how" => "漢字", "search" => "match" }
         end

  uri = URI.join(base_url, "/include/page_send.php")
  request = Net::HTTP::Post.new(uri)
  request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "\
                          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  request.set_form_data(form)

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end
  raise "Jitenon search failed for #{query.inspect}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  location = response.body.to_s.strip
  raise "Jitenon search returned an empty URL for #{query.inspect}" if location.empty?

  URI.join(base_url, location).to_s
end

def kanji_unicode(char)
  "U+#{char.codepoints.first.to_s(16).upcase}"
end

def normalize_unicode_filter(value)
  raw = value.to_s.strip
  return "" if raw.empty?

  code = raw.sub(/\AU\+/i, "").upcase
  "U+#{code}"
end

def unicode_code_query(value)
  raw = normalize_digits(value).to_s.strip.sub(/\AU\+/i, "").upcase
  raw.match?(/\A[0-9A-F]{4,6}\z/) ? raw : nil
end

def normalize_digits(value)
  value.to_s.tr("０-９", "0-9")
end

def clean_node_text(node)
  return "" unless node

  copy = node.dup
  copy.css("rt,.term-popover,.help-btn").remove
  copy.text.gsub(/\s+/, " ").strip
end

def clean_heading(node)
  clean_node_text(node).gsub(/\s+/, "")
end

def strip_variation_selectors(text)
  text.to_s.gsub(/[\uFE00-\uFE0F\u{E0100}-\u{E01EF}]/, "")
end

def hiragana_to_katakana(text)
  text.tr("ぁ-ゖ", "ァ-ヶ")
end

def katakana_to_hiragana(text)
  text.tr("ァ-ヶ", "ぁ-ゖ")
end

def normalize_reading_kana(text, kind)
  case kind
  when :onyomi
    hiragana_to_katakana(text)
  when :kunyomi
    katakana_to_hiragana(text)
  else
    text
  end
end

def jitenon_reading(raw, kind)
  text = raw.to_s.strip.gsub(/[（(]([^）)]+)[）)]/, '-\1')
  normalize_reading_kana(text, kind)
end

def normalize_word_reading(text)
  text.to_s
      .sub(/[（(]その他表記[）)].*\z/, "")
      .tr("ァ-ヶ", "ぁ-ゖ")
      .tr("－‐‑‒–—―", "-")
      .gsub(/[-・･\s]/, "")
      .strip
end

def normalize_kotobank_reading(text)
  text.to_s
      .gsub(/[（(][^）)]*[）)]/, "")
      .gsub(/[［\[][^\]］]*[\]］]/, "")
      .then { |value| normalize_word_reading(value) }
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
  normalized = normalize_word_reading(reading)
  bases = [normalized, fold_small_kana(normalized)].uniq.reject(&:empty?)
  bases += bases.filter_map { |base| sokuon_reading_variant(base) }
  bases.flat_map { |base| voiced_reading_variants(base) }.uniq
end

def reading_contains_yomi?(reading, yomi)
  normalized_reading = normalize_word_reading(reading)
  yomi_reading_variants(yomi).any? { |variant| normalized_reading.include?(variant) }
end

def clean_word_text(text)
  text.to_s
      .gsub(/[△▲▽▼]/, "")
      .gsub(/[〈〉《》]/, "")
      .gsub(/\s+/, "")
      .strip
end

def reading_type(td)
  src = td.at_css("img")&.[]("src").to_s
  return "상용" if src.match?(%r{yomi_icon[1-3]\.svg})

  ""
end

def extract_reading(td, kind)
  text = td.at_css("a")&.text&.strip
  text ||= clean_node_text(td).sub(/\A[[:space:]]*/, "")
  jitenon_reading(text, kind)
end

def load_json_cache(path)
  return {} if path.nil? || path.empty? || !File.exist?(path)

  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue JSON::ParserError => e
  warn "JSON cache parse failed for #{path}: #{e.message}"
  {}
end

def write_json_cache(path, data)
  return if path.nil? || path.empty?

  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(data), encoding: "UTF-8")
end

def load_meaning_translations(path)
  return {} if path.nil? || path.empty? || !File.exist?(path)

  YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: true) || {}
rescue Psych::SyntaxError => e
  warn "Translation cache parse failed for #{path}: #{e.message}"
  {}
end

def kanjipedia_search_url(base_url, char)
  query = URI.encode_www_form(k: strip_variation_selectors(char), kt: "1", sk: "perfect")
  "#{base_url}/search?#{query}"
end

def kanjipedia_word_search_url(base_url, char)
  query = URI.encode_www_form(
    k: strip_variation_selectors(char),
    kt: "1",
    wt: "1",
    ky: "1",
    wy: "1",
    sk: "partial",
    t: "kotoba"
  )
  "#{base_url}/search?#{query}"
end

def kotobank_word_url(base_url, word)
  "#{base_url}/word/#{URI.encode_www_form_component(word)}"
end

def kotobank_word_search_url(base_url, word)
  "#{base_url}/search?#{URI.encode_www_form(q: word, t: "all")}"
end

def kanjipedia_word_search_page_urls(first_doc, first_url, base_url)
  urls = Set[first_url]
  first_doc.css(".pagerSection a[href]").each do |link|
    href = link["href"].to_s
    next unless href.include?("t=kotoba")

    urls << URI.join(base_url, href).to_s
  end
  urls.to_a
end

def resolve_kanjipedia_url(char, base_url, cache)
  cache_key = strip_variation_selectors(char)
  cached = cache[cache_key]
  return cached if cached && !cached.empty?

  doc = fetch_html(kanjipedia_search_url(base_url, cache_key))
  candidates = doc.css("#resultKanjiList a").filter_map do |link|
    href = link["href"].to_s
    text = strip_variation_selectors(clean_node_text(link))
    next unless href.match?(%r{\A/kanji/(?:other/)?\d+\z})
    next unless text == cache_key

    URI.join(base_url, href).to_s
  end

  regular = candidates.reject { |url| url.include?("/kanji/other/") }
  selected = regular.first || candidates.first
  raise "No kanjipedia kanji result for #{cache_key}" unless selected
  raise "Ambiguous kanjipedia kanji result for #{cache_key}: #{candidates.join(", ")}" if regular.length > 1

  cache[cache_key] = selected
end

def reading_marker_image?(node)
  src = node["src"].to_s
  alt = node["alt"].to_s
  src.include?("icon_loanword") || alt == "外"
end

def split_reading_buffer(buffer, kind, type)
  buffer.to_s
        .gsub(/[[:space:]]+/, " ")
        .split(/[・\s]+/)
        .map { |reading| jitenon_reading(reading, kind) }
        .reject(&:empty?)
        .map { |reading| { "reading" => reading, "type" => type } }
end

def kanjipedia_readings_from_node(node, kind)
  readings = []
  buffer = +""
  current_type = "상용"

  flush = lambda do
    readings.concat(split_reading_buffer(buffer, kind, current_type))
    buffer.clear
  end

  walk = lambda do |current|
    if current.text?
      buffer << current.text
      return
    end
    return unless current.element?

    if current.name == "img" && reading_marker_image?(current)
      flush.call
      current_type = ""
      return
    end

    if current.name == "span" && current["class"].to_s.split.include?("txtNormal")
      okurigana = clean_node_text(current)
      buffer << "-#{okurigana}" unless okurigana.empty?
      return
    end

    current.children.each { |child| walk.call(child) }
  end

  node.children.each { |child| walk.call(child) }
  flush.call
  readings
end

def extract_kanjipedia_readings(doc)
  readings = { "onyomi" => [], "kunyomi" => [] }

  doc.css("#onkunList li").each do |li|
    heading = li.at_css("img")&.[]("alt").to_s
    body = li.at_css(".onkunYomi")
    next unless body

    case heading
    when "音"
      readings["onyomi"].concat(kanjipedia_readings_from_node(body, :onyomi))
    when "訓"
      readings["kunyomi"].concat(kanjipedia_readings_from_node(body, :kunyomi))
    end
  end

  readings
end

CIRCLED_NUMBER_PATTERN = /[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]/
KATAKANA_SUBMEANING_PATTERN = /[（(][ア-ン][）)]/
LATIN_MEANING_GROUP_PATTERN = /[（(][A-Z][）)]\s*[［\[]([^］\]]+)[］\]]/
GENRE_TAGS = %w[불교 생물 지명 나라 단위].freeze
GENRE_RULES = [
  {
    tag: "단위",
    patterns: [
      /[[:space:]]단위[.。]/,
      /단위의 이름/,
      /세는 말/,
      /단위로 하는/,
      /단위로 한다/,
      /(?:수|길이|거리|면적|넓이|부피|용량|화폐|비율|시간|각도|무게)의 단위/
    ]
  },
  {
    tag: "지명",
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
    patterns: [
      /일본日本의 약칭/,
      /아메리카.*약칭/,
      /미합중국/,
      /일본과 미합중국/,
      /공화국/
    ]
  },
  {
    tag: "불교",
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
    patterns: [
      /포유동물/,
      /조류의 총칭/,
      /어류(?:의 총칭|와 패류)/,
      /곤충류의 총칭/,
      /곤충의 총칭/,
      /선태식물/,
      /양치식물/,
      /치어/,
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

def cleanup_example(text)
  text.to_s
      .gsub(/[（(][^）)]*[）)]/, "")
      .gsub(/[△▲▽▼]/, "")
      .gsub(/[〈〉《》]/, "")
      .strip
end

def split_kanjipedia_meaning_text(text)
  normalized = text.to_s.gsub(/\s+/, " ").strip
  return [] if normalized.empty?

  if normalized.match?(CIRCLED_NUMBER_PATTERN)
    normalized.split(/(?=#{CIRCLED_NUMBER_PATTERN})/).reject(&:empty?)
  else
    [normalized]
  end
end

def trim_kanjipedia_cross_reference_tail(text)
  text.to_s
      .sub(/\s*(?:#{KATAKANA_SUBMEANING_PATTERN}){2,}[^「」]*\z/, "")
      .strip
end

def relation_marker_image?(node)
  src = node["src"].to_s
  alt = node["alt"].to_s
  %w[類 対].include?(alt) || src.match?(%r{icon_(?:rui|tai)\.png})
end

def kanjipedia_meaning_text(node)
  return "" unless node

  result = +""
  skipping_relation = false
  restart_pattern = /#{LATIN_MEANING_GROUP_PATTERN}/

  node.children.each do |child|
    if child.element? && child.name == "img" && relation_marker_image?(child)
      skipping_relation = true
      next
    end

    text = child.text
    if skipping_relation
      match = text.match(restart_pattern)
      next unless match

      result << text[match.begin(0)..]
      skipping_relation = false
    else
      result << text
    end
  end

  result.gsub(/\s+/, " ").strip
end

def text_before_marker_image(node, marker_alt)
  return "" unless node

  result = +""
  node.children.each do |child|
    break if child.element? && child.name == "img" && child["alt"].to_s == marker_alt

    result << child.text
  end
  result.gsub(/\s+/, " ").strip
end

def text_before_any_marker_image(node, marker_alts)
  return "" unless node

  result = +""
  node.children.each do |child|
    break if child.element? && child.name == "img" && marker_alts.include?(child["alt"].to_s)

    result << child.text
  end
  result.gsub(/\s+/, " ").strip
end

def split_kanjipedia_submeanings(text)
  text = trim_kanjipedia_cross_reference_tail(text)
  return nil unless text.match?(KATAKANA_SUBMEANING_PATTERN)

  parent, rest = text.split(KATAKANA_SUBMEANING_PATTERN, 2)
  return nil if rest.nil?

  subparts = text[text.index(KATAKANA_SUBMEANING_PATTERN)..].split(/(?=#{KATAKANA_SUBMEANING_PATTERN})/)
  submeanings = subparts.filter_map do |part|
    body = trim_kanjipedia_cross_reference_tail(part.sub(/\A#{KATAKANA_SUBMEANING_PATTERN}/, "").strip)
    next if body.empty?

    example = cleanup_example(body[/「([^」]+)」/, 1])
    meaning = body.split("「", 2).first.to_s.strip
    next if meaning.empty?

    row = { "meaning" => meaning }
    row["example"] = example unless example.empty?
    row
  end

  return nil if submeanings.empty?

  {
    "meaning" => parent.to_s.strip,
    "submeanings" => submeanings
  }
end

def parse_kanjipedia_meaning_part(part, reading = nil)
  stripped = part.sub(/\A#{CIRCLED_NUMBER_PATTERN}/, "").strip
  submeaning_row = split_kanjipedia_submeanings(stripped)
  if submeaning_row
    submeaning_row["reading"] = reading if reading
    return submeaning_row
  end

  quoted = stripped.scan(/「([^」]+)」/).flatten
  if quoted.length >= 2 && stripped.start_with?("「")
    example = cleanup_example(quoted.last)
    last_example = "「#{quoted.last}」"
    meaning = stripped[0...stripped.rindex(last_example)].to_s.strip
  else
    example = cleanup_example(quoted.first)
    meaning = stripped.split("「", 2).first.to_s.strip
  end
  return nil if meaning.empty?

  row = { "meaning" => meaning }
  row = { "reading" => reading }.merge(row) if reading
  row["example"] = example unless example.empty?
  row
end

def split_kanjipedia_meaning_groups(text)
  matches = []
  text.to_enum(:scan, LATIN_MEANING_GROUP_PATTERN).each do
    match = Regexp.last_match
    matches << { start: match.begin(0), finish: match.end(0), reading: match[1] }
  end
  return nil if matches.empty?

  matches.filter_map.with_index do |match, index|
    next_start = matches[index + 1]&.fetch(:start) || text.length
    body = text[match[:finish]...next_start].to_s.strip
    child_meanings = []
    split_kanjipedia_meaning_text(body).each do |part|
      row = parse_kanjipedia_meaning_part(part)
      child_meanings << row if row
    end
    next if child_meanings.empty?

    { "reading" => match[:reading], "meanings" => child_meanings }
  end
end

def extract_kanjipedia_meanings(doc)
  item = doc.css("#kanjiRightSection > ul > li").find do |li|
    li.at_css("h4 img")&.[]("alt") == "意味"
  end
  text = kanjipedia_meaning_text(item.at_css("div p")) if item
  grouped_rows = split_kanjipedia_meaning_groups(text.to_s)
  return grouped_rows if grouped_rows

  split_kanjipedia_meaning_text(text).filter_map do |part|
    parse_kanjipedia_meaning_part(part)
  end
end

def translation_for(translations, char, meaning_ja)
  by_char = translations[strip_variation_selectors(char)] || translations[char]
  return by_char[meaning_ja] if by_char.is_a?(Hash)

  translations[meaning_ja]
end

def existing_genre_tag?(text, tag)
  text.include?("[#{tag}]") || (tag == "지명" && text.include?("[나라]"))
end

def any_existing_genre_tag?(text)
  GENRE_TAGS.any? { |tag| text.include?("[#{tag}]") }
end

def genre_rule_for(text)
  return nil if any_existing_genre_tag?(text)

  GENRE_RULES.find do |rule|
    rule[:patterns].any? { |pattern| text.match?(pattern) }
  end
end

def add_genre_tag(text)
  rule = genre_rule_for(text.to_s)
  return text unless rule
  return text if existing_genre_tag?(text, rule[:tag])

  "[#{rule[:tag]}] #{text}"
end

def numbered_gloss_parts(text)
  source = text.to_s
  matches = source.to_enum(:scan, CIRCLED_NUMBER_PATTERN).map { Regexp.last_match }
  return [] if matches.empty?

  matches.each_with_index.map do |match, index|
    next_match = matches[index + 1]
    body_start = match.end(0)
    body_end = next_match ? next_match.begin(0) : source.length
    {
      marker: match[0],
      start: match.begin(0),
      body_start: body_start,
      body: source[body_start...body_end].to_s.strip
    }
  end
end

def add_word_genre_tags(text)
  source = text.to_s.strip
  return source if source.empty? || any_existing_genre_tag?(source)

  parts = numbered_gloss_parts(source)
  return add_genre_tag(source) if parts.length <= 1

  tagged_parts = parts.filter_map do |part|
    rule = genre_rule_for(part[:body])
    [part, rule[:tag]] if rule
  end
  tags = tagged_parts.map(&:last).uniq
  return "[#{tags.first}] #{source}" if tags.length == 1 && tagged_parts.length == parts.length
  return source if tagged_parts.empty?

  tagged_by_start = tagged_parts.to_h { |part, tag| [part[:start], tag] }
  source.gsub(/(#{CIRCLED_NUMBER_PATTERN})\s*/) do
    marker = Regexp.last_match(1)
    tag = tagged_by_start[Regexp.last_match.begin(0)]
    tag ? "#{marker} [#{tag}] " : "#{marker} "
  end
end

def apply_genre_tags_to_row!(row)
  if row["meanings"].is_a?(Array)
    row["meanings"].each { |child| apply_genre_tags_to_row!(child) }
    return
  end

  row["meaning"] = add_genre_tag(row["meaning"]) if row["meaning"]
  row.fetch("submeanings", []).each { |subrow| apply_genre_tags_to_row!(subrow) }
end

def apply_genre_tags!(meanings)
  meanings.each { |row| apply_genre_tags_to_row!(row) }
  meanings
end

def apply_meaning_translation_to_row!(row, char, translations, require_translations:)
  if row["meanings"].is_a?(Array)
    row["meanings"].each do |child|
      apply_meaning_translation_to_row!(child, char, translations, require_translations: require_translations)
    end
    return
  end

  if row["meaning"]
    original = row["meaning"]
    translated = translation_for(translations, char, original)
    if translated.to_s.strip.empty?
      message = "Missing Korean translation for #{char}: #{original}"
      raise message if require_translations

      warn message
    else
      row["meaning"] = translated.to_s.strip
    end
  end

  row.fetch("submeanings", []).each do |subrow|
    apply_meaning_translation_to_row!(subrow, char, translations, require_translations: require_translations)
  end
end

def apply_meaning_translations!(meanings, char, translations, require_translations:)
  return meanings if translations.empty? && !require_translations

  meanings.each do |row|
    apply_meaning_translation_to_row!(row, char, translations, require_translations: require_translations)
  end

  apply_genre_tags!(meanings)
  meanings
end

def extract_kanjipedia_detail(char, base_url:, url_cache:, translations:, require_translations:)
  url = resolve_kanjipedia_url(char, base_url, url_cache)
  doc = fetch_html(url)
  page_char = strip_variation_selectors(clean_node_text(doc.at_css("#kanjiOyaji") || doc.at_css("title")))
  expected_char = strip_variation_selectors(char)
  raise "Kanjipedia page mismatch for #{char}: got #{page_char} at #{url}" unless page_char.include?(expected_char)

  meanings = extract_kanjipedia_meanings(doc)
  apply_meaning_translations!(meanings, char, translations, require_translations: require_translations)
  readings = extract_kanjipedia_readings(doc)

  {
    "source_url" => url,
    "meanings" => meanings,
    "onyomi" => readings["onyomi"],
    "kunyomi" => readings["kunyomi"]
  }
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

def scrape_kanjipedia_word_candidates(char, base_url)
  first_url = kanjipedia_word_search_url(base_url, char)
  first_doc = fetch_html(first_url)
  page_urls = kanjipedia_word_search_page_urls(first_doc, first_url, base_url)
  page_urls.each_with_object([]) do |url, candidates|
    doc = url == first_url ? first_doc : fetch_html(url)
    doc.css("#resultKotobaList a[href^='/kotoba/']").each do |link|
      raw_label = clean_node_text(link)
      href = link["href"].to_s
      word = raw_label.sub(/[（(][^）)]*[）)]\z/, "").strip
      reading = raw_label[/[（(]([^）)]*)[）)]\z/, 1].to_s
      next if word.empty?

      candidates << WordCandidate.new(
        word: clean_word_text(word),
        reading: normalize_word_reading(reading),
        url: URI.join(base_url, href).to_s,
        raw_label: raw_label,
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

def kunyomi_surfaces(detail)
  detail.fetch("kunyomi", []).filter_map do |item|
    reading = item["reading"].to_s
    next if reading.empty?

    normalize_word_reading(reading)
  end.uniq
end

def kunyomi_word_target(char, reading)
  raw = reading.to_s.strip
  return nil if raw.empty?

  normalized = normalize_word_reading(raw)
  word = if raw.include?("-")
           stem, suffix = raw.split("-", 2)
           joiner = stem.include?("…") ? "…" : ""
           "#{char}#{joiner}#{suffix}"
         else
           char
         end
  RequiredWordTarget.new(
    word: clean_word_text(word),
    reading: normalized,
    reason: "kunyomi",
    jukujikun: false
  )
end

def required_word_targets(detail)
  char = strip_variation_selectors(detail["char"])
  targets = []

  extract_meaning_examples(detail.fetch("meanings", [])).each do |word|
    cleaned = clean_word_text(word)
    next if cleaned.empty?

    targets << RequiredWordTarget.new(
      word: cleaned,
      reading: "",
      reason: "meaning-example",
      jukujikun: false
    )
  end

  detail.fetch("kunyomi", []).each do |item|
    target = kunyomi_word_target(char, item["reading"])
    targets << target if target && !target.word.empty?
  end

  targets.uniq { |target| [target.word, target.reading] }
end

def compound_yomi(word, reading, detail, jukujikun:)
  return "숙자훈" if jukujikun

  normalized_reading = normalize_word_reading(reading)
  detail.fetch("kunyomi", []).each do |item|
    raw = item["reading"].to_s
    surface = normalize_word_reading(raw)
    stem = raw.split("-", 2).first.to_s
    stem_surface = normalize_word_reading(stem)
    next if stem_surface.empty?

    return stem if !surface.empty? && normalized_reading.start_with?(surface)
    return stem if normalized_reading.start_with?(stem_surface)
    return stem if reading_contains_yomi?(reading, stem)
  end

  detail.fetch("onyomi", []).each do |item|
    yomi = item["reading"].to_s
    return yomi if !yomi.empty? && reading_contains_yomi?(reading, yomi)
  end

  ""
end

def ensure_compound_yomi!(row, detail, context:)
  row["yomi"] = compound_yomi(row["word"], row["reading"], detail, jukujikun: row["yomi"].to_s == "숙자훈") if row["yomi"].to_s.strip.empty?
  return row unless row["yomi"].to_s.strip.empty?

  raise "Missing compound yomi for #{detail["char"]} #{row["word"]}(#{row["reading"]}) while #{context}"
end

def fallback_unresolved_yomi(detail)
  onyomi = detail.fetch("onyomi", []).map { |item| item["reading"].to_s }.find { |reading| !reading.empty? }
  return onyomi if onyomi

  detail.fetch("kunyomi", []).map { |item| item["reading"].to_s.split("-", 2).first }.find { |reading| !reading.empty? }.to_s
end

def validate_compound_yomi!(detail)
  detail.fetch("compounds", []).each do |row|
    ensure_compound_yomi!(row, detail, context: "validating generated compounds")
  end
end

def kunyomi_compound_reading?(reading, detail)
  normalized = normalize_word_reading(reading)
  return false if normalized.empty?

  detail.fetch("kunyomi", []).any? do |item|
    surface = normalize_word_reading(item["reading"])
    !surface.empty? && normalized.start_with?(surface)
  end
end

def display_compound_reading(reading, word:, kunyomi: false, jukujikun: false)
  normalized = normalize_word_reading(reading)
  return "" if normalized.empty?

  if kunyomi || jukujikun || word.to_s.match?(/[ぁ-ゖ]/)
    katakana_to_hiragana(normalized)
  else
    hiragana_to_katakana(normalized)
  end
end

def select_word_candidates(candidates, detail, max_words:)
  examples = extract_meaning_examples(detail.fetch("meanings", [])).map { |word| clean_word_text(word) }
  kunyomi = kunyomi_surfaces(detail)
  char = strip_variation_selectors(detail["char"])
  selected = []

  add = lambda do |candidate|
    return if selected.any? { |row| row.url == candidate.url }
    return if proverb_or_idiom_candidate?(candidate)

    selected << candidate
  end

  candidates.each { |candidate| add.call(candidate) if examples.include?(candidate.word) }
  candidates.each { |candidate| add.call(candidate) if kunyomi.include?(candidate.reading) }
  candidates.each { |candidate| add.call(candidate) if candidate.jukujikun }
  candidates.each do |candidate|
    break if selected.length >= max_words
    next unless candidate.word.start_with?(char)
    next if candidate.word.length > 5
    next if compound_yomi(candidate.word, candidate.reading, detail, jukujikun: candidate.jukujikun).empty?

    add.call(candidate)
  end
  candidates.each do |candidate|
    break if selected.length >= max_words
    next unless candidate.word.include?(char)
    next if candidate.word.start_with?(char)
    next if candidate.word.length > 5
    next if kanji_only?(candidate.word) && candidate.word.length == 4
    next if compound_yomi(candidate.word, candidate.reading, detail, jukujikun: candidate.jukujikun).empty?

    add.call(candidate)
  end

  selected.first(max_words)
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

def compact_translation_source(text)
  text.to_s.gsub(/\s+/, "")
end

def translation_source_fingerprint(text)
  compact_translation_source(text).gsub(/[ぁ-ゖァ-ヺー]/, "")
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

def missing_word_translation_error?(error)
  error.message.start_with?("Missing Korean word translation")
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

def clean_word_gloss_text(text)
  cleaned = text.to_s.gsub(/\s+/, " ").strip
  cleaned = cleaned.gsub(/[（(]出典：[^）)]*[）)]/, "")
  cleaned = cleaned.gsub(/[［\[]出典[^］\]]*[］\]][^。]*。?/, "")
  cleaned = cleaned.gsub(/[［\[]例[^］\]]*[］\]][^。]*。?/, "")
  cleaned = cleaned.gsub(/「[^」]*―[^」]*」/, "")
  cleaned = cleaned.gsub(/「[^」]*[。！？][^」]*」/, "")
  cleaned = cleaned.gsub(/「[^」]*(?:です|ます|した|だった|である|になる|となる|がある|がいる)[^」]*」/, "")
  cleaned = cleaned.gsub(/「[^」]+」(?=\s*(?:#{CIRCLED_NUMBER_PATTERN}|\z))/, "")
  cleaned.gsub(/\s+/, " ").strip
end

def kotobank_dictionary_article(doc, key)
  article = doc.at_css("article.dictype.cf.#{key}")
  return article if article

  expected = {
    "nikkokuseisen" => "日本国語大辞典",
    "daijisen" => "デジタル大辞泉"
  }[key]
  return nil unless expected

  doc.css("article").find do |candidate|
    candidate.at_css("h2")&.text.to_s.include?(expected)
  end
end

def kotobank_reference_for_article(article)
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

  ""
end

def xpath_literal(value)
  text = value.to_s
  return "'#{text}'" unless text.include?("'")
  return "\"#{text}\"" unless text.include?('"')

  "concat(#{text.split("'").map { |part| "'#{part}'" }.join(%q{, "'", })})"
end

def kotobank_result_reading(label)
  label_text = label.to_s
  raw = if label_text.match?(/\A[ぁ-ゖァ-ヺー・･\s\-－‐‑‒–—―（(）)]+/)
          label_text[/\A[ぁ-ゖァ-ヺー・･\s\-－‐‑‒–—―（(）)]+/].to_s
        else
          label_text.split(/[】］]/, 2)[1].to_s[/[ぁ-ゖァ-ヺー・･\s\-－‐‑‒–—―（(）)]+/].to_s
        end
  normalize_kotobank_reading(raw)
end

def kotobank_article_matches_target?(article, word, reading)
  labels = article.css("h3, h4").map { |node| clean_node_text(node) }.reject(&:empty?)
  return false if labels.empty?

  normalized_reading = normalize_kotobank_reading(reading)
  labels.any? do |label|
    kotobank_result_matches_word?(label, word) &&
      (normalized_reading.empty? || kotobank_result_reading(label) == normalized_reading)
  end
end

def kotobank_preferred_article(doc, word: nil, reading: nil, url: nil)
  articles = doc.css("article.dictype")
  if word
    matched_articles = articles.select { |article| kotobank_article_matches_target?(article, word, reading) }
    articles = matched_articles unless matched_articles.empty?
  end

  SOURCE_REFERENCE_ORDER.each do |reference|
    article = articles.find { |candidate| kotobank_reference_for_article(candidate) == reference }
    return article if article
  end

  fragment = url.to_s.split("#", 2)[1]
  if fragment && !fragment.empty?
    marker = doc.at_xpath("//*[@id=#{xpath_literal(fragment)}]")
    article = marker&.ancestors&.find { |node| node.name == "article" && node["class"].to_s.include?("dictype") }
    return article if article && PROJECT_REFERENCES.include?(kotobank_reference_for_article(article))
  end

  articles.first
end

def kotobank_heading_reading(doc)
  text = clean_node_text(doc.at_css("h1"))
  text[/[（(]読み[）)](.+)\z/, 1].to_s.strip
end

def kotobank_heading_reading_matches?(heading, expected)
  normalized_expected = normalize_kotobank_reading(expected)
  return true if normalized_expected.empty?

  heading.to_s
         .gsub(/[［\[].*\z/, "")
         .split(/[・･,、／\/\s]+/)
         .map { |part| normalize_kotobank_reading(part) }
         .reject(&:empty?)
         .include?(normalized_expected)
end

def validate_kotobank_kunyomi_heading!(target, detail, heading)
  return unless target.reason == "kunyomi"
  return if target.reading.to_s.empty?
  return if heading.to_s.empty?

  return if kotobank_heading_reading_matches?(heading, target.reading)

  raise "Kotobank fallback heading reading mismatch for #{target.word}: #{heading} != #{target.reading}"
end

def normalize_kotobank_result_label(text)
  text.to_s
      .gsub(/[[:space:]・\/／〔〕【】「」▽△]/, "")
      .gsub(/[（(]([^）)]*)[）)]/, '\1')
      .strip
end

def kotobank_result_spellings(label)
  bracket = label.to_s[/[【［]([^】］]+)[】］]/, 1].to_s
  return [] if bracket.empty?

  bracket.split(/[／\/・･]/).map do |part|
    clean_word_text(part)
  end.reject(&:empty?)
end

def kotobank_result_matches_word?(label, word)
  normalized_word = clean_word_text(word)
  spellings = kotobank_result_spellings(label)
  return true if spellings.include?(normalized_word)

  kanji = normalized_word.scan(/\p{Han}/)
  kana_suffix = normalized_word.sub(/\A\p{Han}+/, "")
  kanji.length == 1 && !kana_suffix.empty? && spellings.include?(kanji.first)
end

def kotobank_result_reading_matches?(label, expected)
  normalized_expected = normalize_kotobank_reading(expected)
  return true if normalized_expected.empty?

  kotobank_result_reading(label) == normalized_expected
end

def kotobank_result_matches_target?(label, word, expected_reading)
  return kotobank_result_matches_word?(label, word) if expected_reading.to_s.empty?
  return false unless kotobank_result_reading_matches?(label, expected_reading)

  return true if kotobank_result_matches_word?(label, word)

  false
end

def resolve_kotobank_word_url(base_url, word, expected_reading: "")
  search_doc = fetch_html(kotobank_word_search_url(base_url, word))
  link = search_doc.css('a[href^="/word/"]').find do |candidate|
    kotobank_result_matches_target?(clean_node_text(candidate), word, expected_reading)
  end
  return nil unless link

  URI.join(base_url, link["href"].to_s).to_s
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

def extract_kotobank_word_detail(target, detail, base_url:, translations:, require_translations:)
  direct_url = kotobank_word_url(base_url, target.word)
  doc = begin
    fetch_html(direct_url)
  rescue OpenURI::HTTPError
    resolved_url = resolve_kotobank_word_url(base_url, target.word, expected_reading: target.reading)
    raise unless resolved_url

    fetch_html(resolved_url)
  end
  article = kotobank_preferred_article(doc, word: target.word, reading: target.reading, url: direct_url)
  raise "No Kotobank fallback dictionary entry for #{target.word}" unless article

  gloss_ja = clean_kotobank_gloss(clean_node_text(article.at_css("section.description")), target.word)
  raise "No Kotobank fallback gloss for #{target.word}" if gloss_ja.empty?

  heading_reading = kotobank_heading_reading(doc)
  if target.reason == "kunyomi" && !kotobank_heading_reading_matches?(heading_reading, target.reading)
    resolved_url = resolve_kotobank_word_url(base_url, target.word, expected_reading: target.reading)
    if resolved_url && resolved_url != direct_url
      doc = fetch_html(resolved_url)
      article = kotobank_preferred_article(doc, word: target.word, reading: target.reading, url: resolved_url)
      raise "No Kotobank fallback dictionary entry for #{target.word}" unless article

      gloss_ja = clean_kotobank_gloss(clean_node_text(article.at_css("section.description")), target.word)
      raise "No Kotobank fallback gloss for #{target.word}" if gloss_ja.empty?
      heading_reading = kotobank_heading_reading(doc)
    end
  end
  validate_kotobank_kunyomi_heading!(target, detail, heading_reading)
  reading = target.reading.to_s.empty? ? normalize_kotobank_reading(heading_reading) : target.reading
  reading = katakana_to_hiragana(reading) if target.reason == "kunyomi" || target.word.match?(/[ぁ-ゖ]/)
  gloss = word_translation_for(translations, detail["char"], target.word, gloss_ja)
  if gloss.to_s.strip.empty?
    message = "Missing Korean word translation for #{detail["char"]} #{target.word}: #{gloss_ja}"
    raise message if require_translations

    warn message if !translations.empty? || require_translations
    gloss = gloss_ja
  end

  gloss = add_word_genre_tags(gloss.to_s.strip)
  display_reading = display_compound_reading(
    reading,
    word: target.word,
    kunyomi: target.reason == "kunyomi" || kunyomi_compound_reading?(reading, detail),
    jukujikun: target.jukujikun
  )
  row = {
    "word" => target.word,
    "reading" => display_reading,
    "gloss" => gloss,
    "yomi" => compound_yomi(target.word, display_reading, detail, jukujikun: target.jukujikun)
  }
  reference = kotobank_reference_for_article(article)
  row["reference"] = reference unless reference.empty?
  ensure_compound_yomi!(row, detail, context: "extracting Kotobank word detail")
end

def extract_kanjipedia_word_detail(candidate, detail, translations:, require_translations:)
  doc = fetch_html(candidate.url)
  word = clean_word_text(clean_node_text(doc.at_css("#kotobaArea p")))
  word = candidate.word if word.empty?
  reading = normalize_word_reading(clean_node_text(doc.at_css("#kotobaArea .kotobaYomi")))
  reading = candidate.reading if reading.empty?
  gloss_node = doc.at_css("#kotobaExplanationSection > p:not(.hyouki):not(.sankou)")
  replacement = extract_word_replace(doc)
  gloss_ja = kanjipedia_meaning_text(gloss_node)
  gloss_ja = text_before_any_marker_image(gloss_node, %w[季 書きかえ]) if gloss_node&.css("img")&.any? { |img| %w[季 書きかえ].include?(img["alt"].to_s) }
  gloss_ja = clean_word_gloss_text(gloss_ja)
  gloss = word_translation_for(translations, detail["char"], word, gloss_ja)
  if gloss.to_s.strip.empty?
    message = "Missing Korean word translation for #{detail["char"]} #{word}: #{gloss_ja}"
    raise message if require_translations

    warn message if !translations.empty? || require_translations
    gloss = gloss_ja
  end

  gloss = add_word_genre_tags(gloss.to_s.strip)
  display_reading = display_compound_reading(
    reading,
    word: word,
    kunyomi: candidate.word.match?(/[ぁ-ゖ]/) || kunyomi_compound_reading?(reading, detail),
    jukujikun: candidate.jukujikun
  )
  row = {
    "word" => word,
    "reading" => display_reading,
    "gloss" => gloss,
    "yomi" => compound_yomi(word, display_reading, detail, jukujikun: candidate.jukujikun)
  }
  variation = extract_word_variation(doc)
  row["variation"] = variation unless variation.empty?
  row["replace"] = replacement unless replacement.empty?
  ensure_compound_yomi!(row, detail, context: "extracting Kanjipedia word detail")
end

def required_target_present?(rows, target)
  rows.any? do |row|
    next false unless clean_word_text(row["word"]) == target.word
    next true if target.reading.to_s.empty?

    normalize_word_reading(row["reading"]) == target.reading
  end
end

def unresolved_source_error?(error)
  return false if missing_word_translation_error?(error)
  return true if error.is_a?(OpenURI::HTTPError) && error.message.include?("404")

  error.message.start_with?("No Kotobank fallback dictionary entry") ||
    error.message.start_with?("No Kotobank fallback gloss") ||
    error.message.start_with?("Kotobank fallback heading reading mismatch")
end

def unresolved_required_word_row(target, detail)
  reading = display_compound_reading(
    target.reading,
    word: target.word,
    kunyomi: target.reason == "kunyomi" || kunyomi_compound_reading?(target.reading, detail),
    jukujikun: target.jukujikun
  )
  yomi = compound_yomi(target.word, reading, detail, jukujikun: target.jukujikun)
  if reading.empty?
    reading = UNRESOLVED_WORD_READING
    yomi = fallback_unresolved_yomi(detail)
  end
  row = {
    "word" => target.word,
    "reading" => reading,
    "gloss" => UNRESOLVED_WORD_GLOSS,
    "yomi" => yomi
  }
  ensure_compound_yomi!(row, detail, context: "creating unresolved word placeholder")
end

def append_kotobank_fallback_words!(rows, detail, targets, base_url:, translations:, require_translations:)
  targets.each do |target|
    next if required_target_present?(rows, target)

    begin
      row = extract_kotobank_word_detail(
        target,
        detail,
        base_url: base_url,
        translations: translations,
        require_translations: require_translations
      )
      rows << row
    rescue StandardError => e
      raise if require_translations && missing_word_translation_error?(e)

      warn "  Kotobank #{target.word}: #{e.class}: #{e.message}"
      unless unresolved_source_error?(e)
        warn "  #{target.word}: unresolved placeholder skipped because the failure was not a source miss."
        next
      end

      placeholder = unresolved_required_word_row(target, detail)
      rows << placeholder
      warn "  #{target.word}: added #{UNRESOLVED_WORD_GLOSS}"
    end
  end
  rows
end

def extract_kanjipedia_words(detail, base_url:, translations:, require_translations:, max_words:, kotobank_base_url: nil)
  candidates = scrape_kanjipedia_word_candidates(detail["char"], base_url)
  selected = select_word_candidates(candidates, detail, max_words: max_words)
  rows = selected.filter_map do |candidate|
    extract_kanjipedia_word_detail(
      candidate,
      detail,
      translations: translations,
      require_translations: require_translations
    )
  rescue StandardError => e
    raise if require_translations && missing_word_translation_error?(e)

    warn "  #{candidate.url}: #{e.class}: #{e.message}"
    nil
  end
  append_kotobank_fallback_words!(
    rows,
    detail,
    required_word_targets(detail),
    base_url: kotobank_base_url,
    translations: translations,
    require_translations: require_translations
  ) if kotobank_base_url
  rows
end

def merge_readings!(target, key, additions)
  additions.each do |item|
    item = item.dup
    item["type"] = "" unless target["_joyo"]
    existing = target[key].find { |row| row["reading"] == item["reading"] }
    if existing
      existing["type"] = "상용" if target["_joyo"] && existing["type"].to_s.empty? && item["type"] == "상용"
      next
    end

    target[key] << item
  end
end

def enrich_with_kanjipedia!(detail, kanjipedia)
  merge_readings!(detail, "onyomi", kanjipedia["onyomi"])
  merge_readings!(detail, "kunyomi", kanjipedia["kunyomi"])
  detail["meanings"] = kanjipedia["meanings"] unless kanjipedia["meanings"].empty?
  detail
end

def extract_radical(td)
  candidates = td.css("a").filter_map do |link|
    text = clean_node_text(link)
    next unless text.end_with?("部")

    text.sub(/部\z/, "")
  end
  return candidates.last unless candidates.empty?

  text = clean_node_text(td)
  text.split(/[（(]/).first.to_s.sub(/部\z/, "").strip
end

def extract_kanji_detail(url, fallback_char:, grade:)
  doc = fetch_html(url)
  h1_text = clean_node_text(doc.at_css("h1") || doc.at_css("title"))
  char = h1_text[/「(.+?)」/, 1] || fallback_char

  detail = {
    "title" => char,
    "char" => char,
    "unicode" => kanji_unicode(char),
    "meanings" => [],
    "onyomi" => [],
    "kunyomi" => [],
    "radical" => "",
    "strokes" => nil,
    "kanken" => grade&.label.to_s,
    "jis" => "",
    "variants" => nil,
    "compounds" => [],
    "_joyo" => false
  }

  current_heading = nil
  doc.css("table tr").each do |tr|
    th = tr.at_css("th")
    td = tr.at_css("td")
    next unless td

    current_heading = clean_heading(th) if th

    case current_heading
    when /部首/
      detail["radical"] = extract_radical(td)
    when /画数/
      detail["strokes"] = normalize_digits(clean_node_text(td))[/(\d+)\s*画/, 1]&.to_i
    when /音読み/
      detail["onyomi"] << { "reading" => extract_reading(td, :onyomi), "type" => reading_type(td) }
    when /訓読み/
      detail["kunyomi"] << { "reading" => extract_reading(td, :kunyomi), "type" => reading_type(td) }
    when /漢字検定/
      detail["kanken"] = normalize_digits(clean_node_text(td)).gsub(/\s+/, "")
    when /JIS水準/
      detail["jis"] = normalize_digits(clean_node_text(td)).gsub(/\s+/, "")
    when /種別/
      detail["_joyo"] = clean_node_text(td).include?("常用")
    end
  end

  detail["onyomi"].reject! { |item| item["reading"].empty? }
  detail["kunyomi"].reject! { |item| item["reading"].empty? }
  unless detail["_joyo"]
    detail["onyomi"].each { |item| item["type"] = "" }
    detail["kunyomi"].each { |item| item["type"] = "" }
  end
  detail
end

def yaml_scalar(value)
  return "" if value.nil?

  value.to_s
end

def json_quote(value)
  JSON.generate(value.to_s)
end

def inline_reading(item)
  "{ reading: #{yaml_scalar(item["reading"])}, type: \"#{yaml_scalar(item["type"])}\" }"
end

def inline_meaning(item)
  fields = []
  fields << "reading: #{json_quote(item["reading"])}" unless item["reading"].to_s.empty?
  fields << "meaning: #{json_quote(item["meaning"])}"
  fields << "example: #{json_quote(item["example"])}" unless item["example"].to_s.empty?
  "{ #{fields.join(", ")} }"
end

def inline_compound(item)
  fields = []
  %w[word reading gloss yomi variation replace reference].each do |key|
    next if item[key].to_s.empty?

    fields << "#{key}: #{json_quote(item[key])}"
  end
  "{ #{fields.join(", ")} }"
end

def append_meaning_item_lines(lines, item, indent)
  if item["submeanings"].is_a?(Array) && !item["submeanings"].empty?
    fields = []
    fields << "reading: #{json_quote(item["reading"])}" unless item["reading"].to_s.empty?
    fields << "meaning: #{json_quote(item["meaning"])}"
    lines << "#{indent}- #{fields.join(", ")}"
    lines << "#{indent}  submeanings:"
    item["submeanings"].each { |subitem| lines << "#{indent}    - #{inline_meaning(subitem)}" }
  else
    lines << "#{indent}- #{inline_meaning(item)}"
  end
end

def append_meaning_lines(lines, item)
  if item["meanings"].is_a?(Array) && !item["meanings"].empty?
    lines << "  - reading: #{json_quote(item["reading"])}"
    lines << "    meanings:"
    item["meanings"].each { |child| append_meaning_item_lines(lines, child, "      ") }
  elsif item["submeanings"].is_a?(Array) && !item["submeanings"].empty?
    append_meaning_item_lines(lines, item, "  ")
  else
    lines << "  - #{inline_meaning(item)}"
  end
end

def stage_markdown(data)
  lines = []
  lines << "---"
  lines << "title: #{yaml_scalar(data["title"])}"
  lines << "char: #{yaml_scalar(data["char"])}"
  lines << "unicode: #{yaml_scalar(data["unicode"])}"
  if data["meanings"].empty?
    lines << "meanings: []"
  else
    lines << "meanings:"
    data["meanings"].each { |item| append_meaning_lines(lines, item) }
  end
  if data["onyomi"].empty?
    lines << "onyomi: []"
  else
    lines << "onyomi:"
    data["onyomi"].each { |item| lines << "  - #{inline_reading(item)}" }
  end
  if data["kunyomi"].empty?
    lines << "kunyomi: []"
  else
    lines << "kunyomi:"
    data["kunyomi"].each { |item| lines << "  - #{inline_reading(item)}" }
  end
  lines << "radical: #{yaml_scalar(data["radical"])}"
  lines << "strokes: #{yaml_scalar(data["strokes"])}"
  lines << "kanken: #{yaml_scalar(data["kanken"])}"
  lines << "jis: #{yaml_scalar(data["jis"])}"
  lines << "variants:"
  if data["compounds"].empty?
    lines << "compounds: []"
  else
    lines << "compounds:"
    data["compounds"].each { |item| lines << "  - #{inline_compound(item)}" }
  end
  lines << "---"
  lines << ""
  lines.join("\n")
end

def validate_stage_data!(data)
  required = %w[title char unicode radical strokes kanken jis]
  missing = required.select { |key| data[key].to_s.strip.empty? }
  raise "Missing required fields for #{data["char"]}: #{missing.join(", ")}" unless missing.empty?

  expected = kanji_unicode(data["char"])
  raise "Unicode mismatch for #{data["char"]}: expected #{expected}, got #{data["unicode"]}" if expected != data["unicode"]
end

def write_stage_file(data, stage_dir)
  validate_stage_data!(data)
  code = data["unicode"].sub(/\AU\+/, "")
  path = File.join(stage_dir, "#{code}.md")
  FileUtils.mkdir_p(stage_dir)
  File.write(path, stage_markdown(data), encoding: "UTF-8")
  path.tr("\\", "/")
end

def scrape_grade_list(url, base_url)
  doc = fetch_html(url)
  expected = doc.at_css("#kanji_list_count")&.[]("data-total")&.to_i ||
             doc.at_css("#kanji_list_count")&.text&.tr("０-９", "0-9")&.to_i

  entries = doc.css(".kanji_bushu_list a").filter_map do |link|
    char = link.at_css(".big")&.text&.strip
    next if char.nil? || char.empty?

    href = link["href"]
    readings = link.css(".yomi").map { |node| node.text.strip }.reject(&:empty?)
    ListEntry.new(
      char: char,
      unicode: kanji_unicode(char),
      url: URI.join(base_url, href).to_s,
      readings: readings
    )
  end

  duplicates = entries.group_by(&:unicode).select { |_unicode, rows| rows.length > 1 }
  raise "No kanji list entries found at #{url}" if entries.empty?
  raise "Duplicate kanji entries found: #{duplicates.keys.join(", ")}" unless duplicates.empty?

  [entries, expected]
end

def jitenon_detail_char(doc)
  h1_text = clean_node_text(doc.at_css("h1") || doc.at_css("title"))
  h1_text[/漢字「(.+?)」/, 1] || h1_text[/「(.+?)」/, 1]
end

def jitenon_detail_url(doc, fallback_url)
  canonical = doc.at_css('link[rel="canonical"]')&.[]("href").to_s.strip
  canonical.empty? ? fallback_url : canonical
end

def jitenon_search_candidate_links(doc)
  links = doc.css("#search_result .data_cont a").select do |link|
    href = link["href"].to_s
    href.match?(%r{/kanji[a-z]?/})
  end
  links = doc.css("a").select { |link| link["href"].to_s.match?(%r{/kanji[a-z]?/}) } if links.empty?
  links
end

def resolve_jitenon_search_entry(query, base_url)
  search_url = post_jitenon_search_url(query, base_url)
  doc = fetch_html(search_url)
  target_code = unicode_code_query(query)
  target_unicode = target_code ? "U+#{target_code}" : nil
  target_char = target_code ? [target_code.to_i(16)].pack("U") : strip_variation_selectors(query).strip

  direct_char = jitenon_detail_char(doc)
  if direct_char && strip_variation_selectors(direct_char) == strip_variation_selectors(target_char)
    url = jitenon_detail_url(doc, search_url)
    return [ListEntry.new(char: direct_char, unicode: kanji_unicode(direct_char), url: url, readings: []), search_url]
  end

  candidates = jitenon_search_candidate_links(doc).filter_map do |link|
    char = link.at_css("span")&.text&.strip
    char ||= clean_node_text(link)[/\p{Han}/]
    next if char.to_s.empty?

    unicode = kanji_unicode(char)
    next if target_unicode && unicode != target_unicode
    next if !target_unicode && strip_variation_selectors(char) != strip_variation_selectors(target_char)

    ListEntry.new(
      char: char,
      unicode: unicode,
      url: URI.join(base_url, link["href"].to_s).to_s,
      readings: []
    )
  end

  candidates.uniq!(&:unicode)
  raise "No exact Jitenon search result found for #{query.inspect} at #{search_url}" if candidates.empty?
  raise "Multiple exact Jitenon search results found for #{query.inspect}: #{candidates.map(&:url).join(", ")}" if candidates.length > 1

  [candidates.first, search_url]
end

def front_matter(path)
  text = File.read(path, encoding: "UTF-8")
  match = text.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
  return {} unless match

  YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: true) || {}
rescue Psych::SyntaxError => e
  warn "YAML parse failed for #{path}: #{e.message}"
  {}
end

def load_collection(dir)
  return {} unless Dir.exist?(dir)

  Dir[File.join(dir, "*.md")].each_with_object({}) do |path, by_unicode|
    data = front_matter(path)
    unicode = data["unicode"].to_s.strip
    next if unicode.empty?

    by_unicode[unicode] = {
      path: path.tr("\\", "/"),
      char: data["char"],
      title: data["title"],
      kanken: data["kanken"]
    }

    filename_code = File.basename(path, ".md").upcase
    metadata_code = unicode.sub(/\AU\+/i, "").upcase
    warn "Unicode mismatch: #{path} filename=#{filename_code} metadata=#{metadata_code}" if filename_code != metadata_code
  end
end

def status_for(entry, completed, staged)
  return "completed" if completed.key?(entry.unicode)
  return "staged" if staged.key?(entry.unicode)

  "missing"
end

def printable_rows(rows, mode)
  return rows if mode == "all"

  rows.select { |row| row[:status] == mode }
end

def print_report(grade, source_url, expected, rows, mode)
  counts = rows.group_by { |row| row[:status] }.transform_values(&:length)
  puts "Grade: #{grade&.label || "Jitenon search"}"
  puts "Source: #{source_url}"
  puts "Listed: #{rows.length}#{expected ? " / expected #{expected}" : ""}"
  puts "Completed: #{counts.fetch("completed", 0)}"
  puts "Staged: #{counts.fetch("staged", 0)}"
  puts "Missing: #{counts.fetch("missing", 0)}"

  visible = printable_rows(rows, mode)
  return if visible.empty?

  puts
  puts format("%-8s %-4s %-9s %-45s %s", "STATUS", "KANJI", "UNICODE", "PATH", "SOURCE")
  visible.each do |row|
    puts format(
      "%-8s %-4s %-9s %-45s %s",
      row[:status],
      row[:char],
      row[:unicode],
      row[:path] || "-",
      row[:url]
    )
  end
end

def real_stage_dir?(path)
  File.basename(path.to_s).start_with?("_kanji_")
end

def validate_snapshot_for_stage_write!(stage_dir, snapshot)
  return unless real_stage_dir?(stage_dir)

  abort "Refusing to write #{stage_dir}: pass --snapshot PATH created by tools/snapshot_kanji_stage.rb." if snapshot.to_s.empty?
  abort "Snapshot path does not exist: #{snapshot}" unless File.exist?(snapshot)
end

grade = options[:jitenon_search] ? nil : parse_grade(options[:grade])
options[:stage_dir] ||= options[:jitenon_search] ? "_kanji_single" : default_stage_dir(grade)
validate_snapshot_for_stage_write!(options[:stage_dir], options[:snapshot]) if options[:write_stage]
if options[:jitenon_search]
  entry, source_url = resolve_jitenon_search_entry(options[:jitenon_search], options[:base_url])
  entries = [entry]
  expected = 1
else
  source_url = grade.url(options[:base_url])
  entries, expected = scrape_grade_list(source_url, options[:base_url])
end
completed = load_collection(options[:final_dir])
staged = load_collection(options[:stage_dir])
kanjipedia_url_cache = load_json_cache(options[:kanjipedia_cache])
meaning_translations = load_meaning_translations(options[:meaning_translations])
word_translations = load_meaning_translations(options[:word_translations])

if options[:write_stage] && !options[:allow_untranslated]
  options[:require_meaning_translations] = true if options[:kanjipedia]
  options[:require_word_translations] = true if options[:kanjipedia_words]
end

rows = entries.map do |entry|
  status = status_for(entry, completed, staged)
  source = status == "completed" ? completed[entry.unicode] : staged[entry.unicode]
  {
    status: status,
    char: entry.char,
    unicode: entry.unicode,
    url: entry.url,
    readings: entry.readings,
    path: source&.fetch(:path, nil)
  }
end
if options[:unicode]
  target_unicode = normalize_unicode_filter(options[:unicode])
  rows = rows.select { |row| row[:unicode].casecmp?(target_unicode) }
end
if options[:char]
  rows = rows.select { |row| strip_variation_selectors(row[:char]) == strip_variation_selectors(options[:char]) }
end
abort "No matching kanji found for the requested --unicode/--char filter." if (options[:unicode] || options[:char]) && rows.empty?

if expected && expected != entries.length
  warn "Expected #{expected} entries from page metadata, but scraped #{entries.length}."
end

print_report(grade, source_url, expected, rows, options[:show])

if options[:write_stage]
  writable_statuses = case options[:write_stage]
                      when "missing" then Set["missing"]
                      when "staged" then Set["staged"]
                      when "all" then Set["missing", "staged"]
                      end

  targets = rows.select { |row| writable_statuses.include?(row[:status]) }
  targets = targets.first(options[:limit]) if options[:limit]

  puts
  puts "Writing #{targets.length} stage file(s) to #{options[:stage_dir]}..."
  failed = false
  targets.each_with_index do |row, index|
    print "[#{index + 1}/#{targets.length}] #{row[:char]} #{row[:unicode]} "
    detail = extract_kanji_detail(row[:url], fallback_char: row[:char], grade: grade)
    if options[:kanjipedia]
      kanjipedia = extract_kanjipedia_detail(
        row[:char],
        base_url: options[:kanjipedia_base_url],
        url_cache: kanjipedia_url_cache,
        translations: meaning_translations,
        require_translations: options[:require_meaning_translations]
      )
      enrich_with_kanjipedia!(detail, kanjipedia)
    end
    if options[:kanjipedia_words]
      detail["compounds"] = extract_kanjipedia_words(
        detail,
        base_url: options[:kanjipedia_base_url],
        translations: word_translations,
        require_translations: options[:require_word_translations],
        max_words: options[:max_words],
        kotobank_base_url: options[:kotobank_fallback] ? options[:kotobank_base_url] : nil
      )
    end
    validate_compound_yomi!(detail)
    path = write_stage_file(detail, options[:stage_dir])
    puts "-> #{path}"
    sleep options[:sleep] if index + 1 < targets.length && options[:sleep].positive?
  rescue StandardError => e
    failed = true
    puts "FAILED"
    warn "  #{row[:url]}: #{e.class}: #{e.message}"
  end

  write_json_cache(options[:kanjipedia_cache], kanjipedia_url_cache) if options[:kanjipedia]
  exit 1 if failed
end

if options[:json]
  report = {
    grade: grade&.label,
    jitenon_search: options[:jitenon_search],
    source_url: source_url,
    expected_count: expected,
    scraped_count: entries.length,
    counts: rows.group_by { |row| row[:status] }.transform_values(&:length),
    rows: rows
  }
  File.write(options[:json], JSON.pretty_generate(report), encoding: "UTF-8")
  puts
  puts "Wrote #{options[:json]}"
end
