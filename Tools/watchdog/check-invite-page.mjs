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

writeFileSync(join(tmpdir(), "invite-page-check.html"), html);
chrome.kill("SIGKILL");
server.close();
console.log(`${qIds.length} 题在浏览器里真实渲染；409 有明确提示；JS 无异常`);
