# bundle exec ruby scrape_kanken_9.rb

require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'yaml'

# 타겟 디렉토리
TARGET_DIR = "_kanji_9"
FileUtils.mkdir_p(TARGET_DIR)

# 목록 페이지 URL
LIST_URL = "https://kanji.jitenon.jp/cat/kyu09"
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
  # h1 텍스트 예: "漢字「刀」について" 또는 "「刀」の漢字" 등
  # 괄호 안의 문자 추출
  h1_text = doc.at_css('h1')&.text&.strip
  match = h1_text.match(/「(.+)」/)
  char = match ? match[1] : nil
  
  # 만약 괄호 추출 실패 시, 다른 방법 시도 (예: meta title 등)
  unless char
    # fallback: title 태그 등 확인, 혹은 h1 전체에서 한자만 추출 시도
    # 여기서는 일단 nil 반환하여 스킵
    puts "  Failed to extract char from h1: #{h1_text}"
    return nil
  end

  # 유니코드 계산
  unicode = "U+#{char.ord.to_s(16).upcase}"

  # 2. 테이블 데이터 추출
  # meanings, onyomi, kunyomi, compounds는 사용자 요청에 따라 비워둠
  meanings = ""
  onyomi = []
  kunyomi = []
  compounds = []
  
  radical = ""
  strokes = ""
  kanken = "9級"
  jis = ""

  doc.css('table.kanji_table tr').each do |tr|
    th = tr.at_css('th')&.text&.strip
    td = tr.at_css('td')&.text&.strip
    next unless th && td

    case th
    when "部首"
      radical = td
    when "画数"
      strokes = td.to_i
    when "漢検"
      kanken = td
    when "JIS水準"
      jis = td
    end
  end

  # 3. 데이터 구조화
  data = {
    "title" => char,
    "char" => char,
    "unicode" => unicode,
    "meanings" => meanings,
    "onyomi" => onyomi,
    "kunyomi" => kunyomi,
    "radical" => radical,
    "strokes" => strokes,
    "kanken" => kanken,
    "jis" => jis,
    "variants" => nil,
    "compounds" => compounds
  }

  return data
end

# 메인 로직
puts "Fetching list from #{LIST_URL}..."
list_doc = fetch_page(LIST_URL)

if list_doc
  # 목록에서 한자 링크 추출
  # HTML 구조: <ul class="search_parts"><li><a href="...">...</a></li></ul>
  # 링크는 https://kanji.jitenon.jp/kanji/숫자 형태일 수도 있고 상대 경로일 수도 있음.
  links = list_doc.css('.search_parts li a').map { |a| a['href'] }
  
  # /kanji/숫자 패턴을 포함하는 링크만 필터링
  links.select! { |l| l =~ %r{/kanji/\d+} }
  
  puts "Found #{links.size} kanji links."

  links.each_with_index do |link, index|
    full_url = link.start_with?('http') ? link : "#{BASE_URL}#{link}"
    
    puts "[#{index + 1}/#{links.size}] Processing #{full_url}..."
    
    data = extract_kanji_data(full_url)
    
    if data
      # 파일명: 유니코드 (예: 4E00.md)
      filename = "#{data['char'].ord.to_s(16).upcase}.md"
      filepath = File.join(TARGET_DIR, filename)
      
      # YAML Front Matter 생성
      yaml_content = data.to_yaml
      # to_yaml은 "---\n"으로 시작하므로, 맨 앞의 ---를 제거하거나 그대로 두고
      # Jekyll 형식에 맞게 조정. 보통 to_yaml 결과 그대로 써도 됨.
      
      # 하지만 to_yaml은 복잡한 객체를 !ruby/object 등으로 표현할 수 있으므로
      # 순수 해시만 변환했으니 괜찮음.
      # 다만 가독성을 위해 직접 포맷팅하거나 clean up 할 수도 있음.
      
      File.open(filepath, "w") do |f|
        f.write(yaml_content)
        f.write("---\n") # 컨텐츠 영역 구분
      end
      
      puts "  Saved to #{filepath}"
    else
      puts "  Failed to extract data."
    end
    
    # 서버 부하 방지를 위한 딜레이
    sleep 1
  end
else
  puts "Failed to fetch list page."
end
