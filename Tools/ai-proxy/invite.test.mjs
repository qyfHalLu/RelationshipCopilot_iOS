//
// invite.test.mjs —— 评理邀请协议的本地验证
//
// 跑法：node invite.test.mjs
//
// ## 为什么这份测试值得单独存在
//
// 这个协议里有一处**只能靠结构保证、无法靠代码检查**的安全属性：
// 「服务端读不懂证词」。它在服务端不体现为任何一行代码 ——
// 恰恰是"这里没有解密代码"本身构成了保证。
//
// 所以测试要守的是这条边界的**周边**：
//   ① URL 里的 key 走 `#`，不进 HTTP 请求（否则会进日志与聊天预览）
//   ② 写入过的东西不能被覆盖（否则"我的证词被换掉了"成为可能）
//   ③ 位置要用 claim 领取（否则两人同时写会静默丢失一份）
//   ④ 没配 KV 时必须明确报错（否则用户以为对方收到了，其实什么都没存）
//
// 用假 KV 在本地跑，不需要 wrangler、不需要 Cloudflare 账号。

import { handleInvite } from "./invite.js";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));

let passed = 0;
let failed = 0;

function check(name, condition, detail = "") {
  if (condition) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    console.log(`  FAIL ${name}${detail ? " — " + detail : ""}`);
  }
}

/** 最小 KV 替身。只需 get / put，并记录 TTL 是否被设置。 */
function makeKV() {
  const store = new Map();
  return {
    store,
    async get(key) {
      return store.has(key) ? store.get(key).value : null;
    },
    async put(key, value, options) {
      store.set(key, { value, ttl: options?.expirationTtl });
    },
  };
}

/** 永远放行的配额检查。测限频本身是另一件事，这里不该被它干扰。 */
const allowAll = async () => ({ allowed: true });

function req(method, path, body) {
  const init = { method };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers = { "content-type": "application/json" };
  }
  return new Request(`https://proxy.example.com${path}`, init);
}

const CASE = "abcdefghijklmnop1234";

// ---------------------------------------------------------------------------
// ① 路由边界
// ---------------------------------------------------------------------------

console.log("\n路由");

{
  const env = { INVITE_KV: makeKV() };
  const r = await handleInvite(req("GET", "/v1/assist"), new URL("https://x/v1/assist"), env, allowAll);
  check("非 invite 路径返回 null，交回主 Worker", r === null);

  const r2 = await handleInvite(
    req("POST", `/v1/invite/${CASE}/claim`),
    new URL(`https://x/v1/invite/${CASE}/claim`),
    { INVITE_KV: makeKV() },
    allowAll
  );
  check("invite 路径返回 Response", r2 instanceof Response);
}

{
  // 没配 KV：必须 503 且明确说明，不能静默"成功"。
  const env = {};
  const r = await handleInvite(
    req("POST", `/v1/invite/${CASE}/claim`),
    new URL(`https://x/v1/invite/${CASE}/claim`),
    env,
    allowAll
  );
  check("未配置 INVITE_KV 时返回 503", r.status === 503, `实际 ${r.status}`);
  const body = await r.json();
  check("503 的错误信息提到 INVITE_KV", String(body?.error?.message).includes("INVITE_KV"));
}

{
  // caseId 太短 / 含非法字符：必须拒绝，防 KV 键污染与路径穿越。
  const env = { INVITE_KV: makeKV() };
  for (const bad of ["short", "../etc/passwd", "a".repeat(200)]) {
    const r = await handleInvite(
      req("POST", `/v1/invite/${encodeURIComponent(bad)}/claim`),
      new URL(`https://x/v1/invite/${encodeURIComponent(bad)}/claim`),
      env,
      allowAll
    );
    // 要么被正则挡在 400，要么根本没匹配上路由（404）—— 都算拒绝。
    check(`非法 caseId「${bad.slice(0, 12)}」被拒绝`, r !== null && r.status >= 400, `实际 ${r.status}`);
  }
}

