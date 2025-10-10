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
  {% assign ts = site.data.lastmod[url] | default: d.date | default: "" %}
  {% if ts != "" %}
    {% assign item = ts | append: "||" | append: url | append: "||" | append: d.title | append: "||" | append: d.char | append: "||" | append: d.unicode %}
    {% assign enriched = enriched | append: item | append: "##SEP##" %}
  {% endif %}
{% endfor %}
{% assign rows = enriched | split: "##SEP##" | sort_natural | reverse | slice: 0, 10 %}

<div class="grid">
  {% for k in recent %}
    <a class="card" href="{{ k.url | relative_url }}" title="{{ k.title }}">
      <span class="g">{{ k.char }}</span>
      <div>{{ k.title }}</div>
      <small>{{ k.unicode }}</small>
    </a>
  {% endfor %}
</div>