/**
 * 关系副驾 · 评理邀请（Cloudflare Worker 模块）
 *
 * ## 这个文件解决什么
 *
 * 原来「把一件事说清」只能**同一台手机**上两个人轮流写（`DisputeMode.sameDevice`）。
 * 但现实里很多矛盾是远程发生的 —— 异地、冷战、对方在另一个城市。
 * 用户原话：「不要在同一部手机里说清，可以生成微信或者 App 邀请链接给另一方，
 * 让对方在自己的终端上填写。」
 *
 * 于是需要一块**中转的公共白板**：A 写完 → 生成链接 → B 在任意设备打开填写 →
 * A 端取回。这块白板必须有服务端，纯本机做不到。
 *
 * ## 最重要的设计约束：服务端**读不懂**内容
 *
 * 邀请链接会经过微信、短信、各种剪贴板。如果 URL 里带证词，等于把最私密的内容
 * 明文贴在聊天记录里。所以：
 *
 *   · URL 里只有 `caseId`（随机 16 字节）和 `key`（随机 32 字节，在 **#** 后面）——
 *     `#` 之后的部分**不会发到服务器**，也不会进 Referer / 日志。
 *   · 证词由客户端用 `key` 做 AES-GCM 加密后才 `PUT` 上来。
 *   · 服务端存的是一坨它解不开的密文。它只负责"保管"和"到时候交还"。
 *
 * 因此本文件里**没有任何解密逻辑**，也不需要任何加密密钥环境变量。
 * 这不是偷懒，是让"服务端看不到内容"成为结构上的事实，而不是承诺。
 *
 * ## 存储
 *
 * 用 Workers KV（`INVITE_KV`）。选它而不是 D1 的理由：这只是一次性的、
 * 带 TTL 的键值对，没有查询需求，也没有关联关系。KV 的 TTL 由平台负责删除，
 * 免掉"忘了写过期清理"这类必然发生的疏漏。
 *
 * **KV 不是强一致的。** 它对"写完立刻读"有最长约 60 秒的延迟，
 * 所以客户端取不到时要能重试，而不是判定"对方没写"。
 * 这里刻意不做 read-after-write 的就近缓存，宁可让客户端多轮询一次。
 *
 * ## 反滥用
 *
 * 白板是公开可写的（对方没有账号），所以必须限：
 *   · 单个 caseId 最多 2 份证词（A / B），写满即封。
 *   · 单份密文 ≤ 64KB（四题各 200 字，正常不足 5KB）。
 *   · TTL 7 天，到期自动消失。
 *   · 每次写入按 IP 限频，复用 `worker.js` 的 `checkQuota`。
 */

const INVITE_TTL_SECONDS = 7 * 24 * 3600;
const MAX_CIPHERTEXT_BYTES = 64 * 1024;
/** 一个 caseId 只接受两个写入者（A / B）。多出来的拒绝，避免被当免费存储用。 */
const MAX_SLOTS = 2;

/** caseId 是客户端生成的随机串，只允许 URL 安全字符，防路径穿越与 KV 键污染。 */
const CASE_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extraHeaders,
    },
  });
}

function fail(message, status = 400) {
  return json({ error: { message } }, status);
}

function keyFor(caseId, slot) {
  return `invite:${caseId}:${slot}`;
}

/** 该案卷已收到几份证词。只读元信息，不含密文。 */
async function readSlots(kv, caseId) {
  const [a, b] = await Promise.all([
    kv.get(keyFor(caseId, "a")),
    kv.get(keyFor(caseId, "b")),
  ]);
  return { a: a !== null, b: b !== null };
}

