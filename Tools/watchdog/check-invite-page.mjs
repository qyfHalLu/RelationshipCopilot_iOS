// 检查邀请填写页真的在浏览器里跑起来，并把四道题渲染出来。
//
// ## 为什么这个文件存在（这是本项目最贵的一次教训）
//
// 上一轮我用无头 Chrome 的 `--dump-dom` 截图，看到页面只有标题、
// 四个问题一个都没有。当时以为是 `file://` 的锅、或者样式问题，
// 差点去"修"一个不存在的东西。
//
// 真因是：`invite.js` 里的 JS 写在**模板字符串**中，有一处写成了 `\\/`，
// 求值后浏览器收到 `/\\/v1\\/…/` —— 正则提前闭合，
// 整个 `<script>` 抛 `SyntaxError: Invalid regular expression flags`，
// **一行 JS 都没执行**。
//
// 而当时所有测试都是绿的：`invite.test.mjs` 只读源码字符串，
// Swift 端只测自己的加密与状态机，**没有人真的把页面放进浏览器跑一次**。
// "读源码"和"浏览器执行"之间，隔着模板字符串转义、CSP、WebCrypto 可用性
// 这三层，任何一层都能让页面彻底空白。
//
// 所以这个检查必须用 CDP 真的执行页面，而不是 dump HTML：
// `--dump-dom` 拿到的是**未执行 JS 的初始 DOM**，长度和源文件一模一样，
// 看上去"页面加载正常"，实际上什么都没发生。
//
// ## 三层各自验什么
//
//   1. 源码层：QUESTIONS 有几题
//   2. 执行层：页面在真实 HTTP 路径下跑起来，没有 JS 异常
//   3. 结果层：DOM 里真的出现了对应数量的题目卡片、提交按钮、密封说明
//
// 再加一条反向场景：claim 返回 409（链接已提交）时必须有明确提示，
// 不能是空白 —— 用户会以为链接坏了。
import { createServer } from "node:http";
import { readFileSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("../../", import.meta.url).pathname;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const fail = (msg) => { console.error(`✗ ${msg}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- 1. 源码层 ----
const src = readFileSync(join(root, "Tools/ai-proxy/invite.js"), "utf8");
const qStart = src.indexOf("var QUESTIONS");
const qBlock = src.slice(qStart, src.indexOf("];", qStart) + 2);
const qIds = [...qBlock.matchAll(/id:\s*"(\w+)"/g)].map((m) => m[1]);
if (qIds.length !== 4) fail(`QUESTIONS 应为 4 题（与 App 端一致），实际 ${qIds.length}`);

const tmplStart = src.indexOf("return `", src.indexOf("function renderInvitePage"));
const tmplEnd = src.indexOf("</html>`") + 7;
const tmpl = src.slice(tmplStart, tmplEnd);

// 这里**故意不做**「扫描源码找坏正则」的静态检查。
//
// 试过两版，都被自己的注释误伤：问题说明必须引用那几个反斜杠，
// 而注释和真代码在文本上完全一样，只有语法位置能区分。
// 用文本模式去代理"代码能不能跑"，本身就是错层的指标。
//
// 真正的判据在下面：**把页面放进浏览器执行，看有没有 JS 异常。**
// 语法错误、WebCrypto 缺失、CSP 拦截，全都会被那一条抓住，
// 不需要为每种成因各写一条猜测式的模式匹配。

// ---- 2. 起服务，模拟真实端点 ----
const htmlStart = tmpl.indexOf("`") + 1;
const html = tmpl.slice(htmlStart, tmpl.length - 7);
if (!html.includes("<!DOCTYPE")) fail("renderInvitePage 没有返回完整 HTML");

const caseId = "watchdogcaseid0001";
const keyB64 = "A".repeat(43);
let claimMode = "ok";

const server = createServer((req, res) => {
  if (/^\/v1\/invite\/[A-Za-z0-9_-]{16,64}\/claim$/.test(req.url)) {
    if (claimMode === "conflict") {
      res.writeHead(409, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "这个链接已经提交过了" }));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ slot: "b" }));
    return;
  }
  if (/^\/v1\/invite\/[A-Za-z0-9_-]{16,64}\/page/.test(req.url)) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
    return;
  }
  if (req.url === "/favicon.ico") { res.writeHead(204); res.end(); return; }
  res.writeHead(404); res.end("nope");
});