// ---------------------------------------------------------------------------
// ② claim：两个位置，第三个拒绝
// ---------------------------------------------------------------------------

console.log("\n领取位置");

{
  const env = { INVITE_KV: makeKV() };
  const path = `/v1/invite/${CASE}/claim`;
  const a = await (await handleInvite(req("POST", path), new URL("https://x" + path), env, allowAll)).json();
  check("第一次 claim 拿到 a", a.slot === "a", JSON.stringify(a));

  const b = await (await handleInvite(req("POST", path), new URL("https://x" + path), env, allowAll)).json();
  check("第二次 claim 拿到 b", b.slot === "b", JSON.stringify(b));

  const c = await handleInvite(req("POST", path), new URL("https://x" + path), env, allowAll);
  check("第三次 claim 返回 409", c.status === 409, `实际 ${c.status}`);
}

{
  // TTL 必须每次写入都带上，否则过期清理要靠人记得。
  const kv = makeKV();
  const env = { INVITE_KV: kv };
  const path = `/v1/invite/${CASE}/claim`;
  await handleInvite(req("POST", path), new URL("https://x" + path), env, allowAll);
  const entry = kv.store.get(`invite:${CASE}:a`);
  check("claim 写入时带了 TTL", typeof entry?.ttl === "number" && entry.ttl > 0, JSON.stringify(entry?.ttl));
  check("TTL 是 7 天", entry?.ttl === 7 * 24 * 3600, String(entry?.ttl));
}

{
  // 指定 slot：对方网页固定领 b。
  //
  // 这一组守的是一处**两边都不报错**的错位：
  // 自动分配会让唯一的填写者（对方）拿到 a，而 App 端只读 testimonies["b"]。
  // 症状是对方显示"已提交"、发起方永远显示"TA 还没写"，
  // 服务端日志一切正常，客户端一切正常，只是人永远等下去。
  const env = { INVITE_KV: makeKV() };
  const path = `/v1/invite/${CASE}/claim`;

  const r = await (
    await handleInvite(req("POST", path, { slot: "b" }), new URL("https://x" + path), env, allowAll)
  ).json();
  check("指定 slot=b 时返回 b", r.slot === "b", JSON.stringify(r));

  const got = await (
    await handleInvite(req("GET", `/v1/invite/${CASE}`), new URL(`https://x/v1/invite/${CASE}`), env, allowAll)
  ).json();
  check("指定 b 之后 a 仍为空", got.slots?.a === false, JSON.stringify(got.slots));
  check("指定 b 之后 b 已占", got.slots?.b === true, JSON.stringify(got.slots));

  // 非法 slot 直接拒，不应落进自动分配。
  const bad = await handleInvite(
    req("POST", path, { slot: "c" }),
    new URL("https://x" + path),
    { INVITE_KV: makeKV() },
    allowAll
  );
  check("非法 slot 返回 400", bad.status === 400, `实际 ${bad.status}`);
}

{
  // 刷新页面要能重新领到同一个位置。
  //
  // 对方很可能在写了一半时刷新或误关页面。若重复 claim 回 409，
  // 他会被自己的占位挡在门外 —— 而那个占位上什么内容都没有。
  const env = { INVITE_KV: makeKV() };
  const path = `/v1/invite/${CASE}/claim`;
  await handleInvite(req("POST", path, { slot: "b" }), new URL("https://x" + path), env, allowAll);
  const again = await handleInvite(
    req("POST", path, { slot: "b" }),
    new URL("https://x" + path),
    env,
    allowAll
  );
  check("已领取未写入时可以重复领取", again.status === 200, `实际 ${again.status}`);

  // 但写过内容之后就不能再领了 —— 否则等于允许第二个人覆盖。
  const base = `https://x/v1/invite/${CASE}`;
  await handleInvite(
    req("PUT", `${base}/b`, { ciphertext: "CIPHER_B", iv: "IV_B" }),
    new URL(`${base}/b`),
    env,
    allowAll
  );
  const afterWrite = await handleInvite(
    req("POST", path, { slot: "b" }),
    new URL("https://x" + path),
    env,
    allowAll
  );
  check("已写入内容后 claim 返回 409", afterWrite.status === 409, `实际 ${afterWrite.status}`);
}

