# bundle exec ruby scrape_kanken_9.rb

require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'yaml'

# 타겟 디렉토리
TARGET_DIR = "_kanji_8"
FileUtils.mkdir_p(TARGET_DIR)

# 목록 페이지 URL
LIST_URL = "https://kanji.jitenon.jp/cat/kyu08"
BASE_URL = "https://kanji.jitenon.jp"

def fetch_page(url)
  Nokogiri::HTML(URI.open(url))
rescue => e
  puts "Error fetching #{url}: #{e.message}"
  nil
end

def extract_kanji_data(url)
  doc = fetch_page(url)
  return nil unless doc

  # 1. 기본 정보 추출
  h1_text = doc.at_css('h1')&.text&.strip
  match = h1_text.match(/「(.+)」/)
  char = match ? match[1] : nil
  
  unless char
    puts "  Failed to extract char from h1: #{h1_text}"
    return nil
  end

  unicode = "U+#{char.ord.to_s(16).upcase}"

  # 2. 테이블 데이터 추출
  onyomi = []
  kunyomi = []
  
  radical = ""
  strokes = ""
  kanken = "9級"
  jis = ""

  current_th = nil

  doc.css('table.kanjirighttb tr').each do |tr|
    th_node = tr.at_css('th')
    td_node = tr.at_css('td')
    
    if th_node
      th_node.search('rt').remove
      current_th = th_node.text.strip
    end

    next unless td_node && current_th

    td_node.search('rt').remove
    td_text = td_node.text.strip

    case current_th
    when "部首"
      raw_radical = td_text.split('（').first.strip
      radical = raw_radical.split('・').first.sub(/部$/, '').strip
    when "画数"
      normalized_strokes = td_text.tr('０-９', '0-9')
      strokes = normalized_strokes.to_i
    when "音読み"
      onyomi.concat(extract_readings(td_node, false))
    when "訓読み"
      kunyomi.concat(extract_readings(td_node, true))
    when "漢字検定"
      kanken = td_text.tr('０-９', '0-9')
    when "JIS水準"
      jis = td_text.tr('０-９', '0-9')
    end
  end

  # 2.5 훈독을 활용한 숙어(compounds) 생성 (요청사항 2)
  compounds_entries = []
  unless kunyomi.empty?
    kunyomi.each do |k|
      r_str = k['reading']
      if r_str.include?('-')
        yomi_part, okuri_part = r_str.split('-', 2)
      else
        yomi_part = r_str
        okuri_part = ""
      end
      
      # word: 한자 + 오쿠리가나 (따옴표 없음)
      # reading: 전체 읽기 (따옴표 없음)
      # gloss: "" (따옴표 있음)
      # yomi: 한자 부분 읽기 (따옴표 있음)
      compounds_entries << "  - { word: #{char}#{okuri_part}, reading: #{yomi_part}#{okuri_part}, gloss: \"\", yomi: \"#{yomi_part}\" }"
    end
  end

  # 3. 데이터 구조화 (YAML 수동 포맷팅)
  yaml_content = <<~YAML
---
title: #{char}
char: #{char}
unicode: #{unicode}
meanings:
  - { meaning: "", example : "" }
onyomi:
YAML

  # 음독 출력
  if onyomi.empty?
    yaml_content += " []\n"
  else
    onyomi.each do |y|
      line = "  - { reading: #{y['reading']}"
      line += ", type: \"#{y['type']}\"" if y['type']
      line += " }\n"
      yaml_content += line
    end
  end

  # 훈독 출력
  yaml_content += "kunyomi:\n"
  if kunyomi.empty?
    yaml_content += " []\n"
  else
    kunyomi.each do |y|
      line = "  - { reading: #{y['reading']}"
      line += ", type: \"#{y['type']}\"" if y['type']
      line += " }\n"
      yaml_content += line
    end
  end

  yaml_content += <<~YAML
radical: #{radical}
strokes: #{strokes}
kanken: #{kanken}
jis: #{jis}
variants:
compounds:
YAML

  # 숙어(compounds) 출력
  if compounds_entries.empty?
    yaml_content += "\n"
  else
    yaml_content += compounds_entries.join("\n") + "\n"
  end

  yaml_content += "---\n"
  return yaml_content
end

def extract_readings(td_node, is_kunyomi)
  readings = []
  current_type = nil

  td_node.children.each do |child|
    if child.name == 'span' && child['class']&.include?('yomi_icon')
      img = child.at_css('img')
      if img && img['src'] =~ /yomi_icon[1-3]\.svg/
        current_type = "상용"
      elsif img && img['src'] =~ /yomi_icon4\.svg/
        current_type = nil
      end
    elsif child.name == 'img' && child['src'] =~ /yomi_icon[1-3]\.svg/
      current_type = "상용"
    elsif child.text? || child.name == 'a'
      text = child.text.strip
      next if text.empty? || text == '・'

      parts = text.split('・')
      parts.each do |part|
        part = part.strip
        next if part.empty?

        if is_kunyomi
          # 훈독 포맷팅: ま（ざる） -> ま-ざる
          part = part.sub(/（(.+)）/, '-\1')
        end

        reading_data = { "reading" => part }
        reading_data["type"] = current_type if current_type
        readings << reading_data
      end
      
      current_type = nil
    end
  end
  
  readings
end

# 메인 로직
puts "Fetching list from #{LIST_URL}..."
list_doc = fetch_page(LIST_URL)

unless list_doc
  puts "Failed to fetch list page."
  exit 1
end

links = list_doc.css('.search_parts li a').map { |a| a['href'] }
            .select { |href| href =~ %r{/kanji/\d+} }
            .map { |href| URI.join(BASE_URL, href).to_s }
            .uniq

puts "Found #{links.size} kanji links."

links.each_with_index do |url, index|
  puts "[#{index + 1}/#{links.size}] Processing #{url}..."
  
  yaml_content = extract_kanji_data(url)
  
  if yaml_content
    unicode_match = yaml_content.match(/unicode: (U\+[0-9A-F]+)/)
    if unicode_match
      unicode = unicode_match[1].sub('U+', '')
      filename = File.join(TARGET_DIR, "#{unicode}.md")
      
      File.open(filename, 'w') do |f|
        f.write(yaml_content)
      end
      puts "  Saved to #{filename}"
    else
      puts "  Failed to extract unicode from generated YAML."
    end
  else
    puts "  Failed to extract data."
  end
  
  sleep 1 
  break
end