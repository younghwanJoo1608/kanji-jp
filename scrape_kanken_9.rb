# bundle exec ruby scrape_kanken_9.rb

require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'yaml'
require 'cgi'

# 타겟 디렉토리
TARGET_DIR = "_kanji_8"
FileUtils.mkdir_p(TARGET_DIR)

# 사이트 URL 설정
LIST_URL = "https://kanji.jitenon.jp/cat/kyu08"
BASE_URL = "https://kanji.jitenon.jp"
KANJIPEDIA_URL = "https://www.kanjipedia.jp/"

def fetch_page(url)
  # 브라우저처럼 보이게 하여 403 에러 방지
  user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  Nokogiri::HTML(URI.open(url, "User-Agent" => user_agent))
rescue => e
  puts "  [Log Error] Fetching #{url}: #{e.message}"
  nil
end

# --- [로그 추가] Kanjipedia 데이터 추출 함수 ---
def fetch_kanjipedia_data(char)
  # 1. 검색 페이지 접속 로직
  search_url = "#{KANJIPEDIA_URL}search?k=#{CGI.escape(char)}&kt=1&sk=leftHand"
  puts "  [Log] Kanjipedia 검색 시작: #{search_url}"

  doc = fetch_page(search_url)
  if doc.nil?
    puts "  [Log] 검색 페이지를 읽어오는 데 실패했습니다."
    return []
  end

  # 2. 결과 목록에서 상세 페이지 링크 추출
  first_link = doc.at_css('#resultKanjiList a')
  unless first_link
    puts "  [Log] 검색 결과 목록(#resultKanjiList)에서 링크를 찾을 수 없습니다."
    return []
  end

  detail_path = first_link['href']
  detail_url = URI.join(KANJIPEDIA_URL, detail_path).to_s
  puts "  [Log] 상세 페이지 링크 발견: #{detail_url}"

  # 3. 상세 페이지 접속 및 내용 추출
  detail_doc = fetch_page(detail_url)
  if detail_doc.nil?
    puts "  [Log] 상세 페이지를 읽어오는 데 실패했습니다."
    return []
  end

  right_section = detail_doc.at_css('#kanjiRightSection')
  unless right_section
    puts "  [Log] 상세 페이지에서 '#kanjiRightSection' 노드를 찾을 수 없습니다."
    return []
  end

  first_li = right_section.at_css('ul li')
  unless first_li
    puts "  [Log] kanjiRightSection 내에 li가 없습니다."
    return []
  end

  # 찾은 li 내부의 div > p 내용을 파싱
  # 구조: <p> <img icon1> "Reading ①…" <img icon2> "Reading2 ①…" </p>
  p_node = first_li.at_css('div p')
  # 구조가 li > p 일수도 있으므로 확인
  p_node ||= first_li.at_css('p')
  
  unless p_node
    puts "  [Log] 의미 텍스트가 담긴 p 태그를 찾을 수 없습니다."
    return []
  end

  meanings_result = []
  current_reading = nil
  expect_reading = false

  p_node.children.each do |node|
    if node.name == 'img'
       # 아이콘 체크 (예: /common/images/icon_one.png)
       # 아이콘이 나오면 다음 텍스트는 reading으로 시작됨을 의미
       if node['src'] =~ /icon_(one|two|three|four|five|chi|nm)/
         expect_reading = true
       end
    elsif node.text?
      text = node.text.gsub(/\s+/, ' ').strip
      next if text.empty?

      if expect_reading
        # reading과 본문 분리 (① 같은 숫자로 시작하는 부분 찾기)
        # 예: "ガ ①え。…" -> reading="ガ", body="①え。…"
        # 예: "ひのと。…" -> reading=nil, body="ひのと。…" (아이콘 없었으면 여기 안옴, 근데 아이콘 있었으면 무조건 reading 있다고 가정?)
        # 유저 예시: "icon… > カク ①…"
        
        match = text.match(/^([^①-⑳]+)(.*)/)
        if match
          current_reading = match[1].strip
          body = match[2].strip
        else
          # 숫자가 없는 경우 (드문 경우)
          current_reading = text
          body = ""
        end
        expect_reading = false
      else
        body = text
        # current_reading 유지 (한 아이콘 뒤에 텍스트 노드가 여러개일 리는 적지만 안전하게)
        # 하지만 보통 img -> text(full) 구조임. 
        # 아이콘 없이 시작하는 경우 current_reading = nil
      end

      # 본문 파싱 (①, ②… 로 분리)
      # 숫자가 맨 앞에 없을 수도 있음 (단일 의미일 때)
      # "①… ②…" 형태라면 split
      
      if body.match?(/[①-⑳]/)
        parts = body.split(/([①-⑳])/).drop(1) # 첫번째 빈 문자열 제거하거나, 매칭된 구분자와 쌍으로 나옴
        # split(/([pat])/): [pre, match, post, match, post…]
        # body="①A②B" -> ["", "①", "A", "②", "B"]
        
        # 쌍으로 순회
        parts.each_slice(2) do |num, content|
          next unless content
          meanings_result << parse_single_meaning(content.strip, current_reading)
        end
      else
        # 번호 없는 단일 의미
        unless body.empty?
          meanings_result << parse_single_meaning(body, current_reading)
        end
      end
    end
  end

  meanings_result