/**
 * `POST /v1/invite/:caseId/claim`
 *
 * 领取一个空位。返回 `slot`（"a" / "b"）。
 *
 * ## 为什么 `slot` 必须可以由调用方指定
 *
 * 早先这里是"谁先来谁拿 a"的自动分配。那个设计在**本方**（发起方）
 * 也写一份的模型下成立，但在当前流程里是错的：
 *
 *   A 的证词本来就在 A 手机的数据库里，**从不上送服务器**。
 *   所以服务器上只会有"对方"这一份。而自动分配会让对方拿到 `a`，
 *   而 A 端只读 `testimonies["b"]` —— 结果是：
 *   对方那边显示"已提交"，A 这边永远显示"TA 还没写"，且两边都没有报错。
 *
 * 所以对方网页固定领 `b`（见 `renderInvitePage` 里的 claim 调用）。
 * 不传 `slot` 时保留自动分配，供将来"双方都写"的形态使用。
 *
 * ## 重复领取是允许的
 *
 * `b` 已被领取但**还没写**时，再次 claim 仍然返回 200 和同一个 slot。
 * 因为对方可能提交前刷新了页面 —— 若在这里回 409，
 * 他会被自己的占位挡在门外，写了一半的内容直接丢掉。
 *
 * 真正的并发保护在 `handlePut`：写入过的东西不可覆盖，
 * 第二个人提交时会拿到明确的 409，而不是静默把第一个人的话换掉。
 */
async function handleClaim(caseId, kv, requestedSlot) {
  if (requestedSlot !== undefined && requestedSlot !== null) {
    if (requestedSlot !== "a" && requestedSlot !== "b") {
      return fail("slot 只能是 a 或 b", 400);
    }
    const existing = await kv.get(keyFor(caseId, requestedSlot));
    // 已经写过内容：这个链接对下一个人来说确实失效了。
    if (existing !== null && existing !== "") {
      return fail("这个链接已经提交过了", 409);
    }
    // 未领取 或 已领取未写：都放行，占位可重复写入。
    await kv.put(keyFor(caseId, requestedSlot), "", { expirationTtl: INVITE_TTL_SECONDS });
    return json({ slot: requestedSlot });
  }

  const slots = await readSlots(kv, caseId);

  // A 先来：`a` 空就用 a。
  if (!slots.a) {
    await kv.put(keyFor(caseId, "a"), "", { expirationTtl: INVITE_TTL_SECONDS });
    return json({ slot: "a" });
  }
  // A 已占，B 空就给 b。
  if (!slots.b) {
    await kv.put(keyFor(caseId, "b"), "", { expirationTtl: INVITE_TTL_SECONDS });
    return json({ slot: "b" });
  }
  return fail("这个邀请已经有两份回复了，链接已失效", 409);
}

/**
 * `PUT /v1/invite/:caseId/:slot`
 *
 * 写入一份密文。body 是 `{ ciphertext, iv }`（都 base64）。
 *
 * **不接受"覆盖已有内容"**：`if (existing)` 就拒绝。
 * 覆盖在这里没有任何合理用途，只会让"我的证词被换掉了"成为可能。
 */
async function handlePut(caseId, slot, body, kv) {
  if (slot !== "a" && slot !== "b") {
    return fail("slot 只能是 a 或 b", 400);
  }

  const ciphertext = typeof body?.ciphertext === "string" ? body.ciphertext : "";
  const iv = typeof body?.iv === "string" ? body.iv : "";

  if (!ciphertext || !iv) return fail("ciphertext 与 iv 都不能为空", 400);
  if (ciphertext.length > MAX_CIPHERTEXT_BYTES) {
    return fail("内容过长", 413);
  }

  const existing = await kv.get(keyFor(caseId, slot));
  // 空串是 `claim` 留下的占位。只有占位才能写。
  if (existing === null) return fail("请先领取这个位置", 409);
  if (existing !== "") return fail("这个位置已经写过了", 409);

  await kv.put(
    keyFor(caseId, slot),
    JSON.stringify({ ciphertext, iv, writtenAt: Date.now() }),
    { expirationTtl: INVITE_TTL_SECONDS }
  );

  return json({ ok: true });
}

/**
 * `GET /v1/invite/:caseId`
 *
 * 取回**已经写好的**证词。`slots` 告诉调用方还差哪一份。
 *
 * 只返回已完成的槽位，未写的槽位不出现在 `testimonies` 里 ——
 * 这样客户端能区分"对方还没写"（键不存在）和"对方写了空内容"（不会发生，
 * 因为 `PUT` 拒绝空 ciphertext）。
 */
