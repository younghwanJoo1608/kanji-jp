require 'yaml'
require 'fileutils'
require 'time'

# _kanji 디렉토리 내의 모든 마크다운 파일 찾기
kanji_files = Dir.glob("_kanji/*.md")
lastmod_data = {}

puts "Processing #{kanji_files.length} kanji files…"

kanji_files.each do |file|
  # 파일 내용 읽어서 title 추출 (URL 생성용)
  content = File.read(file)
  if content =~ /^title:\s*(.+)$/
    # 파일명에서 확장자 제거하여 키로 사용 (예: 4E00)
    key = File.basename(file, ".*")
    
    # git log로 마지막 수정 시간 가져오기
    # %aI: author date, ISO 8601 format
    date = `git log -1 --format="%aI" "#{file}"`.strip
    
    if date.empty?
      # git에 커밋되지 않은 파일인 경우 현재 시간 사용
      date = Time.now.iso8601
    end
    
    lastmod_data[key] = date
  end
end

# _data 디렉토리 생성
FileUtils.mkdir_p("_data")

# YAML 파일로 저장
File.open("_data/lastmod.yml", "w") do |f|
  f.write(lastmod_data.to_yaml)
end

puts "Generated _data/lastmod.yml with #{lastmod_data.length} entries."
