// 给邀请填写页拍截图，人工看一眼"长得对不对"。
//
// ## 为什么 DOM 断言不够
//
// `check-invite-page.mjs` 已经能证明四道题渲染出来了、能提交、没有 JS 异常。
// 但这个项目反复验证过一件事：**结构对不等于看起来对**。
// 之前 App 端就出现过"断言全绿但按钮被浮动 tab bar 切掉一半"的情况。
//
// 网页这边同样可能出问题：字号太小、卡片挤在一起、
// 深色下文字与背景对比度不够、刘海屏底部被系统手势条压住。
// 这些只有看图能判断。
//
// 用法：node Tools/watchdog/shoot-invite-page.mjs [输出目录]
import { createServer } from "node:http";
import { readFileSync, mkdirSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolve } from "node:path";

const outDir = resolve(process.argv[2] || "/tmp/invite-shots");
mkdirSync(outDir, { recursive: true });

const root = new URL("../../", import.meta.url).pathname;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const src = readFileSync(join(root, "Tools/ai-proxy/invite.js"), "utf8");
const s = src.indexOf("function renderInvitePage");
const b = src.slice(s);
const t = b.indexOf("return `") + 8;
const e = b.indexOf("</html>`") + 7;
const html = b.slice(t, e);

const server = createServer((req, res) => {
  if (/\/claim$/.test(req.url)) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ slot: "b" }));
    return;
  }
  if (/\/page/.test(req.url)) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
    return;
  }
  if (req.url === "/favicon.ico") { res.writeHead(204); res.end(); return; }
  res.writeHead(404); res.end("x");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
// caseId 必须满足页面的校验（16-64 位 base64url 字符）。
// 第一版用了 `shootcaseid0001`（15 位），页面正确地拒绝了它并显示
// "链接不完整，请让对方重新发一次" —— 截图里看到的就是这句。
// 那是截图脚本的错，不是页面的错：这反倒印证了校验是有效的。
const pageURL = `http://127.0.0.1:${port}/v1/invite/shootcaseid000001/page#${"A".repeat(43)}`;

const cdpPort = 9700 + Math.floor(Math.random() * 200);
const chrome = spawn(CHROME, [
  "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run",
  "--no-default-browser-check", "--hide-scrollbars",
  `--remote-debugging-port=${cdpPort}`,
  `--user-data-dir=${join(tmpdir(), "rc-shoot-" + process.pid)}`,
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
if (!wsUrl) { chrome.kill("SIGKILL"); server.close(); console.error("CDP 未就绪"); process.exit(1); }

const ws = new WebSocket(wsUrl);
await new Promise((r) => ws.addEventListener("open", r));
let msgId = 0;
const send = (method, params) => new Promise((res) => {
  const id = ++msgId;
  const h = (ev) => { const d = JSON.parse(ev.data); if (d.id === id) { ws.removeEventListener("message", h); res(d); } };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id, method, params: params || {} }));
});

await send("Page.enable");

// iPhone 尺寸，带设备像素比 —— 目标和真实使用最接近的一档
async function shoot(name, opts) {
  const { width = 390, height = 844, dark = false, fullPage = true } = opts || {};
  await send("Emulation.setDeviceMetricsOverride", {
    width, height, deviceScaleFactor: 2, mobile: true,
  });
  await send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-color-scheme", value: dark ? "dark" : "light" }],
  });
  await send("Page.navigate", { url: pageURL });
  await sleep(2200);

  if (fullPage) {
    // 整页高度：把内容实际高度读出来，避免只截首屏看不到后面几题
    const m = await send("Runtime.evaluate", {
      expression: "Math.ceil(document.documentElement.scrollHeight)",
      returnByValue: true,
    });
    const h = Math.min(m.result.result.value || height, 4000);
    await send("Emulation.setDeviceMetricsOverride", {
      width, height: h, deviceScaleFactor: 2, mobile: true,
    });
    await sleep(400);
  }

  const shot = await send("Page.captureScreenshot", { format: "png" });
  const { writeFileSync } = await import("node:fs");
  writeFileSync(join(outDir, name + ".png"), Buffer.from(shot.result.data, "base64"));
  console.log("  ✓", name + ".png");
}

console.log("截图输出到", outDir);
await shoot("invite-light", { dark: false });
await shoot("invite-dark", { dark: true });
// 小屏机型：iPhone SE 宽度，最容易暴露横向挤压
await shoot("invite-light-narrow", { dark: false, width: 320 });

chrome.kill("SIGKILL");
server.close();