await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
const pageURL = `http://127.0.0.1:${port}/v1/invite/${caseId}/page#${keyB64}`;

// ---- 3. 用 CDP 真的执行页面 ----
const cdpPort = 9400 + Math.floor(Math.random() * 400);
const chrome = spawn(CHROME, [
  "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run",
  "--no-default-browser-check",
  `--remote-debugging-port=${cdpPort}`,
  `--user-data-dir=${join(tmpdir(), "rc-inv-" + process.pid)}`,
  "about:blank",
], { stdio: "ignore" });

let wsUrl = null;
for (let i = 0; i < 60 && !wsUrl; i++) {
  await sleep(250);
  try {
    const list = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
    const tgt = list.find((x) => x.type === "page");
    if (tgt) wsUrl = tgt.webSocketDebuggerUrl;
  } catch {}
}
if (!wsUrl) { chrome.kill("SIGKILL"); server.close(); fail("CDP 未就绪，无法验证页面"); }

const ws = new WebSocket(wsUrl);
await new Promise((r) => ws.addEventListener("open", r));

let msgId = 0;
const send = (method, params) => new Promise((res) => {
  const id = ++msgId;
  const h = (ev) => {
    const d = JSON.parse(ev.data);
    if (d.id === id) { ws.removeEventListener("message", h); res(d); }
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id, method, params: params || {} }));
});

const jsErrors = [];
ws.addEventListener("message", (ev) => {
  const d = JSON.parse(ev.data);
  if (d.method === "Runtime.exceptionThrown") {
    jsErrors.push(d.params.exceptionDetails.exception?.description
      || d.params.exceptionDetails.text);
  }
});

await send("Runtime.enable");
await send("Page.enable");
await send("Page.navigate", { url: pageURL });
await sleep(3000);

const probe = await send("Runtime.evaluate", {
  expression: `JSON.stringify({
    status: (document.getElementById("status")||{}).textContent || "",
    textareas: document.querySelectorAll("textarea").length,
    cards: document.querySelectorAll(".card").length,
    submit: !!document.getElementById("submit"),
    bodyText: document.body.innerText
  })`,
  returnByValue: true,
});

const state = JSON.parse(probe.result.result.value);

// 执行层：有任何 JS 异常都算失败 —— 因为异常会让整段脚本停摆
if (jsErrors.length) {
  chrome.kill("SIGKILL"); server.close();
  fail(`页面执行时抛异常，整段 JS 已停摆：\n  ${jsErrors[0].split("\n")[0]}`);
}

// 结果层
if (state.textareas !== qIds.length || state.cards !== qIds.length) {
  chrome.kill("SIGKILL"); server.close();
  fail(`只渲染出 ${state.textareas} 个输入框 / ${state.cards} 张卡片，应为 ${qIds.length}`
    + `\n  页面状态栏写的是：${JSON.stringify(state.status)}`);
}
if (!state.submit) fail("没有渲染出提交按钮");
if (!/看不到/.test(state.bodyText)) {
  fail("页面上没有『对方看不到你写的』这句说明 —— 密封承诺没有告知对方");
}
if (!state.bodyText.includes("提交我这一份")) fail("提交按钮文案缺失");