{
  // 网页里必须显式领 b。这一条把服务端的 slot 约定与网页的实际行为钉在一起 ——
  // 只测服务端能按参数分配是不够的，还要确认网页真的传了这个参数。
  const pagePath = `/v1/invite/${CASE}/page`;
  const html = await (
    await handleInvite(req("GET", pagePath), new URL(`https://x${pagePath}`), { INVITE_KV: makeKV() }, allowAll)
  ).text();
  check(
    "网页 claim 时显式指定 slot=b",
    /claim"[\s\S]{0,200}?slot:\s*"b"/.test(html) || /slot:\s*"b"[\s\S]{0,200}?claim/.test(html),
    "没找到网页固定领 b 的代码"
  );
}

// ---------------------------------------------------------------------------
// ③ put / get：一轮完整往返
// ---------------------------------------------------------------------------

console.log("\n写入与取回");

async function fullRoundTrip() {
  const env = { INVITE_KV: makeKV() };
  const base = `https://x/v1/invite/${CASE}`;

  await handleInvite(req("POST", `${base}/claim`), new URL(`${base}/claim`), env, allowAll);
  const putA = await handleInvite(
    req("PUT", `${base}/a`, { ciphertext: "CIPHER_A", iv: "IV_A" }),
    new URL(`${base}/a`),
    env,
    allowAll
  );
  return { env, base, putA };
}

{
  const { env, base, putA } = await fullRoundTrip();
  check("写入 a 成功", putA.status === 200, `实际 ${putA.status}`);

  const got = await (await handleInvite(req("GET", base), new URL(base), env, allowAll)).json();
  check("取回时 a 有内容", got.testimonies?.a?.ciphertext === "CIPHER_A", JSON.stringify(got.testimonies));
  check("取回时 iv 也在", got.testimonies?.a?.iv === "IV_A");
  check("a 已写、b 未领取", got.slots?.a === true && got.slots?.b === false, JSON.stringify(got.slots));
}

{
  // 覆盖必须被拒绝 —— 这是"我的证词被换掉了"的唯一防线。
  const { env, base } = await fullRoundTrip();
  const again = await handleInvite(
    req("PUT", `${base}/a`, { ciphertext: "OTHER", iv: "IV_X" }),
    new URL(`${base}/a`),
    env,
    allowAll
  );
  check("重复写入同一位置返回 409", again.status === 409, `实际 ${again.status}`);

  const got = await (await handleInvite(req("GET", base), new URL(base), env, allowAll)).json();
  check("原始内容没有被覆盖", got.testimonies?.a?.ciphertext === "CIPHER_A");
}

{
  // 没 claim 就写：必须拒绝。
  // 否则任何人都能往任意 caseId 塞内容，把它当免费存储。
  const kv = makeKV();
  const env = { INVITE_KV: kv };
  const base = `https://x/v1/invite/${CASE}`;
  const r = await handleInvite(
    req("PUT", `${base}/a`, { ciphertext: "X", iv: "Y" }),
    new URL(`${base}/a`),
    env,
    allowAll
  );
  check("未 claim 直接写返回 409", r.status === 409, `实际 ${r.status}`);
}

{
  // 空内容 / 缺 iv：必须拒绝。
  const env = { INVITE_KV: makeKV() };
  const base = `https://x/v1/invite/${CASE}`;
  await handleInvite(req("POST", `${base}/claim`), new URL(`${base}/claim`), env, allowAll);

  for (const body of [{}, { ciphertext: "X" }, { iv: "Y" }, { ciphertext: "", iv: "Y" }]) {
    const r = await handleInvite(req("PUT", `${base}/a`, body), new URL(`${base}/a`), env, allowAll);
    check(`缺字段的写入被拒绝 ${JSON.stringify(body)}`, r.status === 400, `实际 ${r.status}`);
  }
}