async function handleGet(caseId, kv) {
  const [a, b] = await Promise.all([
    kv.get(keyFor(caseId, "a")),
    kv.get(keyFor(caseId, "b")),
  ]);

  const testimonies = {};
  for (const [slot, raw] of [["a", a], ["b", b]]) {
    if (!raw) continue; // 未领取或已领取未写入
    try {
      testimonies[slot] = JSON.parse(raw);
    } catch {
      // 坏数据当不存在。宁可让客户端多等一次，也不要回半截 JSON。
      continue;
    }
  }

  return json({
    slots: { a: a !== null, b: b !== null },
    // 「还需要谁来写」由服务端算好，避免客户端各自实现一遍判定。
    awaiting: [a === "" ? "a" : null, b === "" ? "b" : null].filter(Boolean),
    testimonies,
  });
}

/**
 * `GET /v1/invite/:caseId/page`
 *
 * 对方在**浏览器**里填写用的极简页面（微信 / 短信里点开）。
 *
 * ## 为什么这个页面必须在服务端渲染
 *
 * 对方大概率没装 App。要让"点开链接就能写"，只能给一个网页。
 * 而这个网页必须在**浏览器里完成加密** —— 明文绝不能发给服务器。
 * 所以页面内嵌的 JS 用 WebCrypto 做 AES-GCM，与服务端完全无关。
 *
 * `key` 从 URL 的 `#` 后面读，**不会出现在 HTTP 请求里**。
 * 这一点是这个方案成立的全部前提：如果 key 走 query string，
 * 它会进 Cloudflare 日志、进浏览器历史、进聊天软件的链接预览抓取。
 */
