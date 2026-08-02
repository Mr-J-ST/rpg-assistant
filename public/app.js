const state = {
  scenes: [],
  currentId: null,
  dirty: false,
  generating: false,
  status: null,
  lastOutput: "",
};

const elements = {
  apiStatus: document.querySelector("#apiStatus"),
  sceneList: document.querySelector("#sceneList"),
  sceneTemplate: document.querySelector("#sceneItemTemplate"),
  sceneForm: document.querySelector("#sceneForm"),
  currentSceneHeading: document.querySelector("#currentSceneHeading"),
  saveState: document.querySelector("#saveState"),
  activeCharacterBadge: document.querySelector("#activeCharacterBadge"),
  keywordsInput: document.querySelector("#keywordsInput"),
  newSceneButton: document.querySelector("#newSceneButton"),
  saveSceneButton: document.querySelector("#saveSceneButton"),
  duplicateSceneButton: document.querySelector("#duplicateSceneButton"),
  deleteSceneButton: document.querySelector("#deleteSceneButton"),
  chatContext: document.querySelector("#chatContext"),
  contextCount: document.querySelector("#contextCount"),
  keywordSummary: document.querySelector("#keywordSummary"),
  keywordChips: document.querySelector("#keywordChips"),
  contextPreview: document.querySelector("#contextPreview"),
  replyGoal: document.querySelector("#replyGoal"),
  replyMode: document.querySelector("#replyMode"),
  replyLength: document.querySelector("#replyLength"),
  modelSelect: document.querySelector("#modelSelect"),
  extraConstraints: document.querySelector("#extraConstraints"),
  generateButton: document.querySelector("#generateButton"),
  regenerateButton: document.querySelector("#regenerateButton"),
  copyButton: document.querySelector("#copyButton"),
  outputSection: document.querySelector("#outputSection"),
  outputTitle: document.querySelector("#outputTitle"),
  outputText: document.querySelector("#outputText"),
  outputMeta: document.querySelector("#outputMeta"),
  toastRegion: document.querySelector("#toastRegion"),
};

function currentScene() {
  return state.scenes.find((scene) => scene.id === state.currentId) || null;
}

function getNested(object, dottedPath) {
  return dottedPath.split(".").reduce((value, key) => value?.[key], object);
}

function setNested(object, dottedPath, value) {
  const keys = dottedPath.split(".");
  let cursor = object;
  for (const key of keys.slice(0, -1)) {
    cursor[key] ||= {};
    cursor = cursor[key];
  }
  cursor[keys.at(-1)] = value;
}

function deepCopy(value) {
  return JSON.parse(JSON.stringify(value));
}

function parseKeywords(text) {
  const seen = new Set();
  const keywords = [];
  for (const line of String(text || "").split("\n")) {
    const [rawTerm, ...noteParts] = line.split("|");
    const term = rawTerm.trim();
    const note = noteParts.join("|").trim();
    const key = term.toLocaleLowerCase("zh-CN");
    if (!term || seen.has(key)) continue;
    seen.add(key);
    keywords.push({ term: term.slice(0, 120), note: note.slice(0, 500) });
    if (keywords.length >= 120) break;
  }
  return keywords;
}

function serializeKeywords(keywords) {
  return (keywords || [])
    .map((keyword) => `${keyword.term}${keyword.note ? ` | ${keyword.note}` : ""}`)
    .join("\n");
}