{
  // 超大密文：拒绝。
  const env = { INVITE_KV: makeKV() };
  const base = `https://x/v1/invite/${CASE}`;
  await handleInvite(req("POST", `${base}/claim`), new URL(`${base}/claim`), env, allowAll);
  const big = "A".repeat(70 * 1024);
  const r = await handleInvite(
    req("PUT", `${base}/a`, { ciphertext: big, iv: "Y" }),
    new URL(`${base}/a`),
    env,
    allowAll
  );
  check("超大密文返回 413", r.status === 413, `实际 ${r.status}`);
}

{
  // awaiting 反映"还差谁"。A 写完、B 已 claim 未写 → 还差 b。
  const { env, base } = await fullRoundTrip();
  await handleInvite(req("POST", `${base}/claim`), new URL(`${base}/claim`), env, allowAll);
  const got = await (await handleInvite(req("GET", base), new URL(base), env, allowAll)).json();
  check("awaiting 指出还差 b", Array.isArray(got.awaiting) && got.awaiting.join() === "b", JSON.stringify(got.awaiting));
}

{
  // 两端都写完：awaiting 为空，两份都能取到。
  const { env, base } = await fullRoundTrip();
  await handleInvite(req("POST", `${base}/claim`), new URL(`${base}/claim`), env, allowAll);
  await handleInvite(
    req("PUT", `${base}/b`, { ciphertext: "CIPHER_B", iv: "IV_B" }),
    new URL(`${base}/b`),
    env,
    allowAll
  );
  const got = await (await handleInvite(req("GET", base), new URL(base), env, allowAll)).json();
  check("两份都写完时 awaiting 为空", Array.isArray(got.awaiting) && got.awaiting.length === 0);
  check("两份密文都能取回",
    got.testimonies?.a?.ciphertext === "CIPHER_A" && got.testimonies?.b?.ciphertext === "CIPHER_B");
}

// ---------------------------------------------------------------------------
// ④ 网页：密钥不进请求
// ---------------------------------------------------------------------------

console.log("\n对方填写的网页");

{
  const env = { INVITE_KV: makeKV() };
  const path = `/v1/invite/${CASE}/page`;
  const r = await handleInvite(req("GET", path), new URL(`https://x${path}`), env, allowAll);
  check("网页需要 GET", r.status === 200, `实际 ${r.status}`);
  check("返回 HTML", String(r.headers.get("content-type")).includes("text/html"));

  const html = await r.text();

  // 这一条是整个方案的地基：key 从 `#` 后面读。
  check("网页从 location.hash 读密钥", html.includes("location.hash"));
  check("网页不使用 location.search 取密钥", !html.includes("location.search"));

  // 不允许缓存：链接带一次性密钥，缓存会把密钥留在中间层。
  check("网页不可缓存", r.headers.get("cache-control") === "no-store");
  check("网页不索引", String(r.headers.get("x-robots-tag")).includes("noindex"));

  // 加密必须在浏览器里完成。
  check("网页内嵌 WebCrypto 加密", html.includes("crypto.subtle.encrypt"));

  // 明文绝不能上送 —— 检查 PUT 的 body 里没有 answers 的直接序列化。
  // 这里查的是"加密在前、PUT 在后"的结构顺序。
  const encIdx = html.indexOf("crypto.subtle.encrypt");
  const putIdx = html.indexOf('method: "PUT"');
  check("加密发生在 PUT 之前", encIdx > 0 && putIdx > encIdx, `${encIdx} vs ${putIdx}`);
}

{
  // 网页不接受 POST。
  const env = { INVITE_KV: makeKV() };
  const path = `/v1/invite/${CASE}/page`;
  const r = await handleInvite(req("POST", path), new URL(`https://x${path}`), env, allowAll);
  check("网页只接受 GET", r.status === 405, `实际 ${r.status}`);
}

