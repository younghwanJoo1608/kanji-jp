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
  {% assign ts = site.data.lastmod[url] | default: d.date | default: "0001-01-01T00:00:00Z" %}
  {% assign item = ts | append: "||" | append: url | append: "||" | append: d.title | append: "||" | append: d.char | append: "||" | append: d.unicode %}
  {% assign enriched = enriched | append: item | append: "##SEP##" %}
{% endfor %}

{% assign rows = enriched | split: "##SEP##" | sort_natural | reverse | slice: 0, 10 %}

<div class="grid">
  {% for row in rows %}
    {% assign p = row | split: "||" %}
    <a class="card" href="{{ p[1] | relative_url }}" title="{{ p[2] }}">
      <span class="g">{{ p[3] }}</span>
      <div>{{ p[2] }}</div>
      <small>{{ p[4] }}</small>
    </a>
  {% endfor %}
</div>