// ---- 3b. 配色：两套主题下的对比度必须真的够 ----
//
// ## 为什么必须测这一层
//
// 上面那些断言全绿的时候，浅色模式下的页面其实是**不能用的**：
// 卡片和输入框还是深色（`#16161c` / `#0f0f14`），而文字被浅色主题染成了
// `#1c1c22` —— 题号和用户自己敲的字都压成了"深色叠深色"，肉眼几乎看不见。
//
// 根因是 CSS 顺序：`@media (prefers-color-scheme: light)` 覆盖块写在
// `.card` / `textarea` / `.hint` 的深色规则之前，特异性相同 → 后写的深色赢。
// 只有 `body` 生效（它后面没有同名规则），所以页面"看起来变了色"，
// 但变的只有背景 —— 这恰好是最容易骗过一眼扫过的形态。
//
// **DOM 断言对此完全无能为力**：元素都在、数量都对、文案都对。
// 必须读计算样式，而且必须默认把两套主题都跑一遍 ——
// 只测深色等于没测浅色，而这份链接大多数人是白天在微信里打开的。
const CONTRAST_PAIRS = [
  { name: "正文", fg: "body", bg: "body", min: 4.5 },
  { name: "题号", fg: "label", bg: ".card", min: 4.5 },
  { name: "提示语", fg: ".hint", bg: ".card", min: 4.5 },
  { name: "输入框文字", fg: "textarea", bg: "textarea", min: 4.5 },
  { name: "提交按钮", fg: "#submit", bg: "#submit", min: 4.5 },
];

// 对比度计算放在页面里做，避免把颜色字符串搬出来自己解析。
// 关键点：解析失败**不返回 null 静默跳过**，而是抛错 ——
// 本项目吃过"样本为 0 时断言恒真"的亏，宁可炸也不要假绿。
const contrastExpr = `
(function (pairs) {
  function toRGB(s) {
    var m = s.match(/rgba?\\(([^)]+)\\)/);
    if (!m) throw new Error("无法解析颜色：" + s);
    var p = m[1].split(",").map(function (x) { return parseFloat(x); });
    return [p[0], p[1], p[2]];
  }
  function lum(rgb) {
    var c = rgb.map(function (v) {
      v = v / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function ratio(a, b) {
    var l1 = lum(a), l2 = lum(b);
    if (l1 < l2) { var t = l1; l1 = l2; l2 = t; }
    return (l1 + 0.05) / (l2 + 0.05);
  }
  var out = [];
  pairs.forEach(function (p) {
    var fe = document.querySelector(p.fg), be = document.querySelector(p.bg);
    if (!fe || !be) throw new Error("找不到元素：" + p.fg + " / " + p.bg);
    var fg = toRGB(getComputedStyle(fe).color);
    var bg = toRGB(getComputedStyle(be).backgroundColor);
    out.push({ name: p.name, ratio: Math.round(ratio(fg, bg) * 100) / 100, min: p.min });
  });
  return JSON.stringify(out);
})(${JSON.stringify(CONTRAST_PAIRS)})
`;

const contrastResults = {};
for (const scheme of ["dark", "light"]) {
  await send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-color-scheme", value: scheme }],
  });
  // 换 caseId 强制真重载：只改 fragment / 只改媒体特性都可能不重载
  await send("Page.navigate", { url: `http://127.0.0.1:${port}/v1/invite/contrast${scheme}case01/page#${keyB64}` });
  await sleep(2000);
  const r = await send("Runtime.evaluate", { expression: contrastExpr, returnByValue: true });

  if (r.result.exceptionDetails) {
    chrome.kill("SIGKILL"); server.close();
    fail(`${scheme} 主题下读不到颜色：${r.result.exceptionDetails.exception?.description?.split("\n")[0]}`);
  }
  // 样本数下限：五组颜色一组都不能少，否则循环里的比较可能一个都没跑
  const rows = JSON.parse(r.result.result.value);
  if (rows.length !== CONTRAST_PAIRS.length) {
    chrome.kill("SIGKILL"); server.close();
    fail(`${scheme} 主题下只量到 ${rows.length} 组颜色，应为 ${CONTRAST_PAIRS.length} 组`);
  }
  contrastResults[scheme] = rows;

  for (const row of rows) {
    if (row.ratio < row.min) {
      chrome.kill("SIGKILL"); server.close();
      fail(`${scheme} 主题下「${row.name}」对比度只有 ${row.ratio}:1，低于 ${row.min}:1 —— 看起来是能读的，实际读不了`);
    }
  }
}

// 还原媒体特性，后面的反向场景按默认深色走
await send("Emulation.setEmulatedMedia", { features: [] });

