//
// worker.test.mjs —— 零依赖的本地验证
//
// 跑法：node worker.test.mjs
//
// ## 这份测试存在的理由（一次真实的假绿）
//
// 上一版的 18 项测试全部通过，但代理对上真实客户端是 100% 的 400。
// 原因：测试自己把请求体写成 `{ transcript: ... }`，而客户端
// `AIService.ProxyAnalyzeRequest` 发的字段是 `conversation`。
//
// 测试是按**假设**写的，不是按**契约**写的。所以它在测一个不存在的客户端。
//
// 修法不是改一个字符串，而是让契约不可假设：下面的「契约」段落直接读
// `Services/AIService.swift` 源码，把字段名、预算、端点路径取出来，
// 再拿这些值去构造请求。Swift 那边改了名字，这里立刻报红。
//

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import worker from "./worker.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const SWIFT = resolve(HERE, "../../Services/AIService.swift");
const DISPUTE_PROMPT = resolve(HERE, "../../Core/DisputePrompt.swift");

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

// ---------------------------------------------------------------------------
// 契约：从 Swift 源码里读出真实字段名与预算
// ---------------------------------------------------------------------------

const swiftSource = readFileSync(SWIFT, "utf8");

/** 取某个 struct 的成员名。 */
function membersOf(structName) {
  const match = swiftSource.match(new RegExp(`struct ${structName}\\s*:[^{]*\\{([\\s\\S]*?)\\n\\}`));
  if (!match) throw new Error(`找不到 struct ${structName}`);
  return [...match[1].matchAll(/^\s*let\s+(\w+)\s*:/gm)].map((m) => m[1]);
}

const contract = {
  analyze: membersOf("ProxyAnalyzeRequest"),
  assist: membersOf("AssistRequest"),
  dispute: membersOf("DisputeProxyRequest"),
};

// ---------------------------------------------------------------------------