// ---------------------------------------------------------------------------
// ④b 题目数必须与 App 内一致
// ---------------------------------------------------------------------------
//
// 这一条守的是一个**跨端不一致**，而它的症状全在另一端：
// 早先网页只问两题，对方写完显示"已提交"，A 端却永远卡在"等 TA 写完" ——
// 因为 `DisputeTestimony.isComplete` 要求四题全填，
// `DisputeCase.submit` 拿到两题的证词直接返回 nil，状态机原地不动。
//
// 判不出来的原因是：网页在自己的世界里自洽（两题 → 两题答案 → 加密 → 提交成功）。
// 只有把两端的题目数放在一起比，才能发现它们对不上。
//
// 所以这里读 Swift 源码，逐个取题目名，再与网页里的 id 集合比对。
// 不写死"4"这个数字 —— 写死的话将来 Swift 加第五题，这里还是绿的。

console.log("\n题目数：网页 vs App");

{
  const pagePath = `/v1/invite/${CASE}/page`;
  const html = await (
    await handleInvite(req("GET", pagePath), new URL(`https://x${pagePath}`), { INVITE_KV: makeKV() }, allowAll)
  ).text();

  const swift = readFileSync(resolve(HERE, "../../Core/DisputeTestimony.swift"), "utf8");
  const enumStart = swift.indexOf("enum TestimonyQuestion");
  const enumBody = swift.slice(enumStart, swift.indexOf("var id: Int", enumStart));
  const swiftCases = [...enumBody.matchAll(/^\s*case (\w+)\s*=\s*\d+/gm)].map((m) => m[1]);

  check("从 Swift 源码解析出了题目", swiftCases.length > 0, JSON.stringify(swiftCases));

  const qStart = html.indexOf("var QUESTIONS");
  const qBlock = html.slice(qStart, html.indexOf("var answers = {}", qStart));
  const webIds = [...qBlock.matchAll(/id:\s*"(\w+)"/g)].map((m) => m[1]);

  check(
    `网页题目数与 App 一致（网页 ${webIds.length} / App ${swiftCases.length}）`,
    webIds.length > 0 && webIds.length === swiftCases.length,
    `网页 ${JSON.stringify(webIds)} / App ${JSON.stringify(swiftCases)}`
  );

  // 不只是数量，字段名也要逐一对上 —— 数量相同但名字不同，
  // 结果一样是"对方写的第 3 题变成 A 端的第 2 题"。
  check(
    "网页题目 id 与 App 的 case 名逐一对应",
    webIds.length > 0 &&
      JSON.stringify(webIds.slice().sort()) === JSON.stringify(swiftCases.slice().sort()),
    `网页 ${JSON.stringify(webIds)} / App ${JSON.stringify(swiftCases)}`
  );

  // 字数上限也必须一致，否则一侧截断、另一侧不截断，对称性校验会失真。
  const swiftLimit = Number((swift.match(/characterLimit\s*=\s*(\d+)/) || [])[1]);
  const webLimit = Number((html.match(/maxLength\s*=\s*(\d+)/) || [])[1]);
  check(
    `字数上限一致（网页 ${webLimit} / App ${swiftLimit}）`,
    swiftLimit > 0 && webLimit === swiftLimit,
    `网页 ${webLimit} / App ${swiftLimit}`
  );

  // 四题全填才让点提交。少一题就放行的话，A 端拿到的是废证词。
  check(
    "提交按钮由四题全填控制",
    qBlock.length > 0 && html.includes("QUESTIONS.every"),
    "没找到 QUESTIONS.every 判定"
  );
}

// ---------------------------------------------------------------------------
// ⑤ 限频
// ---------------------------------------------------------------------------

console.log("\n限频");

{
  const env = { INVITE_KV: makeKV() };
  const denyAll = async () => ({ allowed: false, used: 999 });
  const path = `/v1/invite/${CASE}/claim`;
  const r = await handleInvite(req("POST", path), new URL(`https://x${path}`), env, denyAll);
  check("配额用尽时领位被拒", r.status === 429, `实际 ${r.status}`);
}