function splitAliases(text) {
  return String(text || "")
    .split(/[，,、;；\n]/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function buildSceneFromForm() {
  const scene = deepCopy(currentScene() || {
    name: "新场景",
    character: {},
    style: {},
    keywords: [],
  });
  for (const input of elements.sceneForm.querySelectorAll("[data-field]")) {
    setNested(scene, input.dataset.field, input.value);
  }
  scene.keywords = parseKeywords(elements.keywordsInput.value);
  return scene;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: options.body
      ? { "Content-Type": "application/json", ...(options.headers || {}) }
      : options.headers,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `请求失败（HTTP ${response.status}）`);
  return payload;
}

function showToast(message, type = "info") {
  const toast = document.createElement("div");
  toast.className = `toast${type === "error" ? " is-error" : ""}`;
  toast.textContent = message;
  elements.toastRegion.append(toast);
  window.setTimeout(() => toast.remove(), 3200);
}

function setDirty(dirty) {
  state.dirty = dirty;
  elements.saveState.textContent = dirty ? "有未保存更改" : "已保存";
  elements.saveState.classList.toggle("is-dirty", dirty);
}

function renderStatus() {
  const status = state.status;
  elements.apiStatus.className = "status-pill";
  const text = elements.apiStatus.querySelector("span:last-child");
  if (!status) {
    elements.apiStatus.classList.add("status-loading");
    text.textContent = "生成服务不可用";
    return;
  }
  if (status.apiConfigured) {
    elements.apiStatus.classList.add("status-online");
    text.textContent = `在线生成 · ${status.defaultModel}`;
  } else {
    elements.apiStatus.classList.add("status-demo");
    text.textContent = "演示生成模式";
  }
}

function sceneMonogram(scene) {
  return (scene.character?.name || scene.name || "场").trim().slice(0, 1).toUpperCase();
}

function renderSceneList() {
  elements.sceneList.replaceChildren();
  for (const scene of state.scenes) {
    const item = elements.sceneTemplate.content.firstElementChild.cloneNode(true);
    item.dataset.sceneId = scene.id;
    item.classList.toggle("is-active", scene.id === state.currentId);
    item.querySelector(".scene-monogram").textContent = sceneMonogram(scene);
    item.querySelector("strong").textContent = scene.name || "未命名场景";
    item.querySelector("small").textContent = [scene.system, scene.character?.name].filter(Boolean).join(" · ") || "尚未填写设定";
    item.addEventListener("click", () => selectScene(scene.id));
    elements.sceneList.append(item);
  }
}

function updateCounters() {
  for (const counter of document.querySelectorAll("[data-counter-for]")) {
    const input = document.querySelector(`[data-field="${counter.dataset.counterFor}"]`);
    if (input) counter.textContent = `${input.value.length} / ${input.maxLength}`;
  }
  elements.contextCount.textContent = String(elements.chatContext.value.length);
}

function populateSceneForm(scene) {
  for (const input of elements.sceneForm.querySelectorAll("[data-field]")) {
    input.value = getNested(scene, input.dataset.field) ?? "";
  }
  elements.keywordsInput.value = serializeKeywords(scene.keywords);
  elements.currentSceneHeading.textContent = scene.name || "未命名场景";
  elements.activeCharacterBadge.textContent = scene.character?.name || "未设置角色";
  const savedLength = scene.style?.replyLength;
  elements.replyLength.value = savedLength === "中等" ? "medium" : savedLength === "超长" ? "epic" : "long";
  updateCounters();
  updateKeywordMonitor();
  setDirty(false);
}

async function selectScene(id) {
  if (id === state.currentId) return;
  if (state.dirty) {
    try {
      await saveCurrentScene({ quiet: true });
    } catch (error) {
      showToast(`无法切换：${error.message}`, "error");
      return;
    }
  }
  state.currentId = id;
  const scene = currentScene();
  if (!scene) return;
  populateSceneForm(scene);
  renderSceneList();
}

async function saveCurrentScene({ quiet = false } = {}) {
  const scene = currentScene();
  if (!scene) return null;
  const payload = buildSceneFromForm();
  elements.saveSceneButton.disabled = true;
  try {
    const result = await fetchJson(`/api/scenes/${encodeURIComponent(scene.id)}`, {
      method: "PUT",
      body: JSON.stringify(payload),
    });
    const index = state.scenes.findIndex((item) => item.id === scene.id);
    state.scenes[index] = result.scene;
    state.currentId = result.scene.id;
    populateSceneForm(result.scene);
    renderSceneList();
    if (!quiet) showToast("场景档案已保存");
    return result.scene;
  } finally {
    elements.saveSceneButton.disabled = false;
  }
}

async function createScene() {
  if (state.dirty) await saveCurrentScene({ quiet: true });
  const result = await fetchJson("/api/scenes", {
    method: "POST",
    body: JSON.stringify({ name: "新场景", character: {}, style: {} }),
  });
  state.scenes.push(result.scene);
  state.currentId = result.scene.id;
  populateSceneForm(result.scene);
  renderSceneList();
  document.querySelector('[data-field="name"]').focus();
  document.querySelector('[data-field="name"]').select();
  showToast("已创建新场景");
}

async function duplicateScene() {
  if (state.dirty) await saveCurrentScene({ quiet: true });
  const scene = currentScene();
  if (!scene) return;
  const payload = deepCopy(scene);
  payload.name = `${scene.name} · 副本`;
  delete payload.id;
  delete payload.createdAt;
  delete payload.updatedAt;
  const result = await fetchJson("/api/scenes", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  state.scenes.push(result.scene);
  state.currentId = result.scene.id;
  populateSceneForm(result.scene);
  renderSceneList();
  showToast("已复制当前场景");
}

async function deleteScene() {
  const scene = currentScene();
  if (!scene) return;
  if (!window.confirm(`确定删除“${scene.name}”吗？该操作无法在界面中撤销。`)) return;
  await fetchJson(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" });
  state.scenes = state.scenes.filter((item) => item.id !== scene.id);
  state.currentId = state.scenes[0]?.id || null;
  if (currentScene()) populateSceneForm(currentScene());
  renderSceneList();
  showToast("场景已删除");
}

function collectKeywordDefinitions(scene) {
  const definitions = [];
  const seen = new Set();
  const add = (term, note, source) => {
    const cleaned = String(term || "").trim();
    const key = cleaned.toLocaleLowerCase("zh-CN");
    if (!cleaned || seen.has(key)) return;
    seen.add(key);
    definitions.push({ term: cleaned, note: String(note || "").trim(), source });
  };

  add(scene.character?.name, "自己的角色名称", "character");
  for (const alias of splitAliases(scene.character?.aliases)) add(alias, "角色别名", "alias");
  for (const keyword of scene.keywords || []) add(keyword.term, keyword.note, "custom");
  return definitions;
}

function detectKeywords(scene, text) {
  const lower = text.toLocaleLowerCase("zh-CN");
  const matches = [];
  for (const definition of collectKeywordDefinitions(scene)) {
    const needle = definition.term.toLocaleLowerCase("zh-CN");
    let index = 0;
    let count = 0;
    while (needle && index < lower.length) {
      const found = lower.indexOf(needle, index);
      if (found < 0) break;
      count += 1;
      index = found + Math.max(needle.length, 1);
    }
    if (count) matches.push({ ...definition, count });
  }
  return matches.sort((a, b) => b.count - a.count || b.term.length - a.term.length);
}

function renderHighlightedPreview(text, definitions) {
  elements.contextPreview.replaceChildren();
  if (!text.trim()) {
    elements.contextPreview.textContent = "粘贴上下文后，这里会高亮角色名、别名和自定义关键词。";
    return;
  }
  const clipped = text.length > 5000 ? `…${text.slice(-5000)}` : text;
  const terms = definitions
    .map((item) => item.term)
    .filter(Boolean)
    .sort((a, b) => b.length - a.length);
  const lower = clipped.toLocaleLowerCase("zh-CN");
  let cursor = 0;
  let plainStart = 0;

  while (cursor < clipped.length) {
    const term = terms.find((candidate) => lower.startsWith(candidate.toLocaleLowerCase("zh-CN"), cursor));
    if (!term) {
      cursor += 1;
      continue;
    }
    if (cursor > plainStart) {
      elements.contextPreview.append(document.createTextNode(clipped.slice(plainStart, cursor)));
    }
    const mark = document.createElement("mark");
    mark.textContent = clipped.slice(cursor, cursor + term.length);
    elements.contextPreview.append(mark);
    cursor += term.length;
    plainStart = cursor;
  }
  if (plainStart < clipped.length) {
    elements.contextPreview.append(document.createTextNode(clipped.slice(plainStart)));
  }
}

function updateKeywordMonitor() {
  const base = currentScene();
  if (!base) return;
  const scene = buildSceneFromForm();
  const text = elements.chatContext.value;
  const matches = detectKeywords(scene, text);
  elements.keywordChips.replaceChildren();

  if (!text.trim()) {
    const empty = document.createElement("span");
    empty.className = "empty-chip";
    empty.textContent = "尚未检测";
    elements.keywordChips.append(empty);
    elements.keywordSummary.textContent = "等待上下文";
  } else if (!matches.length) {
    const empty = document.createElement("span");
    empty.className = "empty-chip";
    empty.textContent = "未命中已配置关键词";
    elements.keywordChips.append(empty);
    elements.keywordSummary.textContent = "0 个命中";
  } else {
    for (const match of matches) {
      const chip = document.createElement("span");
      chip.className = "keyword-chip";
      chip.title = match.note || "无补充说明";
      chip.append(document.createTextNode(match.term));
      const count = document.createElement("strong");
      count.textContent = `×${match.count}`;
      chip.append(count);
      elements.keywordChips.append(chip);
    }
    const total = matches.reduce((sum, item) => sum + item.count, 0);
    elements.keywordSummary.textContent = `${matches.length} 个词 · ${total} 次命中`;
  }

  renderHighlightedPreview(text, collectKeywordDefinitions(scene));
  elements.contextCount.textContent = String(text.length);
  elements.activeCharacterBadge.textContent = scene.character?.name || "未设置角色";
}

function setGenerating(isGenerating) {
  state.generating = isGenerating;
  elements.generateButton.disabled = isGenerating;
  elements.generateButton.classList.toggle("is-loading", isGenerating);
  elements.generateButton.querySelector("strong").textContent = isGenerating ? "正在组织回复……" : "生成长回复";
  elements.regenerateButton.disabled = isGenerating || !state.lastOutput;
}

function renderOutput(payload) {
  state.lastOutput = payload.text || "";
  elements.outputSection.classList.remove("is-empty");
  elements.outputTitle.textContent = payload.demo ? "演示草稿" : "模型草稿";
  elements.outputText.textContent = payload.text;
  elements.outputMeta.replaceChildren();
  const meta = [
    payload.model,
    `${Math.max(0, Number(payload.elapsedMs || 0) / 1000).toFixed(1)} 秒`,
    `${payload.matches?.length || 0} 个关键词`,
    `${payload.text?.length || 0} 字符`,
  ];
  for (const item of meta) {
    const chip = document.createElement("span");
    chip.textContent = item;
    elements.outputMeta.append(chip);
  }
  elements.copyButton.disabled = false;
  elements.regenerateButton.disabled = false;
  if (payload.demo) showToast("当前是演示生成；设置 API Key 后可调用在线模型");
}

async function generateReply() {
  if (state.generating) return;
  const chatText = elements.chatContext.value.trim();
  if (!chatText) {
    showToast("请先粘贴聊天上下文", "error");
    elements.chatContext.focus();
    return;
  }
  try {
    if (state.dirty) await saveCurrentScene({ quiet: true });
    setGenerating(true);
    elements.outputSection.classList.remove("is-empty");
    elements.outputTitle.textContent = "正在生成";
    elements.outputText.textContent = "助手正在结合规则、角色设定、关键词和最近聊天组织回复……";
    elements.outputMeta.replaceChildren();
    const payload = await fetchJson("/api/generate", {
      method: "POST",
      body: JSON.stringify({
        sceneId: state.currentId,
        chatText,
        goal: elements.replyGoal.value,
        mode: elements.replyMode.value,
        length: elements.replyLength.value,
        model: elements.modelSelect.value,
        extraConstraints: elements.extraConstraints.value,
      }),
    });
    renderOutput(payload);
  } catch (error) {
    elements.outputTitle.textContent = "生成失败";
    elements.outputText.textContent = error.message;
    showToast(error.message, "error");
  } finally {
    setGenerating(false);
  }
}

async function copyOutput() {
  if (!state.lastOutput) return;
  try {
    await navigator.clipboard.writeText(state.lastOutput);
    elements.copyButton.textContent = "已复制";
    window.setTimeout(() => { elements.copyButton.textContent = "复制"; }, 1600);
  } catch {
    showToast("无法访问剪贴板，请手动选择文本复制", "error");
  }
}

function bindTabs() {
  for (const button of document.querySelectorAll(".tab-button")) {
    button.addEventListener("click", () => {
      for (const item of document.querySelectorAll(".tab-button")) {
        item.classList.toggle("is-active", item === button);
      }
      for (const panel of document.querySelectorAll(".tab-panel")) {
        const active = panel.dataset.panel === button.dataset.tab;
        panel.classList.toggle("is-active", active);
        panel.hidden = !active;
      }
    });
  }
}

function bindEvents() {
  elements.sceneForm.addEventListener("submit", (event) => event.preventDefault());
  elements.sceneForm.addEventListener("input", () => {
    setDirty(true);
    const draft = buildSceneFromForm();
    elements.currentSceneHeading.textContent = draft.name || "未命名场景";
    updateCounters();
    updateKeywordMonitor();
  });
  elements.chatContext.addEventListener("input", updateKeywordMonitor);
  elements.newSceneButton.addEventListener("click", () => createScene().catch((error) => showToast(error.message, "error")));
  elements.saveSceneButton.addEventListener("click", () => saveCurrentScene().catch((error) => showToast(error.message, "error")));
  elements.duplicateSceneButton.addEventListener("click", () => duplicateScene().catch((error) => showToast(error.message, "error")));
  elements.deleteSceneButton.addEventListener("click", () => deleteScene().catch((error) => showToast(error.message, "error")));
  elements.generateButton.addEventListener("click", generateReply);
  elements.regenerateButton.addEventListener("click", generateReply);
  elements.copyButton.addEventListener("click", copyOutput);
  window.addEventListener("beforeunload", (event) => {
    if (!state.dirty) return;
    event.preventDefault();
    event.returnValue = "";
  });
  bindTabs();
}

async function initialize() {
  bindEvents();
  try {
    const [status, scenePayload] = await Promise.all([
      fetchJson("/api/status"),
      fetchJson("/api/scenes"),
    ]);
    state.status = status;
    state.scenes = scenePayload.scenes || [];
    state.currentId = state.scenes[0]?.id || null;
    renderStatus();
    if (status.models?.includes(status.defaultModel)) elements.modelSelect.value = status.defaultModel;
    renderSceneList();
    if (currentScene()) populateSceneForm(currentScene());
  } catch (error) {
    renderStatus();
    showToast(`初始化失败：${error.message}`, "error");
  }
}

initialize();
