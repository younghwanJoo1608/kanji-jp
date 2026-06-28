(function () {
  const state = {
    items: [],
    ready: false,
    selectedKanken: "",
    selectedJis: "",
    selectedRadicals: new Set(),
    lastRenderKey: ""
  };

  const els = {
    input: document.getElementById("kanji-search-input"),
    clear: document.getElementById("kanji-search-clear"),
    status: document.getElementById("search-status"),
    results: document.getElementById("search-results"),
    kankenButtons: document.getElementById("filter-kanken-buttons"),
    kankenSummary: document.getElementById("filter-kanken-summary"),
    kankenReset: document.getElementById("filter-kanken-reset"),
    kankenPanel: document.getElementById("filter-kanken-panel"),
    kankenToggleLabel: document.getElementById("filter-kanken-toggle-label"),
    jisButtons: document.getElementById("filter-jis-buttons"),
    jisSummary: document.getElementById("filter-jis-summary"),
    jisReset: document.getElementById("filter-jis-reset"),
    jisPanel: document.getElementById("filter-jis-panel"),
    jisToggleLabel: document.getElementById("filter-jis-toggle-label"),
    strokes: document.getElementById("filter-strokes"),
    radicalButtons: document.getElementById("filter-radical-buttons"),
    radicalSummary: document.getElementById("filter-radical-summary"),
    radicalReset: document.getElementById("filter-radical-reset"),
    radicalPanel: document.querySelector(".radical-filter-panel"),
    radicalToggleLabel: document.getElementById("filter-radical-toggle-label"),
    lexicon: document.getElementById("filter-lexicon")
  };

  const KANKEN_ORDER = ["10級", "9級", "8級", "7級", "6級", "5級", "4級", "3級", "準2級", "2級", "準1級", "1級", "配当外"];
  const JIS_ORDER = ["第1水準", "第2水準", "第3水準", "第4水準", "外字"];
  const RADICAL_ORDER = [
    "一", "丨", "丶", "丿", "乙", "亅", "二", "亠", "人", "儿", "入", "八", "冂", "冖", "冫", "几", "凵", "刀", "力", "勹", "匕", "匚", "匸", "十", "卜", "卩", "厂", "厶", "又",
    "口", "囗", "土", "士", "夂", "夊", "夕", "大", "女", "子", "宀", "寸", "小", "尢", "尸", "屮", "山", "巛", "工", "己", "巾", "干", "幺", "广", "廴", "廾", "弋", "弓", "彐", "彡", "彳",
    "心", "戈", "戶", "手", "支", "攴", "文", "斗", "斤", "方", "无", "日", "曰", "月", "木", "欠", "止", "歹", "殳", "毋", "比", "毛", "氏", "气", "水", "火", "爪", "父", "爻", "爿", "片", "牙", "牛", "犬",
    "玄", "玉", "瓜", "瓦", "甘", "生", "用", "田", "疋", "疒", "癶", "白", "皮", "皿", "目", "矛", "矢", "石", "示", "禸", "禾", "穴", "立",
    "竹", "米", "糸", "缶", "网", "羊", "羽", "老", "而", "耒", "耳", "聿", "肉", "臣", "自", "至", "臼", "舌", "舛", "舟", "艮", "色", "艸", "虍", "虫", "血", "行", "衣", "襾",
    "見", "角", "言", "谷", "豆", "豕", "豸", "貝", "赤", "走", "足", "身", "車", "辛", "辰", "辵", "邑", "酉", "釆", "里",
    "金", "長", "門", "阜", "隶", "隹", "雨", "靑", "非",
    "面", "革", "韋", "韭", "音", "頁", "風", "飛", "食", "首", "香",
    "馬", "骨", "高", "髟", "鬥", "鬯", "鬲", "鬼",
    "魚", "鳥", "鹵", "鹿", "麥", "麻",
    "黃", "黍", "黑", "黹",
    "黽", "鼎", "鼓", "鼠",
    "鼻", "齊",
    "齒",
    "龍", "龜",
    "龠"
  ];
  const RADICAL_ALIASES = {
    "羽": "羽",
    "戸": "戶",
    "青": "靑",
    "麦": "麥",
    "黄": "黃",
    "黒": "黑",
    "歯": "齒",
    "竜": "龍",
    "亀": "龜"
  };

  function normalizeKanaChar(ch) {
    const code = ch.charCodeAt(0);
    if (code >= 0x30a1 && code <= 0x30f6) {
      return String.fromCharCode(code - 0x60);
    }
    return ch;
  }

  function isIgnoredSearchChar(ch) {
    const cp = ch.codePointAt(0);
    return /[\s\-‐‑‒–—―ーｰ・･·.。､、,，()（）\[\]「」『』]/u.test(ch)
      || (cp >= 0xFE00 && cp <= 0xFE0F)
      || (cp >= 0xE0100 && cp <= 0xE01EF);
  }

  function decodeNumericEntities(value) {
    return String(value == null ? "" : value).replace(/&#(x[0-9a-f]+|\d+);?/gi, (match, body) => {
      const codePoint = body[0].toLowerCase() === "x"
        ? parseInt(body.slice(1), 16)
        : parseInt(body, 10);
      if (!Number.isFinite(codePoint)) return match;
      try {
        return String.fromCodePoint(codePoint);
      } catch (error) {
        return match;
      }
    });
  }

  function normalizeSearchText(value) {
    if (value == null) return "";
    let out = "";
    for (const raw of Array.from(decodeNumericEntities(value).normalize("NFKC").toLowerCase())) {
      const ch = normalizeKanaChar(raw);
      if (!isIgnoredSearchChar(ch)) out += ch;
    }
    return out;
  }

  function normalizedMap(value) {
    const text = decodeNumericEntities(value);
    const chars = Array.from(text);
    let normalized = "";
    const map = [];

    chars.forEach((original, index) => {
      for (const raw of Array.from(original.normalize("NFKC").toLowerCase())) {
        const ch = normalizeKanaChar(raw);
        if (!isIgnoredSearchChar(ch)) {
          normalized += ch;
          map.push(index);
        }
      }
    });

    return { text, chars, normalized, map };
  }

  function escapeHtml(value) {
    return decodeNumericEntities(value).replace(/[&<>"']/g, (ch) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "\"": "&quot;",
      "'": "&#39;"
    }[ch]));
  }

  function highlight(value, queryNorm) {
    const model = normalizedMap(value);
    if (!queryNorm || !model.normalized) return escapeHtml(model.text);
    const start = model.normalized.indexOf(queryNorm);
    if (start === -1) return escapeHtml(model.text);

    const end = start + queryNorm.length - 1;
    const rawStart = model.map[start];
    const rawEnd = model.map[end] + 1;
    return [
      escapeHtml(model.chars.slice(0, rawStart).join("")),
      "<mark>",
      escapeHtml(model.chars.slice(rawStart, rawEnd).join("")),
      "</mark>",
      escapeHtml(model.chars.slice(rawEnd).join(""))
    ].join("");
  }

  function textFromReading(item) {
    if (!item) return "";
    if (typeof item === "string") return item;
    return item.reading || "";
  }

  function flattenMeanings(meanings) {
    if (!meanings) return [];
    if (typeof meanings === "string") return [meanings];
    if (!Array.isArray(meanings)) return [];
    const rows = [];
    const pushMeaning = (m, prefix = "") => {
      if (!m) return;
      if (typeof m === "string") {
        rows.push(`${prefix}${m}`);
        return;
      }
      if (m.meaning) rows.push(`${prefix}${m.meaning}${m.example ? ` 「${m.example}」` : ""}`);
      if (Array.isArray(m.submeanings)) {
        m.submeanings.forEach((sub) => {
          if (sub?.meaning) rows.push(`${prefix}${sub.meaning}${sub.example ? ` 「${sub.example}」` : ""}`);
        });
      }
    };
    meanings.forEach((m) => {
      if (!m) return;
      if (typeof m === "string") {
        rows.push(m);
        return;
      }
      const prefix = m.reading ? `${m.reading} ` : "";
      if (Array.isArray(m.meanings)) {
        m.meanings.forEach((child) => pushMeaning(child, prefix));
      } else {
        pushMeaning(m, prefix);
      }
    });
    return rows;
  }

  function itemArray(value) {
    return Array.isArray(value) ? value : [];
  }

  function readingVariants(reading) {
    const raw = String(reading || "");
    if (!raw) return [];
    const noParen = raw.replace(/[（(].*?[）)]/g, "");
    const noMiddle = noParen.replace(/[・･]/g, "");
    const noHyphen = noMiddle.replace(/[-‐‑‒–—―]/g, "");
    const beforeHyphen = noMiddle.split(/[-‐‑‒–—―]/)[0];
    return Array.from(new Set([raw, noParen, noMiddle, noHyphen, beforeHyphen].filter(Boolean)));
  }

  function hasAdvanced(item) {
    return itemArray(item.compounds).some((entry) => entry && entry.reference);
  }

  function hasGenre(item) {
    return itemArray(item.compounds).some((entry) => entry && entry.genre);
  }

  function hasReference(item) {
    const compoundRef = itemArray(item.compounds).some((entry) => entry && entry.reference);
    const onyRef = itemArray(item.onyomi).some((entry) => entry && typeof entry === "object" && entry.reference);
    const kunRef = itemArray(item.kunyomi).some((entry) => entry && typeof entry === "object" && entry.reference);
    return compoundRef || onyRef || kunRef;
  }

  function radicalKey(item) {
    return String(item.radical || "").split(" ")[0].split("（")[0].split("(")[0].trim();
  }

  function canonicalRadical(value) {
    return RADICAL_ALIASES[value] || value;
  }

  function prepareItem(item) {
    const displayChar = decodeNumericEntities(item.char || "");
    const displayTitle = decodeNumericEntities(item.title || item.char || "");
    const onyomi = itemArray(item.onyomi).map(textFromReading).filter(Boolean);
    const kunyomi = itemArray(item.kunyomi).map(textFromReading).filter(Boolean);
    const meanings = flattenMeanings(item.meanings);
    const compounds = itemArray(item.compounds);
    const idioms = itemArray(item.idioms);
    const saja = itemArray(item.saja);

    const searchable = [
      item.char,
      item.title,
      item.unicode,
      String(item.unicode || "").replace(/^U\+/i, ""),
      item.kanken,
      item.jis,
      item.strokes,
      item.radical,
      item.variants,
      ...meanings,
      ...onyomi.flatMap(readingVariants),
      ...kunyomi.flatMap(readingVariants)
    ];

    compounds.concat(idioms, saja).forEach((entry) => {
      if (!entry) return;
      searchable.push(entry.word, entry.reading, entry.gloss, entry.yomi, entry.variation, entry.replace, entry.reference, entry.genre);
      readingVariants(entry.reading).forEach((v) => searchable.push(v));
    });

    return {
      ...item,
      _displayChar: displayChar,
      _displayTitle: displayTitle,
      _onyomi: onyomi,
      _kunyomi: kunyomi,
      _meanings: meanings,
      _compounds: compounds,
      _idioms: idioms,
      _saja: saja,
      _radicalKey: radicalKey(item),
      _radicalCanonical: canonicalRadical(radicalKey(item)),
      _hasAdvanced: hasAdvanced(item),
      _hasGenre: hasGenre(item),
      _hasReference: hasReference(item),
      _searchBlob: searchable.map(normalizeSearchText).filter(Boolean).join(" ")
    };
  }

  function addOption(select, value, label) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label || value;
    select.appendChild(option);
  }

  function orderedFilterValues(order, counts) {
    const known = order.filter((value) => counts.has(value));
    const extras = [...counts.keys()]
      .filter((value) => !order.includes(value))
      .sort((a, b) => String(a).localeCompare(String(b), "ja"));
    return known.concat(extras);
  }

  function appendFilterButton(container, value, label, count) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "filter-chip-button";
    button.dataset.value = value;
    button.setAttribute("aria-pressed", "false");
    button.innerHTML = `<span>${escapeHtml(label || value)}</span><small>${count}</small>`;
    container.appendChild(button);
  }

  function fillFilters() {
    const kankenCounts = new Map();
    state.items.forEach((item) => {
      const value = item.kanken || "配当外";
      kankenCounts.set(value, (kankenCounts.get(value) || 0) + 1);
    });
    orderedFilterValues(KANKEN_ORDER, kankenCounts).forEach((v) => appendFilterButton(els.kankenButtons, v, v, kankenCounts.get(v)));

    const jisCounts = new Map();
    state.items.forEach((item) => {
      const value = item.jis || "外字";
      jisCounts.set(value, (jisCounts.get(value) || 0) + 1);
    });
    orderedFilterValues(JIS_ORDER, jisCounts).forEach((v) => appendFilterButton(els.jisButtons, v, v, jisCounts.get(v)));

    [...new Set(state.items.map((item) => Number(item.strokes)).filter(Boolean))]
      .sort((a, b) => a - b)
      .forEach((v) => addOption(els.strokes, String(v), `${v}획`));

    const counts = new Map();
    state.items.forEach((item) => {
      counts.set(item._radicalCanonical, (counts.get(item._radicalCanonical) || 0) + 1);
    });
    RADICAL_ORDER.forEach((v) => {
        const count = counts.get(v) || 0;
        const button = document.createElement("button");
        button.type = "button";
        button.className = "radical-filter-button";
        button.dataset.radical = v;
        button.setAttribute("aria-pressed", "false");
        button.disabled = count === 0;
        button.innerHTML = `<span>${escapeHtml(v)}</span><small>${count}</small>`;
        els.radicalButtons.appendChild(button);
      });
  }

  function passesFilters(item) {
    if (state.selectedKanken && (item.kanken || "配当外") !== state.selectedKanken) return false;
    if (state.selectedJis && (item.jis || "外字") !== state.selectedJis) return false;
    if (els.strokes.value && String(item.strokes || "") !== els.strokes.value) return false;
    if (state.selectedRadicals.size > 0 && !state.selectedRadicals.has(item._radicalCanonical)) {
      return false;
    }
    if (els.lexicon.value === "advanced" && !item._hasAdvanced) return false;
    if (els.lexicon.value === "genre" && !item._hasGenre) return false;
    if (els.lexicon.value === "reference" && !item._hasReference) return false;
    return true;
  }

  const SCORE = {
    charExact: 10000,
    charPartial: 9500,
    unicodeExact: 9000,
    unicodePartial: 8500,
    wordExact: 8000,
    wordPartial: 7600,
    queryKanji: 7400,
    readingExact: 7000,
    readingPartial: 6600,
    meaning: 5200,
    gloss: 4300,
    meta: 3200
  };

  function matchKind(value, queryNorm) {
    if (!queryNorm) return "";
    const normalized = normalizeSearchText(value);
    if (!normalized) return "";
    if (normalized === queryNorm) return "exact";
    return normalized.includes(queryNorm) ? "partial" : "";
  }

  function addMatch(matches, section, text, queryNorm, score) {
    if (!text) return;
    const normalized = normalizeSearchText(text);
    if (queryNorm && !normalized.includes(queryNorm)) return;
    matches.push({ section, text, score });
  }

  function addValueMatch(matches, section, value, queryNorm, exactScore, partialScore, text) {
    const kind = matchKind(value, queryNorm);
    if (!kind) return;
    matches.push({
      section,
      text: text || value,
      score: kind === "exact" ? exactScore : partialScore
    });
  }

  function addDirectMatch(matches, section, text, score, queryNorm) {
    if (!text) return;
    matches.push({ section, text, score, queryNorm });
  }

  function extractKanjiSet(value) {
    const chars = new Set();
    Array.from(decodeNumericEntities(value).normalize("NFKC")).forEach((ch) => {
      if (!/\p{Script=Han}/u.test(ch) || isIgnoredSearchChar(ch)) return;
      const normalized = normalizeSearchText(ch);
      if (normalized) chars.add(normalized);
    });
    return chars;
  }

  function addEntryMatches(matches, section, entry, queryNorm) {
    if (!entry) return;
    const wordText = [entry.word, entry.reading].filter(Boolean).join(" ");
    addValueMatch(matches, section, entry.word, queryNorm, SCORE.wordExact, SCORE.wordPartial, wordText);
    addValueMatch(matches, section, entry.reading, queryNorm, SCORE.readingExact, SCORE.readingPartial, wordText);
    readingVariants(entry.reading).forEach((variant) => {
      addValueMatch(matches, section, variant, queryNorm, SCORE.readingExact, SCORE.readingPartial, wordText);
    });
    addMatch(matches, section, [entry.word, entry.reading, entry.gloss].filter(Boolean).join(" "), queryNorm, SCORE.gloss);
    addMatch(matches, section, [entry.variation, entry.replace, entry.reference, entry.genre].filter(Boolean).join(" "), queryNorm, SCORE.meta);
  }

  function uniqueMatches(matches) {
    const byKey = new Map();
    matches.forEach((match) => {
      const key = `${match.section}\u0000${match.text}`;
      const previous = byKey.get(key);
      if (!previous || (match.score || 0) > (previous.score || 0)) {
        byKey.set(key, match);
      }
    });
    return [...byKey.values()];
  }

  function collectMatches(item, queryNorm, queryKanjiSet) {
    const matches = [];
    const limit = 8;
    const itemCharNorm = normalizeSearchText(item._displayChar);
    if (queryKanjiSet?.size > 1 && itemCharNorm && queryKanjiSet.has(itemCharNorm) && itemCharNorm !== queryNorm) {
      addDirectMatch(matches, "검색어 구성 한자", `${item._displayChar} ${item.unicode || ""}`, SCORE.queryKanji, itemCharNorm);
    }
    addValueMatch(matches, "한자", item._displayChar, queryNorm, SCORE.charExact, SCORE.charPartial, `${item._displayChar} ${item.unicode || ""}`);
    addValueMatch(matches, "한자", item._displayTitle, queryNorm, SCORE.charExact, SCORE.charPartial, `${item._displayTitle} ${item.unicode || ""}`);
    addValueMatch(matches, "유니코드", item.unicode, queryNorm, SCORE.unicodeExact, SCORE.unicodePartial, item.unicode || "");
    addValueMatch(matches, "유니코드", String(item.unicode || "").replace(/^U\+/i, ""), queryNorm, SCORE.unicodeExact, SCORE.unicodePartial, item.unicode || "");
    item._onyomi.forEach((text) => {
      addValueMatch(matches, "음독", text, queryNorm, SCORE.readingExact, SCORE.readingPartial, text);
    });
    item._kunyomi.forEach((text) => {
      readingVariants(text).forEach((variant) => {
        addValueMatch(matches, "훈독", variant, queryNorm, SCORE.readingExact, SCORE.readingPartial, text);
      });
    });
    item._compounds.forEach((entry) => {
      const label = entry.reference ? "고급 어휘" : "일반 사전 어휘";
      addEntryMatches(matches, label, entry, queryNorm);
    });
    item._idioms.forEach((entry) => addEntryMatches(matches, "관용구", entry, queryNorm));
    item._saja.forEach((entry) => addEntryMatches(matches, "사자성어", entry, queryNorm));
    item._meanings.forEach((text) => addMatch(matches, "의미", text, queryNorm, SCORE.meaning));
    addMatch(matches, "메타데이터", [item.radical, item.kanken, item.jis, item.variants].filter(Boolean).join(" "), queryNorm, SCORE.meta);

    if (!queryNorm && matches.length === 0) {
      item._meanings.slice(0, 2).forEach((text) => matches.push({ section: "의미", text, score: 0 }));
    }
    return uniqueMatches(matches)
      .sort((a, b) => b.score - a.score || a.section.localeCompare(b.section, "ko"))
      .slice(0, limit);
  }

  function scoreItem(item, queryNorm, matches) {
    if (!queryNorm) return 0;
    if (!matches.length) return 0;
    return Math.max(...matches.map((match) => match.score || 0)) + Math.min(matches.length, 8);
  }

  function cardClass(item) {
    const kanken = item.kanken || "";
    if (!kanken) return "card-none";
    return `card-kanken-${kanken.replace("級", "").replace("準", "pre").replace("급", "").replace("준", "pre")}`;
  }

  function badgeClass(item) {
    const kanken = item.kanken || "";
    if (!kanken) return "badge-none";
    return `badge-kanken-${kanken.replace("級", "").replace("準", "pre").replace("급", "").replace("준", "pre")}`;
  }

  function renderCard(item) {
    const readings = [item._onyomi[0], item._kunyomi[0]].filter(Boolean).join("・");
    const level = item.kanken || "配当外";
    const radical = item._radicalKey ? `<span>${escapeHtml(item._radicalKey)}部</span>` : "";
    const strokes = item.strokes ? `<span>${escapeHtml(item.strokes)}획</span>` : "";
    return `
      <a class="card ${cardClass(item)}" href="${escapeHtml(item.url)}" title="${escapeHtml(item._displayTitle || item._displayChar)}">
        <span class="card-level ${badgeClass(item)}">${escapeHtml(level)}</span>
        <span class="g">${escapeHtml(item._displayChar)}</span>
        <div class="title-line">
          <span class="title">${escapeHtml(item._displayTitle || item._displayChar)}</span>
          ${readings ? `<span class="readings-inline">（${escapeHtml(readings)}）</span>` : ""}
        </div>
        <div class="card-meta">${radical}${strokes}</div>
        <small class="card-code">${escapeHtml(item.unicode || "")}</small>
      </a>
    `;
  }

  function renderMatches(matches, queryNorm) {
    if (!matches.length) return '<p class="search-no-snippet">필터 조건에 맞는 한자입니다.</p>';
    return matches.map((match) => `
      <div class="search-match">
        <div class="search-match-section">${escapeHtml(match.section)}</div>
        <div class="search-match-text">${highlight(match.text, match.queryNorm || queryNorm)}</div>
      </div>
    `).join("");
  }

  function render() {
    if (!state.ready) return;
    const query = els.input.value.trim();
    const queryNorm = normalizeSearchText(query);
    const queryKanjiSet = extractKanjiSet(query);
    const filtersActive = Boolean(state.selectedKanken || state.selectedJis)
      || [els.strokes, els.lexicon].some((el) => el.value)
      || state.selectedRadicals.size > 0;
    const renderKey = JSON.stringify({
      query,
      kanken: state.selectedKanken,
      jis: state.selectedJis,
      strokes: els.strokes.value,
      lexicon: els.lexicon.value,
      radicals: [...state.selectedRadicals].sort()
    });

    if (renderKey === state.lastRenderKey) return;
    state.lastRenderKey = renderKey;

    if (!queryNorm && !filtersActive) {
      els.status.textContent = "검색어를 입력하거나 필터를 선택하세요.";
      els.results.innerHTML = "";
      return;
    }

    const results = state.items
      .filter(passesFilters)
      .map((item) => {
        const itemCharNorm = normalizeSearchText(item._displayChar);
        const hasQueryKanji = queryKanjiSet.size > 1 && queryKanjiSet.has(itemCharNorm);
        if (queryNorm && !item._searchBlob.includes(queryNorm) && !hasQueryKanji) return null;
        const matches = collectMatches(item, queryNorm, queryKanjiSet);
        return { item, matches, score: scoreItem(item, queryNorm, matches) };
      })
      .filter(Boolean)
      .sort((a, b) => b.score - a.score || (a.item.strokes || 0) - (b.item.strokes || 0) || String(a.item.title).localeCompare(String(b.item.title), "ja"));

    els.status.textContent = `${results.length}개 결과`;
    els.results.innerHTML = results.slice(0, 120).map(({ item, matches }) => `
      <article class="search-result">
        <div class="search-result-card">${renderCard(item)}</div>
        <div class="search-result-body">
          <h2><a href="${escapeHtml(item.url)}">${escapeHtml(item._displayChar)} <span>${escapeHtml(item.unicode || "")}</span></a></h2>
          ${renderMatches(matches, queryNorm)}
        </div>
      </article>
    `).join("");

    if (results.length > 120) {
      els.results.insertAdjacentHTML("beforeend", `<p class="search-more">상위 120개 결과만 표시합니다. 검색어나 필터를 더 좁혀 주세요.</p>`);
    }
  }

  function bindEvents() {
    els.input.addEventListener("input", render);
    [els.strokes, els.lexicon].forEach((el) => {
      el.addEventListener("change", render);
    });
    els.kankenButtons.addEventListener("click", (event) => {
      const button = event.target.closest(".filter-chip-button");
      if (!button) return;
      state.selectedKanken = state.selectedKanken === button.dataset.value ? "" : button.dataset.value;
      updateSingleFilterButtons(els.kankenButtons, state.selectedKanken);
      updateSingleFilterSummary(els.kankenSummary, state.selectedKanken);
      render();
    });
    els.kankenReset.addEventListener("click", () => {
      state.selectedKanken = "";
      updateSingleFilterButtons(els.kankenButtons, state.selectedKanken);
      updateSingleFilterSummary(els.kankenSummary, state.selectedKanken);
      render();
    });
    els.jisButtons.addEventListener("click", (event) => {
      const button = event.target.closest(".filter-chip-button");
      if (!button) return;
      state.selectedJis = state.selectedJis === button.dataset.value ? "" : button.dataset.value;
      updateSingleFilterButtons(els.jisButtons, state.selectedJis);
      updateSingleFilterSummary(els.jisSummary, state.selectedJis);
      render();
    });
    els.jisReset.addEventListener("click", () => {
      state.selectedJis = "";
      updateSingleFilterButtons(els.jisButtons, state.selectedJis);
      updateSingleFilterSummary(els.jisSummary, state.selectedJis);
      render();
    });
    els.radicalButtons.addEventListener("click", (event) => {
      const button = event.target.closest(".radical-filter-button");
      if (!button) return;
      const radical = button.dataset.radical;
      if (state.selectedRadicals.has(radical)) {
        state.selectedRadicals.delete(radical);
        button.classList.remove("active");
        button.setAttribute("aria-pressed", "false");
      } else {
        state.selectedRadicals.add(radical);
        button.classList.add("active");
        button.setAttribute("aria-pressed", "true");
      }
      updateRadicalSummary();
      render();
    });
    els.radicalReset.addEventListener("click", () => {
      state.selectedRadicals.clear();
      els.radicalButtons.querySelectorAll(".radical-filter-button.active").forEach((button) => {
        button.classList.remove("active");
        button.setAttribute("aria-pressed", "false");
      });
      updateRadicalSummary();
      render();
    });
    els.kankenPanel.addEventListener("toggle", () => updateToggleLabel(els.kankenPanel, els.kankenToggleLabel));
    els.jisPanel.addEventListener("toggle", () => updateToggleLabel(els.jisPanel, els.jisToggleLabel));
    els.radicalPanel.addEventListener("toggle", updateRadicalToggleLabel);
    els.clear.addEventListener("click", () => {
      els.input.value = "";
      render();
      els.input.focus();
    });
  }

  function updateSingleFilterButtons(container, selectedValue) {
    container.querySelectorAll(".filter-chip-button").forEach((button) => {
      const active = button.dataset.value === selectedValue;
      button.classList.toggle("active", active);
      button.setAttribute("aria-pressed", active ? "true" : "false");
    });
  }

  function updateSingleFilterSummary(el, selectedValue) {
    el.textContent = selectedValue || "선택 없음";
  }

  function updateRadicalSummary() {
    if (state.selectedRadicals.size === 0) {
      els.radicalSummary.textContent = "선택 없음";
      return;
    }
    const selected = [...state.selectedRadicals].sort((a, b) => a.localeCompare(b, "ja"));
    els.radicalSummary.textContent = selected.length <= 4
      ? selected.map((v) => `${v}部`).join(", ")
      : `${selected.slice(0, 4).map((v) => `${v}部`).join(", ")} 외 ${selected.length - 4}`;
  }

  function updateRadicalToggleLabel() {
    updateToggleLabel(els.radicalPanel, els.radicalToggleLabel);
  }

  function updateToggleLabel(panel, label) {
    label.textContent = panel.open ? "닫기" : "열기";
  }

  async function init() {
    bindEvents();
    try {
      const response = await fetch("/search.json");
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      state.items = data.map(prepareItem);
      fillFilters();
      updateSingleFilterButtons(els.kankenButtons, state.selectedKanken);
      updateSingleFilterButtons(els.jisButtons, state.selectedJis);
      updateSingleFilterSummary(els.kankenSummary, state.selectedKanken);
      updateSingleFilterSummary(els.jisSummary, state.selectedJis);
      updateRadicalSummary();
      updateToggleLabel(els.kankenPanel, els.kankenToggleLabel);
      updateToggleLabel(els.jisPanel, els.jisToggleLabel);
      updateRadicalToggleLabel();
      state.ready = true;
      render();
    } catch (error) {
      els.status.textContent = "검색 데이터를 불러오지 못했습니다.";
      console.error("Search init failed", error);
    }
  }

  init();
}());