{
  // 网页不应被配额拦住：它是阅读动作，卡它会让对方打不开链接。
  const env = { INVITE_KV: makeKV() };
  const denyAll = async () => ({ allowed: false });
  const path = `/v1/invite/${CASE}/page`;
  const r = await handleInvite(req("GET", path), new URL(`https://x${path}`), env, denyAll);
  check("配额用尽时网页仍可打开", r.status === 200, `实际 ${r.status}`);
}

// ---------------------------------------------------------------------------
// ⑥ 跨境契约：与 Swift 侧共用的固定向量
// ---------------------------------------------------------------------------
//
// 这条是本文件里最重要的一条。
//
// 加密在两个地方实现：Swift（`Services/InviteCrypto.swift`）和对方网页里的
// WebCrypto。两者必须逐字节兼容 —— 差一个，对方写的内容 A 端就解不开，
// 而错误只会说"认证失败"，完全指不出是哪一边的问题。
//
// 下面这组数字在 `Tests/InviteCryptoTests.swift` 里一字不差地存在。
// 两边用**各自的实现**对着同一组数字跑，这是唯一可靠的验证方式。
// 纯 Swift 往返测试证明不了互通：自己加密自己解密，参数全错也能自洽。

console.log("\n与 Swift 侧的加密契约");

{
  const { webcrypto } = await import("node:crypto");

  const keyBytes = new Uint8Array(32);
  for (let i = 0; i < 32; i++) keyBytes[i] = i;

  const key = await webcrypto.subtle.importKey(
    "raw", keyBytes, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]
  );

  const plaintext = "契约向量：她说「算了」的那天";
  const iv = new Uint8Array(12); // 全 0，便于固定向量

  const ctBuf = await webcrypto.subtle.encrypt(
    { name: "AES-GCM", iv }, key, new TextEncoder().encode(plaintext)
  );
  const ctBytes = new Uint8Array(ctBuf);

  // 这三个值必须与 `InviteCryptoTests.swift` 里写死的完全一致。
  const EXPECTED_CT = "6xkkOQ+KZi2ZQS6695ALfHf6vvycYuCjZzAkZ395vtbDuHw4w3Ab45dqWeYKOUmgojdjtV52JNaZPg==";
  const EXPECTED_KEY_B64URL = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

  const ctB64 = Buffer.from(ctBytes).toString("base64");
  const keyB64URL = Buffer.from(keyBytes).toString("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  check("WebCrypto 算出的密文与 Swift 侧写死的向量一致", ctB64 === EXPECTED_CT, ctB64);
  check("密钥的 base64url 与 Swift 侧一致", keyB64URL === EXPECTED_KEY_B64URL, keyB64URL);

  // 密文长度 = 明文字节 + 16 字节认证标签。差 16 通常意味着 tag 没被算进去。
  check(
    "密文长度符合 AES-GCM 预期（明文 + 16 字节 tag）",
    ctBytes.length === new TextEncoder().encode(plaintext).length + 16,
    `${ctBytes.length} vs ${new TextEncoder().encode(plaintext).length + 16}`
  );

  // 反向：用同一 key 解回自己算的密文，确认这组参数本身可用。
  const back = await webcrypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ctBuf);
  check("WebCrypto 能解回原文", new TextDecoder().decode(back) === plaintext);

  // 篡改一个字节必须解不开 —— 确认用的是认证加密。
  const tampered = new Uint8Array(ctBytes);
  tampered[Math.floor(tampered.length / 2)] ^= 0xFF;
  let threw = false;
  try {
    await webcrypto.subtle.decrypt({ name: "AES-GCM", iv }, key, tampered);
  } catch {
    threw = true;
  }
  check("篡改后的密文解不开（认证加密生效）", threw);
}

// ---------------------------------------------------------------------------

console.log(`\n${passed} 通过, ${failed} 失败`);
if (failed > 0) process.exit(1);
