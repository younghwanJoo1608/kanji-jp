---
layout: default
title: 일본어 한자 사전
---

# 일본어 한자 사전

일본어 한자 공부를 위한 개인 사전입니다.


## 최근 추가된 한자

{% assign enriched = "" %}
{% for d in site.kanji %}
  {% assign url = d.url %}
  {% comment %}
    d.path는 "_kanji/4E00.md" 형태이므로, 여기서 파일명(4E00)만 추출하여 키로 사용
  {% endcomment %}
  {% assign filename = d.path | split: "/" | last | replace: ".md", "" %}
  {% assign ts = site.data.lastmod[filename] | default: d.date | default: "0001-01-01T00:00:00Z" %}

  {%- comment -%} 읽기 정보 추출 (첫 번째 항목만) {%- endcomment -%}
  {% assign ony_text = "" %}
  {% if d.onyomi %}
    {% if d.onyomi.first and d.onyomi.first.reading %}
      {% assign ony_text = d.onyomi.first.reading %}
    {% else %}
      {% assign ony_text = d.onyomi | split: "," | first %}
    {% endif %}
  {% endif %}

  {% assign kun_text = "" %}
  {% if d.kunyomi %}
    {% if d.kunyomi.first and d.kunyomi.first.reading %}
      {% assign kun_text = d.kunyomi.first.reading %}
    {% else %}
      {% assign kun_text = d.kunyomi | split: "," | first %}
    {% endif %}
  {% endif %}

  {% assign readings = "" %}
  {% if ony_text != "" %}{% assign readings = ony_text %}{% endif %}
  {% if kun_text != "" %}
    {% if readings != "" %}{% assign readings = readings | append: "・" %}{% endif %}
    {% assign readings = readings | append: kun_text %}
  {% endif %}

  {% assign item = ts | append: "||" | append: url | append: "||" | append: d.title | append: "||" | append: d.char | append: "||" | append: d.unicode | append: "||" | append: readings %}
  {% assign enriched = enriched | append: item | append: "##SEP##" %}
{% endfor %}

{% assign rows = enriched | split: "##SEP##" | sort_natural | reverse | slice: 0, 10 %}

<div class="grid">
  {% for row in rows %}
    {% assign p = row | split: "||" %}
    <a class="card" href="{{ p[1] | relative_url }}" title="{{ p[2] }}">
      <span class="g">{{ p[3] }}</span>
      <div class="title-line">
        <span class="title">{{ p[2] }}</span>
        {% if p[5] and p[5] != "" %}
          <span class="readings-inline">（{{ p[5] }}）</span>
        {% endif %}
      </div>
      <small>{{ p[4] }}</small>
    </a>
  {% endfor %}
</div>