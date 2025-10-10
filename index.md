---
layout: default
title: 일본어 한자 사전
---

# 일본어 한자 사전

일본어 한자 공부를 위한 개인 사전입니다.


## 최근 추가된 한자

{% assign recent = site.kanji | sort: "date" | reverse | slice: 0, 10 %}

<div class="grid">
  {% for k in recent %}
    <a class="card" href="{{ k.url | relative_url }}" title="{{ k.title }}">
      <span class="g">{{ k.char }}</span>
      <div>{{ k.title }}</div>
      <small>{{ k.unicode }}</small>
    </a>
  {% endfor %}
</div>