function renderInvitePage() {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>有一件事想请你一起说清</title>
<style>
  :root { color-scheme: dark light; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 20px 48px;
    font: 16px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
    background: #0b0b0f; color: #ececf1;
    max-width: 640px; margin-inline: auto;
  }
  @media (prefers-color-scheme: light) {
    body { background: #f7f7fa; color: #1c1c22; }
    .card { background: #fff; border-color: #e3e3ea; }
    textarea { background: #fafafc; border-color: #dcdce4; color: #1c1c22; }
    .hint { color: #6b6b76; }
  }
  h1 { font-size: 20px; line-height: 1.5; margin: 0 0 8px; }
  .lede { color: #9a9aa6; font-size: 14px; margin: 0 0 24px; }
  .card {
    background: #16161c; border: 1px solid #26262f; border-radius: 14px;
    padding: 20px; margin-bottom: 16px;
  }
  label { display: block; font-weight: 600; margin-bottom: 8px; font-size: 15px; }
  .hint { color: #8a8a96; font-size: 13px; margin: 0 0 10px; }
  textarea {
    width: 100%; min-height: 96px; padding: 12px; font: inherit; font-size: 15px;
    background: #0f0f14; border: 1px solid #2a2a34; border-radius: 10px;
    color: inherit; resize: vertical;
  }
  textarea:focus { outline: 2px solid #6c5ce7; outline-offset: 1px; }
  button {
    width: 100%; padding: 15px; font: inherit; font-weight: 600;
    background: #6c5ce7; color: #fff; border: 0; border-radius: 12px;
    margin-top: 8px; cursor: pointer;
  }
  button:disabled { opacity: .5; cursor: default; }
  .quick {
    width: auto; padding: 8px 14px; margin-top: 10px;
    font-size: 14px; font-weight: 500;
    background: transparent; color: #6c5ce7;
    border: 1px solid #6c5ce7; border-radius: 999px;
  }
  .status { margin-top: 16px; font-size: 14px; color: #9a9aa6; text-align: center; }
  .done { text-align: center; padding: 40px 0; }
  .done h2 { font-size: 18px; margin: 0 0 8px; }
</style>
</head>
<body>
  <div id="app">
    <h1>有一件事想请你一起说清</h1>
    <p class="lede">对方先用这个方式写了自己那一份。你写的这份在 TA 提交之前，TA 看不到。</p>
    <div id="form"></div>
    <div class="status" id="status"></div>
  </div>
<script>
(function () {
  "use strict";

  // caseId 来自路径；key 来自 # 之后 —— 后者永远不会出现在 HTTP 请求里。
  //
  // ## 下面这条正则的反斜杠，一个都不能多
  //
  // 这段 JS 整个写在模板字符串里。模板字符串会把 \\ 求值成一个 \
  // 所以这里写 \\/ 的话，浏览器收到的是「两个反斜杠 + 斜杠」——
  // 而「两个反斜杠」在正则里表示"匹配一个反斜杠"，
  // 它后面那个斜杠就提前把正则字面量闭合了，紧跟的 v1 被当成修饰符：
  //   SyntaxError: Invalid regular expression flags
  //
  // 后果不是这一句报错，而是**整段脚本一行都不执行**：
  // 页面只剩标题和一行说明，四个问题一个都不渲染，
  // 对方打开链接看到的就是一片空白。
  //
  // 更值得记住的是这件事**不可能靠读源码的测试发现** ——
  // 转义只在"模板字符串求值 + 浏览器解析"这两步之后才现形。
  // 所以必须有一条真的把页面放进浏览器执行的检查
  // （Tools/watchdog/check-invite-page.mjs），
  // 它会直接报出上面那句 SyntaxError。
  //
  // 另外：模板字符串里绝对不能出现反引号，注释里也不行 ——
  // 那一轮我就是用反引号把这几个反斜杠括起来，结果把整个字符串切断了，
  // 报的是 SyntaxError: Invalid or unexpected token。
  var m = location.pathname.match(/\/v1\/invite\/([A-Za-z0-9_-]{16,64})\/page/);
  var caseId = m && m[1];
  var keyB64 = location.hash.replace(/^#/, "");

  var statusEl = document.getElementById("status");
  var formEl = document.getElementById("form");

  function setStatus(t) { statusEl.textContent = t || ""; }

  if (!caseId) { setStatus("链接不完整，请让对方重新发一次。"); return; }
  if (!keyB64) {
    setStatus("这个链接缺少密钥部分，可能是被截断了。请让对方复制完整链接再发一次。");
    return;
  }

  // ---- 加密（WebCrypto，全在浏览器本地完成） ----
  function b64ToBytes(b64) {
    var bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function bytesToB64(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s);
  }

  var cryptoKeyPromise = null;
  function getKey() {
    if (!cryptoKeyPromise) {
      cryptoKeyPromise = crypto.subtle.importKey(
        "raw", b64ToBytes(keyB64), { name: "AES-GCM" }, false, ["encrypt"]
      );
    }
    return cryptoKeyPromise;
  }

  async function encrypt(plaintext) {
    var key = await getKey();
    var iv = crypto.getRandomValues(new Uint8Array(12));
    var ct = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: iv }, key, new TextEncoder().encode(plaintext)
    );
    return { ciphertext: bytesToB64(new Uint8Array(ct)), iv: bytesToB64(iv) };
  }

  // ---- 题目 ----
  //
  // 四题与 App 内**完全一致**（见 Core/DisputeTestimony.swift）。
  //
  // 早先这里只问两题，理由是"远程填写的人没有耐心答四题"。那个理由站不住：
  // 题目数不对等会让整份评理失效 ——
  //   · DisputeTestimony.isComplete 要求四题全填，只有两题的证词
  //     在 A 端**根本提交不进去**（DisputeCase.submit 直接返回 nil），
  //     A 会永远卡在"等 TA 写完"，而对方那边明明显示"已提交"。
  //   · 即使强行放宽完整性，A 写了四题、B 写了两题，
  //     模型看到的两份信息量差一倍 —— 而这套协议的全部价值建立在
  //     "双方被同等对待"上，信息量不对等时任何结论都不可信。
  //
  // 第 4 题（自己那一份）是整套协议的支点，但也是远程最容易让人卡住的一题，
  // 所以给它一个"我还没想清楚"的一键填充 —— 那一句本来就是合法的答案。
  var QUESTIONS = [
    { id: "happened", label: "发生了什么？", hint: "只写你看到的、听到的。先别写你猜对方怎么想。" },
    { id: "hurtMost", label: "最让你难受的是哪一点？", hint: "不是最生气的地方，是最难受的地方。" },
    { id: "request", label: "你希望对方怎么做？", hint: "具体到一个动作，不要写「多关心我」。" },
    { id: "myPart", label: "这件事里，你自己那一份是什么？", hint: "不用认错，只要写你那一份。", shortcut: "我还没想清楚" }
  ];

  var answers = {};

  function renderForm(slot) {
    formEl.innerHTML = "";
    QUESTIONS.forEach(function (q, idx) {
      var wrap = document.createElement("div");
      wrap.className = "card";
      var lab = document.createElement("label");
      lab.textContent = (idx + 1) + ". " + q.label;
      var hint = document.createElement("p");
      hint.className = "hint";
      hint.textContent = q.hint;
      var ta = document.createElement("textarea");
      ta.placeholder = "写在这里…";
      ta.maxLength = 200;
      ta.rows = 3;
      ta.addEventListener("input", function () {
        answers[q.id] = ta.value;
        updateButton();
      });
      wrap.appendChild(lab); wrap.appendChild(hint); wrap.appendChild(ta);

      if (q.shortcut) {
        var quick = document.createElement("button");
        quick.type = "button";
        quick.className = "quick";
        quick.textContent = q.shortcut;
        quick.addEventListener("click", function () {
          ta.value = q.shortcut;
          answers[q.id] = q.shortcut;
          updateButton();
        });
        wrap.appendChild(quick);
      }

      formEl.appendChild(wrap);
    });

    var btn = document.createElement("button");
    btn.id = "submit";
    btn.textContent = "提交我这一份";
    btn.disabled = true;
    btn.addEventListener("click", function () { submit(slot, btn); });
    formEl.appendChild(btn);

    var note = document.createElement("p");
    note.className = "hint";
    note.style.textAlign = "center";
    note.textContent = "四题都写完才能提交。写完之后不能修改。";
    formEl.appendChild(note);
  }

  function isAnswered(id) {
    return !!(answers[id] && answers[id].trim());
  }

  function updateButton() {
    var btn = document.getElementById("submit");
    if (!btn) return;
    // 四题全填才允许提交 —— 与服务端 isComplete 的口径必须一致。
    var ready = QUESTIONS.every(function (q) { return isAnswered(q.id); });
    btn.disabled = !ready;
    if (ready) {
      setStatus("");
    } else {
      var missing = QUESTIONS.filter(function (q) { return !isAnswered(q.id); }).length;
      setStatus("还有 " + missing + " 题没写。");
    }
  }

  async function submit(slot, btn) {
    btn.disabled = true;
    setStatus("正在加密并提交…");
    try {
      // 提交前再核一遍四题 —— 按钮状态可以被绕过（改 DOM、回车、直接调函数），
      // 而"少一题的证词"在 A 端会让整件案卷卡死。这里多花一次判断，省掉一个死局。
      var missing = QUESTIONS.filter(function (q) { return !isAnswered(q.id); });
      if (missing.length) {
        setStatus("还有 " + missing.length + " 题没写。");
        btn.disabled = false;
        return;
      }
      var payload = JSON.stringify({
        slot: slot,
        answers: answers,
        submittedAt: Date.now()
      });
      var enc = await encrypt(payload);
      var res = await fetch("/v1/invite/" + caseId + "/" + slot, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(enc)
      });
      if (!res.ok) {
        var err = await res.json().catch(function () { return {}; });
        throw new Error((err.error && err.error.message) || ("提交失败（" + res.status + "）"));
      }
      formEl.innerHTML = '<div class="done"><h2>已经交给对方了</h2>' +
        '<p class="lede">对方那边会看到你写的这一份。你可以关掉这个页面。</p></div>';
      setStatus("");
    } catch (e) {
      setStatus(e.message || "提交失败，请稍后再试。");
      btn.disabled = false;
    }
  }

  // ---- 启动：领取位置 ----
  //
  // 固定领 b，不用自动分配。理由：发起方（A）的证词留在 A 自己的手机里，
  // **不会上送服务器**，所以这块白板上永远只会有"对方"这一份。
  // 自动分配会让对方拿到 a，而 App 只读 b ——
  // 结果是对方显示"已提交"、发起方永远显示"TA 还没写"，两边都不报错。
  (async function boot() {
    setStatus("正在准备…");
    try {
      var res = await fetch("/v1/invite/" + caseId + "/claim", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ slot: "b" })
      });
      if (res.status === 409) {
        setStatus("这个链接已经提交过了，不能重复填写。");
        return;
      }
      if (!res.ok) throw new Error("准备失败（" + res.status + "）");
      var data = await res.json();
      setStatus("");
      renderForm(data.slot);
    } catch (e) {
      setStatus(e.message || "打不开这个邀请，请稍后再试。");
    }
  })();
})();
</script>
</body>
</html>`;
}

// MARK: - 路由

/**
 * 处理 `/v1/invite/...` 下的全部路径。
 *
 * 返回 `null` 表示"这个模块不处理"，交给 `worker.js` 继续匹配 ——
 * 这样两个模块可以共用一个 Worker 与一套鉴权，而路由逻辑各管各的。
 *
 * @param {Request} request
 * @param {URL} url
 * @param {object} env 需要 `INVITE_KV`
 * @param {Function} quotaCheck 复用主 Worker 的 `checkQuota`
 */
export async function handleInvite(request, url, env, quotaCheck) {
  const path = url.pathname;
  if (!path.startsWith("/v1/invite/")) return null;

  const kv = env?.INVITE_KV;
  if (!kv) {
    // 没配 KV 时明确报错，而不是假装成功。
    // 一个"写入无声失败"的白板会让用户以为对方收到了，实际上什么都没存下。
    return fail("服务端未配置 INVITE_KV，邀请功能不可用", 503);
  }

  // /v1/invite/:caseId/page —— 浏览器普通 GET，不需要 App 令牌。
  // 对方是普通用户，手里没有令牌；要求令牌等于这个功能不存在。
  const pageMatch = path.match(/^\/v1\/invite\/([A-Za-z0-9_-]{16,64})\/page$/);
  if (pageMatch) {
    if (request.method !== "GET") return fail("只接受 GET", 405);
    return new Response(renderInvitePage(), {
      headers: {
        "content-type": "text/html; charset=utf-8",
        // 绝不缓存：链接带一次性密钥，缓存会把密钥留在中间层。
        "cache-control": "no-store",
        // 不让搜索引擎收录，也不让社交软件的预览抓走标题。
        "x-robots-tag": "noindex, nofollow",
        "referrer-policy": "no-referrer",
      },
    });
  }

  // 以下都需要 App 令牌（或对方网页里的匿名写入，按端点区分）。
  const claimMatch = path.match(/^\/v1\/invite\/([A-Za-z0-9_-]{16,64})\/claim$/);
  const putMatch = path.match(/^\/v1\/invite\/([A-Za-z0-9_-]{16,64})\/(a|b)$/);
  const getMatch = path.match(/^\/v1\/invite\/([A-Za-z0-9_-]{16,64})$/);

  const caseId = (claimMatch || putMatch || getMatch)?.[1];
  if (!caseId) {
    // 走到这里说明路径形如 /v1/invite/xxx/yyy 但不对。不猜，直接 404。
    return fail(`未知路径：${path}`, 404);
  }
  if (!CASE_ID_PATTERN.test(caseId)) return fail("caseId 格式不对", 400);

  // 限频。对方网页那一路没有令牌，所以这里**不能**依赖令牌；
  // 用 IP 配额挡住"写满一万个 caseId"这类滥用。
  const quota = await quotaCheck(request);
  if (!quota.allowed) {
    return fail("今天的使用次数已用完，明天再来。", 429);
  }

  if (claimMatch) {
    if (request.method !== "POST") return fail("只接受 POST", 405);
    // body 是可选的：不传就退回自动分配。
    //
    // 注意不能像 PUT 那样"解析失败就 400"：网页可能是空 body 的 POST，
    // 而 `request.json()` 对空 body 会抛。所以这里容错成 undefined。
    let body;
    try {
      body = await request.json();
    } catch {
      body = undefined;
    }
    return handleClaim(caseId, kv, body?.slot);
  }

  if (putMatch) {
    if (request.method !== "PUT") return fail("只接受 PUT", 405);
    let body;
    try {
      body = await request.json();
    } catch {
      return fail("请求体不是合法 JSON", 400);
    }
    return handlePut(caseId, putMatch[2], body, kv);
  }

  if (getMatch) {
    if (request.method !== "GET") return fail("只接受 GET", 405);
    return handleGet(caseId, kv);
  }

  return fail(`未知路径：${path}`, 404);
}