/** 造一个最小 Cloudflare 环境：env + Cache API。 */
function makeEnv({ modelResponse, status = 200, apiKey = "test-key-123", appToken = "app-token-xyz" } = {}) {
  const calls = [];
  const cacheStore = new Map();

  globalThis.fetch = async (url, init) => {
    calls.push({ url, init, body: init?.body ? JSON.parse(init.body) : null });
    if (status !== 200) {
      return new Response("upstream error detail", { status });
    }
    return new Response(JSON.stringify(modelResponse), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  globalThis.caches = {
    default: {
      async match(key) {
        const value = cacheStore.get(key.url);
        return value === undefined ? undefined : new Response(value);
      },
      async put(key, response) {
        cacheStore.set(key.url, await response.text());
      },
    },
  };

  return {
    env: { SOPHNET_API_KEY: apiKey, APP_TOKEN: appToken, MODEL: "test-model" },
    calls,
    cacheStore,
    appToken,
  };
}

/** 默认带上正确的共享令牌 —— 忘了带令牌的用例单独测。 */
function makeRequest(path, body, headers = {}, token = "app-token-xyz") {
  return new Request(`https://proxy.test${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "1.2.3.4",
      ...(token ? { "x-app-token": token } : {}),
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

const okResponse = (content, finishReason = "stop") => ({
  choices: [{ message: { content }, finish_reason: finishReason }],
});

/** 按 Swift 里的字段名组装 analyze 请求体 —— 这才是真实客户端发的形状。 */
function analyzeBody(values) {
  return Object.fromEntries(contract.analyze.map((key) => [key, values[key]]));
}

// ---------------------------------------------------------------------------

console.log("\n[契约：与 AIService.swift 一致]");
{
  check("analyze 字段是 conversation", contract.analyze.includes("conversation"), contract.analyze.join(","));
  check("analyze 没有 transcript 这个旧名字", !contract.analyze.includes("transcript"));
  check("assist 字段是 tool + input", contract.assist.join(",") === "tool,input", contract.assist.join(","));
  check(
    "dispute 含 systemPrompt + userMessage",
    contract.dispute.includes("systemPrompt") && contract.dispute.includes("userMessage"),
    contract.dispute.join(",")
  );

  // 预算必须两边一致，否则同一段输入在直连与代理两条路上表现不同。
  const swiftTokens = readFileSync(DISPUTE_PROMPT, "utf8").match(/maxOutputTokens\s*=\s*([\d_]+)/);
  const swiftValue = Number(String(swiftTokens?.[1]).replace(/_/g, ""));
  check("评理预算与 DisputePrompt 一致", swiftValue === 3500, `Swift=${swiftValue}`);
}

console.log("\n[健康检查]");
{
  const { env } = makeEnv();
  const res = await worker.fetch(new Request("https://proxy.test/health"), env);
  const data = await res.json();
  check("GET 返回 200", res.status === 200, `实际 ${res.status}`);
  check("回显模型名", data.model === "test-model", JSON.stringify(data));
  check("不泄露密钥", !JSON.stringify(data).includes("test-key-123"));
  check("不需要令牌（部署后要能不装 curl 就验证）", data.ok === true);
}

console.log("\n[令牌]");
{
  const { env } = makeEnv();
  const noToken = await worker.fetch(makeRequest("/v1/assist", {}, {}, null), env);
  check("缺令牌返回 401", noToken.status === 401, `实际 ${noToken.status}`);

  const wrong = await worker.fetch(makeRequest("/v1/assist", {}, {}, "wrong"), env);
  check("令牌不匹配返回 401", wrong.status === 401, `实际 ${wrong.status}`);

  const bare = makeEnv();
  bare.env.APP_TOKEN = "";
  const res = await worker.fetch(makeRequest("/v1/assist", {}), bare.env);
  check("服务端没配 APP_TOKEN 时拒绝服务", res.status === 503, `实际 ${res.status}`);
}

console.log("\n[评理端点]");
{
  const { env, calls } = makeEnv({ modelResponse: okResponse('{"reframe":"x"}') });
  const res = await worker.fetch(
    makeRequest("/v1/dispute/evaluate", {
      systemPrompt: "你是评理助手",
      userMessage: "她说我总在解释",
      temperature: 0.3,
      maxTokens: 3500,
    }),
    env
  );
  const data = await res.json();
  check("返回 200", res.status === 200);
  check("回传 text", data.text === '{"reframe":"x"}', JSON.stringify(data));
  check("上游收到 system 提示词", calls[0].body.messages[0].content === "你是评理助手");
  check("上游收到 user 消息", calls[0].body.messages[1].content === "她说我总在解释");
  check("maxTokens 透传", calls[0].body.max_tokens === 3500);
  check("Authorization 用环境变量", calls[0].init.headers.authorization === "Bearer test-key-123");
  check("响应里没有密钥", !JSON.stringify(data).includes("test-key-123"));
}

console.log("\n[评理端点 · 缺字段]");
{
  const { env } = makeEnv();
  const res = await worker.fetch(makeRequest("/v1/dispute/evaluate", { systemPrompt: "x" }), env);
  check("返回 400", res.status === 400, `实际 ${res.status}`);
}

console.log("\n[评理端点 · 预算上限]");
{
  const { env, calls } = makeEnv({ modelResponse: okResponse("ok") });
  await worker.fetch(
    makeRequest("/v1/dispute/evaluate", { systemPrompt: "s", userMessage: "u", maxTokens: 999999 }),
    env
  );
  check("客户端不能把预算顶到天上", calls[0].body.max_tokens === 8000, `实际 ${calls[0].body.max_tokens}`);
}

console.log("\n[快速工具端点]");
for (const tool of ["conflict", "phrase", "apology"]) {
  const { env, calls } = makeEnv({ modelResponse: okResponse("要点一…") });
  const res = await worker.fetch(makeRequest("/v1/assist", { tool, input: "她说我总在解释" }), env);
  const data = await res.json();
  check(`${tool} 返回 200`, res.status === 200);
  check(`${tool} 用了自己的提示词`, calls[0].body.messages[0].content.length > 50);
  check(`${tool} 回传 text`, data.text === "要点一…");
}

console.log("\n[快速工具 · 未知工具名]");
{
  const { env } = makeEnv();
  const res = await worker.fetch(makeRequest("/v1/assist", { tool: "checkup", input: "x" }), env);
  check("返回 400", res.status === 400, "关系体检已删除，不该被接受");
}

console.log("\n[快速工具 · 提示词不自相矛盾]");
{
  const { env, calls } = makeEnv({ modelResponse: okResponse("x") });

  await worker.fetch(makeRequest("/v1/assist", { tool: "phrase", input: "x" }), env);
  const phrase = calls[0].body.messages[0].content;
  check("phrase 不该同时要求「给原话」和「不要给成品」", !phrase.includes("可以直接使用的原话"));
  check("phrase 明确禁止成品", phrase.includes("不要给用户一段可以复制粘贴的话"));

  const second = makeEnv({ modelResponse: okResponse("x") });
  await worker.fetch(makeRequest("/v1/assist", { tool: "conflict", input: "x" }), second.env);
  const conflict = second.calls[0].body.messages[0].content;
  check("conflict 保留「给原话」（这个工具确实要）", conflict.includes("可以直接使用的原话"));
}

console.log("\n[录音分析端点 · 用真实字段名]");
{
  const analysis = {
    score: 62,
    summary: "沟通还在，但都在讲道理。",
    strengths: ["愿意解释"],
    improvements: ["没先接住情绪"],
    suggestions: ["先只说一句「那一定很难受」"],
    emotionalTrend: "下降",
    communicationQuality: "一般",
  };
  const { env, calls } = makeEnv({ modelResponse: okResponse(JSON.stringify(analysis)) });
  const res = await worker.fetch(
    makeRequest(
      "/v1/relationship/analyze",
      analyzeBody({
        conversation: "她说被领导当众批评了，我说那你下次提前准备",
        counterpartName: "小林",
        relationshipType: "partner",
      })
    ),
    env
  );
  const data = await res.json();
  check("返回 200", res.status === 200, JSON.stringify(data));
  check("解析出 analysis", data.analysis?.score === 62, JSON.stringify(data));
  check("user 消息含对话内容", calls[0].body.messages[1].content.includes("被领导当众批评"));
  check("user 消息含称呼", calls[0].body.messages[1].content.includes("小林"));
}

console.log("\n[录音分析 · 不认旧字段名]");
{
  const { env } = makeEnv({ modelResponse: okResponse("{}") });
  const res = await worker.fetch(
    makeRequest("/v1/relationship/analyze", { transcript: "旧字段名" }),
    env
  );
  check("transcript 被拒绝（不静默兼容，避免再次漂移）", res.status === 400, `实际 ${res.status}`);
}

console.log("\n[录音分析 · 模型输出带 markdown 包裹]");
{
  const analysis = { score: 70, summary: "还行" };
  const { env } = makeEnv({
    modelResponse: okResponse("```json\n" + JSON.stringify(analysis) + "\n```"),
  });
  const res = await worker.fetch(
    makeRequest("/v1/relationship/analyze", analyzeBody({ conversation: "abc" })),
    env
  );
  const data = await res.json();
  check("能剥掉 ```json 包裹", data.analysis?.score === 70, JSON.stringify(data));
}

console.log("\n[录音分析 · 模型输出无法解析]");
{
  const { env } = makeEnv({ modelResponse: okResponse("我觉得这段关系还不错") });
  const res = await worker.fetch(
    makeRequest("/v1/relationship/analyze", analyzeBody({ conversation: "abc" })),
    env
  );
  check("返回 502 而不是伪造结果", res.status === 502, `实际 ${res.status}`);
  const data = await res.json();
  check("响应里没有 analysis 字段", data.analysis === undefined);
}

console.log("\n[推理模型截断]");
{
  const { env } = makeEnv({ modelResponse: okResponse("", "length") });
  const res = await worker.fetch(makeRequest("/v1/dispute/evaluate", { systemPrompt: "s", userMessage: "x" }), env);
  check("返回 502", res.status === 502, `实际 ${res.status}`);
  const data = await res.json();
  check("错误信息说明是截断", String(data.error?.message).includes("截断"), JSON.stringify(data));
}

console.log("\n[只有推理没有正文]");
{
  const { env } = makeEnv({
    modelResponse: {
      choices: [{ message: { content: "", reasoning_content: "想了很久" }, finish_reason: "stop" }],
    },
  });
  const res = await worker.fetch(makeRequest("/v1/dispute/evaluate", { systemPrompt: "s", userMessage: "x" }), env);
  check("返回 502", res.status === 502, `实际 ${res.status}`);
}

console.log("\n[上游返回非 200]");
{
  const { env } = makeEnv({ status: 500 });
  const res = await worker.fetch(makeRequest("/v1/dispute/evaluate", { systemPrompt: "s", userMessage: "x" }), env);
  check("返回 502", res.status === 502, `实际 ${res.status}`);
  const data = await res.json();
  check("不把上游原文整段抛给客户端", !JSON.stringify(data).includes("upstream error detail"));
}

console.log("\n[模型返回空内容]");
{
  const { env } = makeEnv({ modelResponse: okResponse("   ") });
  const res = await worker.fetch(makeRequest("/v1/dispute/evaluate", { systemPrompt: "s", userMessage: "x" }), env);
  check("返回 502", res.status === 502, `实际 ${res.status}`);
}

console.log("\n[未配置上游密钥]");
{
  const { env } = makeEnv();
  env.SOPHNET_API_KEY = "";
  const res = await worker.fetch(makeRequest("/v1/dispute/evaluate", { systemPrompt: "s", userMessage: "x" }), env);
  check("返回 500", res.status === 500, `实际 ${res.status}`);
}

console.log("\n[未知端点]");
{
  const { env } = makeEnv();
  const res = await worker.fetch(makeRequest("/v1/nope", {}), env);
  check("返回 404", res.status === 404);
}

console.log("\n[非 POST 方法]");
{
  const { env } = makeEnv();
  const res = await worker.fetch(new Request("https://proxy.test/v1/assist"), env);
  check("返回 405", res.status === 405);
}

console.log("\n[请求体过大]");
{
  const { env } = makeEnv();
  const res = await worker.fetch(
    makeRequest("/v1/assist", { tool: "conflict", input: "x" }, { "content-length": "999999" }),
    env
  );
  check("返回 413", res.status === 413, `实际 ${res.status}`);
}

console.log("\n[按 IP 每日配额]");
{
  // 必须给一个正常的模型响应：配额用例关心的是"第 31 次被挡"，
  // 若上游反而报错，最后拿到的 502 会被误读成"配额没生效"。
  const { env } = makeEnv({ modelResponse: okResponse("ok") });
  let lastStatus = 200;
  for (let i = 0; i < 31; i++) {
    const res = await worker.fetch(makeRequest("/v1/assist", { tool: "conflict", input: "x" }), env);
    lastStatus = res.status;
  }
  check("第 31 次被挡下", lastStatus === 429, `实际 ${lastStatus}`);

  const other = await worker.fetch(
    makeRequest("/v1/assist", { tool: "conflict", input: "x" }, { "CF-Connecting-IP": "9.9.9.9" }),
    env
  );
  check("换 IP 可绕过（说明它只防滥用，不是鉴权）", other.status === 200, `实际 ${other.status}`);
}

console.log("\n[配额存储不可用时放行]");
{
  const { env } = makeEnv({ modelResponse: okResponse("x") });
  const saved = globalThis.caches;
  globalThis.caches = undefined;
  const res = await worker.fetch(makeRequest("/v1/assist", { tool: "conflict", input: "x" }), env);
  globalThis.caches = saved;
  check("cache 缺失不该让服务整体不可用", res.status === 200, `实际 ${res.status}`);
}

console.log("\n[提示词立场]");
{
  const { env, calls } = makeEnv({ modelResponse: okResponse("x") });
  await worker.fetch(makeRequest("/v1/assist", { tool: "apology", input: "x" }), env);
  const prompt = calls[0].body.messages[0].content;
  check("道歉提示词禁止给成品", prompt.includes("不要写一段可以复制粘贴的道歉"));
  check("道歉提示词追问具体损失", prompt.includes("对方因此失去了什么"));
  check("提示词里没有打分要求", !prompt.includes("评分") && !prompt.includes("打分"));
}

console.log("\n[分析提示词与客户端枚举一致]");
{
  const { env, calls } = makeEnv({ modelResponse: okResponse("{}") });
  await worker.fetch(
    makeRequest("/v1/relationship/analyze", analyzeBody({ conversation: "abc" })),
    env
  );
  const prompt = calls[0].body.messages[0].content;
  check("emotionalTrend 用「稳定」而不是「平稳」", prompt.includes("上升 / 稳定 / 下降"));
  check("communicationQuality 用「优秀」", prompt.includes("优秀 / 良好 / 一般 / 需要改善"));
  check("信息不足时允许省略 score", prompt.includes("省略 score"));
}

// ---------------------------------------------------------------------------

console.log(`\n${"─".repeat(50)}`);
console.log(`通过 ${passed} 项，失败 ${failed} 项`);
if (failed > 0) process.exit(1);
console.log("全部通过\n");