end

def parse_single_meaning(text, reading)
  # 1. 서브 의미 처리 ((ア), (イ)…)
  if text.match?(/\([アイウエオカキクケコ]\)/)
    # ⑤ちょう。(ア)書物の… (イ)…
    # 첫번째 파트(메인)와 서브 파트 분리
    sub_parts = text.split(/\(([アイウエオカキクケコ])\)/)
    # "⑤ちょう。" (아) "…" (이) "…"
    # index 0: 메인 의미 (또는 비어있음)
    # index 1: marker (ア), index 2: content…
    
    main_meaning_text = sub_parts.shift.strip
    
    data = extract_example(main_meaning_text)
    result = { "meaning" => data[:meaning] }
    result["example"] = data[:example] if data[:example]
    result["reading"] = reading if reading
    
    submeanings = []
    sub_parts.each_slice(2) do |marker, content|
      next unless content
      data_sub = extract_example(content.strip)
      sub_item = { "meaning" => data_sub[:meaning] }
      sub_item["example"] = data_sub[:example] if data_sub[:example]
      submeanings << sub_item
    end
    
    result["submeanings"] = submeanings unless submeanings.empty?
    return result
  else
    # 일반 처리
    data = extract_example(text)
    result = { "meaning" => data[:meaning] }
    result["example"] = data[:example] if data[:example]
    result["reading"] = reading if reading
    return result
  end
end

def extract_example(text)
  # "意味。「例」「例2」" -> meaning="意味。", example="例"
  # "意味。" -> meaning="意味。", example=nil
  # 낫표가 "맨 뒤"에 있어야 함 (다음 번호 직전, 즉 여기서는 문자열 끝)
  # "aaa「bbb」ccc" 형태면 ccc가 있으므로 예시가 아님 (설명 중간의 인용일 수 있음)
  # 유저 요건: "다음 번호가 나타나기 바로 직전에 낫표로 감싸진 단어" -> 여기선 이미 split 됐으므로 문자열 끝 확인
  
  match = text.match(/^(.*?)「([^」]+)」$/)
  if match
    # match[1]은 의미, match[2]는 예시(여러개일 수 있음)
    meaning = match[1].strip
    examples_str = match[2]
    # "例」「例2" 형태일 수 있음 (마지막 닫는 괄호는 regex에서 소비됨)
    # 하지만 regex는 greedy하므로 `(.*)`가 `「` 전까지 최대한 먹음.
    # 만약 "A「B」「C」" 라면?
    # last `」` is matched. `([^」]+)` matches `C`. 
    # `(.*?)` matches `A「B` ?? No.
    
    # 낫표 덩어리들을 추출해야 함.
    # 뒤에서부터 낫표 덩어리를 찾아서 제거?
    # 유저: "가장 처음에 등장하는 단어만 넣어 줘."
    # 예: "…「丁男」「壮丁」" -> …「丁男」…
    
    # 전략: 텍스트에서 낫표로 감싸진 부분들이 "뒤쪽에 몰려있는지" 확인
    # "意味 text 「Ex1」「Ex2」"
    
    # 1. 낫표 제거 전 의미 텍스트 확보
    # 뒤에 연속된 낫표 그룹 찾기
    
    cleaned_meaning = text.sub(/(「[^」]+」)+$/, '').strip
    
    # 2. 예시 추출
    # 제거된 부분에서 첫 번째 예시만 추출
    examples_part = text[cleaned_meaning.length..-1]
    first_example_match = examples_part.match(/「([^」]+)」/)
    
    example = first_example_match ? first_example_match[1] : nil
    
    return { meaning: cleaned_meaning, example: example }
  else
    return { meaning: text, example: nil }
  end
end

def extract_kanji_data(url)
  doc = fetch_page(url)
  return nil unless doc

  # 1. 기본 정보 추출 (jitenon.jp)
  h1_text = doc.at_css('h1')&.text&.strip
  match = h1_text.match(/「(.+)」/)
  char = match ? match[1] : nil
  
  unless char
    puts "  [Log] jitenon에서 한자를 추출하지 못했습니다."
    return nil
  end

  unicode = "U+#{char.ord.to_s(16).upcase}"

  # --- Kanjipedia 데이터 크롤링 ---
  kp_meanings = fetch_kanjipedia_data(char)

  # 2. 테이블 데이터 및 훈독 추출
  onyomi = []
  kunyomi = []
  radical = ""
  strokes = ""
  kanken = "8級"
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
      radical = td_text.split('（').first.strip.split('・').first.sub(/部$/, '').strip
    when "画数"
      strokes = td_text.tr('０-９', '0-9').to_i
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

  # Compounds Generation Logic
  compounds_list = []

  # 1. Kunyomi compounds
  kunyomi.each do |k|
    r_str = k['reading'] # e.g. "まわ-す"
    if r_str.include?('-')
      parts = r_str.split('-')
      yomi_part = parts[0]
      okurigana = parts[1] || ""
    else
      yomi_part = r_str
      okurigana = ""
    end
    
    word = "#{char}#{okurigana}"
    reading_clean = r_str.delete('-')
    
    # "yomi" part needs quotes, others as specified
    compounds_list << {
      type: :kunyomi,
      word: word,
      reading: reading_clean,
      yomi: yomi_part
    }
  end

  # 2. Meaning examples
  kp_meanings.each do |m|
    if m['example']
      compounds_list << {
        type: :example,
        word: m['example']
      }
    end
    
    if m['submeanings']
      m['submeanings'].each do |sub|
        if sub['example']
          compounds_list << {
            type: :example,
            word: sub['example']
          }
        end
      end
    end
  end
  
  # Remove duplicates if any
  compounds_list.uniq! { |c| c[:word] }



  # YAML 생성
  yaml_content = <<~YAML