// ---- 4. 反向场景：claim 409 ----
//
// **必须换一个 pathname，不能只改 fragment。**
// 第一版写成 `navigate(pageURL + "&again=1")` —— 那只是给 fragment
// 多加了一段，pathname 没变，Chrome 判定为同页锚点跳转，
// **根本不重新加载**，于是读到的还是上一次成功渲染的 DOM，
// 断言报"没有提示已提交"，而实际行为完全正确。
//
// 这类错误的共同点：测试自己的动作没生效，却把结果算在代码头上。
// 换个 caseId 是最省事也最不会骗人的做法。
claimMode = "conflict";
await send("Page.navigate", { url: `http://127.0.0.1:${port}/v1/invite/conflictcaseid0001/page#${keyB64}` });
await sleep(2500);
const probe409 = await send("Runtime.evaluate", {
  expression: `document.body.innerText`,
  returnByValue: true,
});
const text409 = probe409.result.result.value;
if (!/已经提交过/.test(text409)) {
  chrome.kill("SIGKILL"); server.close();
  fail("链接已提交（claim 409）时页面没有提示「已经提交过」，用户会看到空白以为链接坏了");
}
// 已提交时不应该再渲染表单 —— 否则用户白白填一遍才发现提交不了
const ta409 = await send("Runtime.evaluate", {
  expression: `document.querySelectorAll("textarea").length`,
  returnByValue: true,
});
if (ta409.result.result.value > 0) {
  chrome.kill("SIGKILL"); server.close();
  fail("链接已提交时仍渲染了输入框 —— 用户会白填一遍才发现提交不了");
}

// ---- 5. 降级环境：没有 WebCrypto 时必须给中文指引，而不是抛异常 ----
//
// 这是**真实会遇到的场景**，不是假想：
// 微信等 App 内置浏览器可能裁掉 `crypto.subtle`，或页面被 http 打开时
// 根本不是安全上下文。那种情况下如果直接调 `crypto.subtle.importKey`，
// 会抛 TypeError —— 而这一步发生在提交时，用户已经写完四个题了。
//
// 用 `Page.addScriptToEvaluateOnNewDocument` 在页面脚本之前把 crypto.subtle 抹掉，
// 精确模拟这种环境。这比"读代码觉得没问题"可靠得多。
claimMode = "ok";
await send("Page.addScriptToEvaluateOnNewDocument", {
  source: `try {
    Object.defineProperty(crypto, "subtle", { value: undefined, configurable: true });
  } catch (e) {}
  try { Object.defineProperty(window, "isSecureContext", { value: false, configurable: true }); } catch (e) {}`,
});
await send("Page.navigate", { url: `http://127.0.0.1:${port}/v1/invite/nocryptocaseid001/page#${keyB64}` });
await sleep(2500);

const probeNoCrypto = await send("Runtime.evaluate", {
  expression: `JSON.stringify({
    bodyText: document.body.innerText,
    textareas: document.querySelectorAll("textarea").length,
    hasNoCryptoError: /不支持|https 打开/.test(document.body.innerText)
  })`,
  returnByValue: true,
});
const noCrypto = JSON.parse(probeNoCrypto.result.result.value);

if (!noCrypto.hasNoCryptoError) {
  chrome.kill("SIGKILL"); server.close();
  fail("浏览器没有 WebCrypto 时页面没有给出中文指引 —— 用户只会看到空白或技术错误");
}
if (noCrypto.textareas > 0) {
  chrome.kill("SIGKILL"); server.close();
  fail("浏览器没有 WebCrypto 时仍然渲染了输入框 —— 用户写完四个题才发现提交不了，内容全丢");
}

writeFileSync(join(tmpdir(), "invite-page-check.html"), html);
chrome.kill("SIGKILL");
server.close();
const fmt = (rows) => rows.map((r) => `${r.name} ${r.ratio}`).join(" / ");
console.log(`${qIds.length} 题在浏览器里真实渲染；409 有明确提示；无 WebCrypto 时有中文指引；JS 无异常`);
console.log(`  对比度 dark：${fmt(contrastResults.dark)}`);
console.log(`  对比度 light：${fmt(contrastResults.light)}`);