---
title: #{char}
char: #{char}
unicode: #{unicode}
meanings:
YAML

  if kp_meanings.empty?
    yaml_content += " []\n"
  else
    kp_meanings.each do |m|
      # meaning: "…"
      # example: "…"
      # reading: "…"
      # submeanings: […]
      
      line = "  - { meaning: \"#{m['meaning']}\""
      line += ", reading: \"#{m['reading']}\"" if m['reading']
      line += ", example: \"#{m['example']}\"" if m['example']
      
      if m['submeanings']
        line += ", submeanings: [\n"
        m['submeanings'].each do |sub|
          sub_line = "      { meaning: \"#{sub['meaning']}\""
          sub_line += ", example: \"#{sub['example']}\"" if sub['example']
          sub_line += " },\n" 
          line += sub_line
        end
        line = line.chomp(",\n") + "\n    ]" 
      end
      
      line += " }\n"
      yaml_content += line
    end
  end

  yaml_content += "onyomi:\n"

  onyomi_list = onyomi.empty? ? " []\n" : onyomi.map { |y| "  - { reading: #{y['reading']}, type: \"#{y['type']}\" }\n" }.join
  yaml_content += onyomi_list
  yaml_content += "kunyomi:\n"
  kunyomi_list = kunyomi.empty? ? " []\n" : kunyomi.map { |y| "  - { reading: #{y['reading']}, type: \"#{y['type']}\" }\n" }.join
  yaml_content += kunyomi_list
  yaml_content += "radical: #{radical}\nstrokes: #{strokes}\nkanken: #{kanken}\njis: #{jis}\nvariants:\ncompounds:\n"
  
  if compounds_list.empty?
    # Leave empty or []? Previous behavior was newline. User example shows list.
    # User's previous request (Step 851) "compounds: [newline] - { … }"
    # If empty, maybe just nothing or ' []'?
    # Let's keep it empty newline if empty, as per previous files.
  else
    compounds_list.each do |item|
      if item[:type] == :kunyomi
        # { word: 回す, reading: まわす, gloss: "" ,  yomi: "まわ"}
        # word, reading: NO quotes. gloss, yomi: quotes.
        line = "  - { word: #{item[:word]}, reading: #{item[:reading]}, gloss: \"\", yomi: \"#{item[:yomi]}\" }\n"
        yaml_content += line
      elsif item[:type] == :example
        # example: { word: 画面, reading: "", gloss: "" ,  yomi: ""}
        # All parts here except word? User example 2 doesn't show quotes for 画面.
        line = "  - { word: #{item[:word]}, reading: \"\", gloss: \"\", yomi: \"\" }\n"
        yaml_content += line
      end
    end
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
      current_type = (img && img['src'] =~ /yomi_icon[1-3]\.svg/) ? "상용" : nil
    elsif child.name == 'img' && child['src'] =~ /yomi_icon[1-3]\.svg/
      current_type = "상용"
    elsif child.text? || child.name == 'a'
      text = child.text.strip
      next if text.empty? || text == '・'
      text.split('・').each do |part|
        part = part.strip
        next if part.empty?
        part = part.sub(/（(.+)）/, '-\\1') if is_kunyomi
        readings << { "reading" => part, "type" => current_type }.compact
      end
      current_type = nil
    end
  end
  readings
end

# 메인 실행부
puts "Fetching list from #{LIST_URL}…"
list_doc = fetch_page(LIST_URL)
exit 1 unless list_doc

links = list_doc.css('.search_parts li a').map { |a| a['href'] }
            .select { |href| href =~ %r{/kanji/\d+} }
            .map { |href| URI.join(BASE_URL, href).to_s }.uniq

links.each_with_index do |url, index|
  puts "[#{index + 1}/#{links.size}] Processing #{url}…"
  yaml_content = extract_kanji_data(url)
  if yaml_content
    unicode_match = yaml_content.match(/unicode: (U\+[0-9A-F]+)/)
    if unicode_match
      unicode = unicode_match[1].sub('U+', '')
      filename = File.join(TARGET_DIR, "#{unicode}.md")
      File.open(filename, 'w') { |f| f.write(yaml_content) }
      puts "  Saved to #{filename}"
    end
  end
  sleep 1.5 # 부하 방지를 위해 약간 늘림
end