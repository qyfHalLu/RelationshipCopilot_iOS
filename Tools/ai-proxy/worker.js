/**
 * 关系副驾 · AI 代理（Cloudflare Worker）
 *
 * ## 这个文件解决什么
 *
 * App 的 Release 构建里**不允许携带第三方模型密钥**（`EndpointConfiguration`
 * 的原则）。但内测又必须有可用的 AI。所以中间加一层：
 *
 *     App ──▶ 这个 Worker ──▶ SophNet
 *             （密钥只在这里）
 *
 * ## 部署
 *
 *     cd Tools/ai-proxy
 *     npx wrangler secret put SOPHNET_API_KEY   # 粘贴 SophNet 的 key
 *     npx wrangler secret put APP_TOKEN         # 自己定一个随机串
 *     npx wrangler deploy
 *
 * 然后把输出的地址（https://xxx.workers.dev，末尾不带斜杠）填进 App 的
 * `App/Info.plist` → `RCProxyBaseURL`，再把同一个 APP_TOKEN 填进 App 的
 * 设置页「内测代理令牌」（它存进 Keychain）。
 *
 * ## 请求/响应契约
 *
 * **这个契约的唯一权威是 `Services/AIService.swift`**，不是这份文件的注释。
 * 字段名改过一次（`transcript` → `conversation`）而测试没抓到，因为测试
 * 自己写的是旧名字 —— 于是"18 项全绿"的代理对上真实客户端是 100% 400。
 * 现在 `contract.test.mjs` 直接读 Swift 源码比对字段名，两边不可能再漂。
 *
 *   POST /v1/assist               {tool, input}                      → {text}
 *   POST /v1/dispute/evaluate     {systemPrompt, userMessage, ...}   → {text}
 *   POST /v1/relationship/analyze {conversation, counterpartName,
 *                                  relationshipType}                → {analysis}
 *   GET  /health                                                    → {ok, model}
 *
 * ## 为什么响应统一包成 {text}
 *
 * App 侧同时接受 `{text}` 和 OpenAI 的 `{choices:[{message:{content}}]}`。
 * 但直接透传上游 JSON 会把 `reasoning_content`、`usage`、错误堆栈一并送回
 * 客户端 —— 那些对 App 没用，还可能泄露上游信息。只回 `{text}` 是最小暴露面。
 */

const UPSTREAM = "https://www.sophnet.com/api/open-apis/v1/chat/completions";
const MODEL = "DeepSeek-V4.1-Flash-1017";

// 评理邀请（跨设备填写）。独立模块，理由见 `invite.js` 顶部注释 ——
// 它有自己的鉴权规则（对方网页没有 App 令牌）和独立的存储（KV）。
import { handleInvite } from "./invite.js";

/**
 * 推理模型的 token 预算。
 *
 * ## 这个数字是被一次真实故障逼出来的
 *
 * 评理原本设 1200，结果 `reasoning_content` 吃掉 951，正文只剩 249，
 * JSON 被截在半句话上，`finish_reason` 是 `length` —— 而客户端当时
 * 根本不读这一栏，于是表现为"格式漂移"，100% 走降级且没有任何报错。
 *
 * 3500 是实测余量（最坏观测 reasoning 1423 + content 473），
 * 且必须与客户端 `DisputePrompt.maxOutputTokens` 一致 —— 契约测试会盯。
 */
const MAX_TOKENS = {
  assist: 900,
  dispute: 3500,
  analyze: 1200,
};

/** 单次请求体上限。评理四题各 200 字，正常远低于此。 */
const MAX_BODY_BYTES = 64 * 1024;

/** 录音转录上限。超过这个长度，模型很难给出有用的分析，不如直接拒绝。 */
const MAX_TRANSCRIPT_CHARS = 20000;

/** 工具输入上限。 */
const MAX_INPUT_CHARS = 4000;

/** 每个 IP 每天的请求上限。内测期够用，且能挡住密钥被拿去跑别的用途。 */
const DAILY_LIMIT_PER_IP = 30;

// ---------------------------------------------------------------------------
// 系统提示词
//
// 评理的提示词**由 App 传上来**（`systemPrompt`）—— 它依赖用户填写的四格
// 内容与双方证词，服务端无法独立生成。这里不复制一份，复制必然漂移。
//
// 快速工具的提示词在这里：assist 端点只收到 `tool` 名字和用户输入，
// 不传提示词（否则客户端能改提示词）。代价是两边要同步 —— 所以
// `Tests/QuickToolTests.swift` 有断言盯着产物不许是成品。
// ---------------------------------------------------------------------------

/**
 * 三个工具共用的底线。
 *
 * 注意这里**没有**"给出可以直接使用的原话"这一条。客户端
 * `QuickToolKind.systemPrompt` 的 common 里有它，但对 phrase / apology 而言
 * 它和任务正文直接冲突（正文是「不要给用户一段可以复制粘贴的话」）。
 * 一条自相矛盾的提示词会让模型在两种行为之间摇摆。
 *
 * `conflict` 想要原话，所以它自己带上了这一条。
 */
const SHARED_RULES = `你是一位务实的关系沟通教练。要求：
1. 只基于用户提供的信息回答，信息不足时明确说明"信息不足，需要更多细节"，不要编造。
2. 不要说教、不要长篇大论，输出不超过 220 字。
3. 不提供心理诊断、医疗或法律建议。若涉及自伤、暴力、虐待，优先建议寻求专业帮助与紧急支持。
4. 用简体中文，分点但不使用复杂格式。`;

const TOOL_PROMPTS = {
  conflict: `${SHARED_RULES}
5. 给出可以直接使用的原话，而不是"应该多沟通"这类空话。

任务：帮用户把这次争执理清楚。**你只读到用户一个人的视角**，
因此不得猜测对方怎么想、不得判断谁对谁错、不得分配责任。
输出四段：
【你当时遇到的是什么】用一句话中立复述用户描述的事实
【真正卡住你的那一点】从用户的描述里指出最难受的那一处
【你今晚可以说的一句】给 1 句第一人称的话，不指责对方
【你自己能做的一件事】给 1 个只依赖用户自己的具体动作
如果用户想两个人一起把这件事说清，提示用户去「评理」入口，各写一份。`,

  phrase: `${SHARED_RULES}

任务：帮用户准备「这次要怎么开口」，**不要给用户一段可以复制粘贴的话**。

为什么：如果对方发现这段是 AI 写的，会比用户原本说不出口更糟 ——
那意味着"你连跟我说句话都要别人代笔"。你的作用是帮用户想清楚，不是替用户说。

输出三段：
【你想要的是什么】一句话，用"我希望……"的口吻，具体到可以答应或拒绝
【对方可能在意什么】一句话，只给可能性，用"TA 可能会觉得……"而不是断言
【最坏的情况你怎么接】一句话，让用户知道就算被拒绝也不会崩

最后给一句**故意粗糙的示范**：短句、口语、可以不完整，
像人脱口而出的那种，不要写成文案。
示范前面明确写"粗糙示范，改成你自己的说法"。`,

  apology: `${SHARED_RULES}

任务：帮用户弄清楚「这次道歉到底在道什么」，**不要写一段可以复制粘贴的道歉**。

为什么：一段 AI 写好的道歉，即使文字完美，也绕过了真正重要的那一步 ——
理解自己伤到了对方哪里。而对方要的恰恰是那一步。
被识破时它还会变成二次伤害："你连道歉都不肯自己说。"

输出三段，每段一句话，不写成完整段落：
【你具体做了什么】只写行为，不写动机，不要加"但是"
【对方因此失去了什么】这是最容易漏掉的一段：不是"让对方不开心"，
而是具体的损失 —— 白等的时间、被辜负的期待、在别人面前丢掉的面子、
之后再也不敢开口的那件事
【你能承诺什么】必须是你做得到的具体动作，不是"以后注意"

结尾给一句提醒：想清楚这三件事，用你自己的话说。不用漂亮，真实比漂亮有用。`,
};

/**
 * 录音分析的提示词。
 *
 * 枚举值必须与客户端 `AIService.systemPrompt` 一致：
 * `emotionalTrend` 是「上升 / 稳定 / 下降」，`communicationQuality` 是
 * 「优秀 / 良好 / 一般 / 需要改善」。用别的词不会崩，但同一次分析在
 * 直连（调试）与代理（内测）两条路上会显示不同的字。
 */
const ANALYSIS_PROMPT = `你是一位关系沟通分析助手。基于用户提供的对话转录，输出一份结构化分析。

严格要求：
1. 只基于转录内容，不得编造未出现的信息。转录太短或信息不足时，在 summary 里直说，
   并且**省略 score 字段**，不要猜一个看起来合理的分数。
2. 不提供心理诊断、医疗或法律建议。
3. 用简体中文。
4. **只输出 JSON**，不要 markdown 代码块，不要任何解释文字。
5. 若转录中出现自伤、暴力、虐待迹象，只输出：
   {"summary":"这段内容涉及安全风险，不适合做沟通分析。","strengths":[],"improvements":[],"suggestions":["如果你正处在危险中，请联系当地紧急服务或专业机构。"],"emotionalTrend":"下降","communicationQuality":"需要改善"}

JSON 结构：
{
  "score": 0-100 的整数（沟通质量，不是关系好坏；信息不足时省略本字段）,
  "summary": "两句话以内的总体判断",
  "strengths": ["具体的积极表现，最多 3 条"],
  "improvements": ["具体可改的地方，最多 3 条"],
  "suggestions": ["可以直接做的动作，最多 3 条"],
  "emotionalTrend": "上升 / 稳定 / 下降",
  "communicationQuality": "优秀 / 良好 / 一般 / 需要改善"
}`;

// MARK: - 工具

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      // 不设 CORS：这个 Worker 只给原生 App 用，不需要浏览器跨域。
      // 开着反而让别人的网页也能拿你的额度。
      "cache-control": "no-store",
    },
  });
}

function fail(message, status = 400) {
  return json({ error: { message } }, status);
}

/** 从上游响应里抽正文。`reasoning_content` 不计入正文。 */
function extractText(data) {
  const choice = data?.choices?.[0];

  if (choice?.finish_reason === "length") {
    // 必须显式报这个错。否则表现为"JSON 解析失败"，排查时想不到是预算不够。
    throw new Error("模型输出被 max_tokens 截断，请缩短输入或提高预算");
  }

  const content = choice?.message?.content;
  if (typeof content === "string" && content.trim()) return content.trim();

  const reasoning = choice?.message?.reasoning_content;
  if (typeof reasoning === "string" && reasoning.trim()) {
    // 只有推理没有正文：说明预算几乎全被 reasoning 吃了。
    throw new Error("模型只返回了推理过程，正文为空（预算不足）");
  }

  throw new Error("上游返回了空内容");
}

/**
 * 容错解析：模型常把 JSON 包在 ```json 里，或前后带一句解释。
 *
 * 解析失败返回 null，**不要在这里编一份看起来正常的分析** ——
 * 「对任何人都输出 72 分」是这个产品早期最容易犯的错。
 */
function parseJsonLoosely(text) {
  const cleaned = String(text)
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/```\s*$/, "")
    .trim();

  try {
    return JSON.parse(cleaned);
  } catch {
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(cleaned.slice(start, end + 1));
      } catch {
        return null;
      }
    }
    return null;
  }
}

async function callModel(env, { system, user, maxTokens, temperature }) {
  const response = await fetch(UPSTREAM, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.SOPHNET_API_KEY}`,
    },
    body: JSON.stringify({
      model: env.MODEL || MODEL,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      temperature,
      max_tokens: maxTokens,
    }),
  });

  const raw = await response.text();

  if (!response.ok) {
    // 只回状态码，**不回上游 body**。
    //
    // 这里曾经是 `上游${status}：${raw.slice(0,200)}`，理由是"方便排查"。
    // 但那段 body 会原样进到 App 的错误提示里，而它可能包含内部路径、
    // 上游账号信息，甚至（某些网关的）回显头。排查信息应该去 Cloudflare
    // 的 `wrangler tail` 里看，不该走客户端的用户可见路径。
    throw new Error(`上游返回 ${response.status}`);
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new Error("上游返回的不是 JSON");
  }

  if (data?.error?.message) throw new Error(String(data.error.message));

  return extractText(data);
}

// MARK: - 配额
//
// 用 Cache API 存计数，不引入 KV —— 内测期够用，且零额外配置。
//
// 这只防"顺手刷"，不防有意绕过（换 IP 即可）。真正的配额要靠账号，
// 而内测阶段没有账号体系。所以目标是**限制密钥被滥用**，不是计费。
//
// Cache 可能被驱逐，也可能在某些运行环境里不可用。任何一种情况都**放行**：
// 配额是尽力而为的软限制，不该因为它自己出问题就把服务变成不可用。

async function checkQuota(request) {
  try {
    const cache = caches?.default;
    if (!cache) return { allowed: true };

    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const day = new Date().toISOString().slice(0, 10);
    const key = new Request(`https://quota.internal/${ip}/${day}`, { method: "GET" });

    const hit = await cache.match(key);
    const used = hit ? Number(await hit.text()) || 0 : 0;

    if (used >= DAILY_LIMIT_PER_IP) return { allowed: false, used };

    await cache.put(
      key,
      new Response(String(used + 1), { headers: { "cache-control": "max-age=86400" } })
    );
    return { allowed: true, used: used + 1 };
  } catch {
    return { allowed: true };
  }
}

// MARK: - 端点

async function handleAssist(body, env) {
  const tool = typeof body?.tool === "string" ? body.tool : "";
  const input = typeof body?.input === "string" ? body.input.trim() : "";

  if (!tool || !TOOL_PROMPTS[tool]) return fail(`未知工具：${tool}`, 400);
  if (!input) return fail("input 不能为空", 400);
  if (input.length > MAX_INPUT_CHARS) {
    return fail(`输入过长，请精简到 ${MAX_INPUT_CHARS} 字以内`, 413);
  }

  const text = await callModel(env, {
    system: TOOL_PROMPTS[tool],
    user: input,
    maxTokens: MAX_TOKENS.assist,
    temperature: 0.5,
  });

  return json({ text });
}

async function handleDispute(body, env) {
  const systemPrompt = typeof body?.systemPrompt === "string" ? body.systemPrompt : "";
  const userMessage = typeof body?.userMessage === "string" ? body.userMessage : "";

  if (!systemPrompt || !userMessage) {
    return fail("systemPrompt 与 userMessage 都不能为空", 400);
  }

  const requested = Number(body?.maxTokens);
  const maxTokens = Number.isFinite(requested) && requested > 0
    ? Math.min(requested, 8000)
    : MAX_TOKENS.dispute;

  const text = await callModel(env, {
    system: systemPrompt,
    user: userMessage,
    maxTokens,
    temperature: typeof body?.temperature === "number" ? body.temperature : 0.3,
  });

  return json({ text });
}

async function handleAnalyze(body, env) {
  // 字段名是 `conversation`。这里**不接受** `transcript` 之类的别名 ——
  // 别名会让"客户端改了字段名但服务端没改"这件事继续静默通过，
  // 而这个 bug 已经真实发生过一次。
  const conversation = typeof body?.conversation === "string" ? body.conversation.trim() : "";

  if (!conversation) return fail("conversation 不能为空", 400);
  if (conversation.length > MAX_TRANSCRIPT_CHARS) {
    return fail(`转录过长，请控制在 ${MAX_TRANSCRIPT_CHARS} 字以内`, 413);
  }

  const context = [
    body?.counterpartName ? `对话对象：${body.counterpartName}` : "",
    body?.relationshipType ? `关系类型：${body.relationshipType}` : "",
    "",
    "对话转录：",
    conversation,
  ]
    .filter(Boolean)
    .join("\n");

  const text = await callModel(env, {
    system: ANALYSIS_PROMPT,
    user: context,
    maxTokens: MAX_TOKENS.analyze,
    temperature: 0.3,
  });

  const analysis = parseJsonLoosely(text);
  if (!analysis) {
    // 解析失败时不要伪造一个看起来正常的分数，让客户端走它自己的降级路径。
    return fail("模型输出不是合法 JSON", 502);
  }

  return json({ analysis });
}

// MARK: - 入口

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // 健康检查放在最前面，且**允许 GET**。
    // 部署完第一件事是用浏览器打开一次看它活着没有；只允许 POST
    // 会让这一步变成"必须装 curl 才对"。
    if (url.pathname === "/health") {
      if (request.method !== "GET" && request.method !== "POST") {
        return fail("只接受 GET", 405);
      }
      return json({ ok: true, model: env?.MODEL || MODEL });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204 });
    }

    // 评理邀请放在令牌校验**之前**。
    //
    // 关键原因：对方是在自己手机浏览器里打开链接的普通人，手里没有、
    // 也不该有 App 的内测令牌。如果这段放在令牌后面，等于这个功能
    // 只对"已经装了 App 并配好令牌的人"可用 —— 那它就没有存在意义了。
    //
    // 这一路的防滥用靠 IP 配额 + caseId 位次上限 + 7 天 TTL，
    // 不靠令牌。细节见 `invite.js`。
    const inviteResponse = await handleInvite(request, url, env, checkQuota);
    if (inviteResponse) return inviteResponse;

    if (request.method !== "POST") {
      return fail("只接受 POST", 405);
    }

    if (!env?.SOPHNET_API_KEY) {
      return fail("服务端未配置 SOPHNET_API_KEY", 500);
    }

    // 共享令牌。
    //
    // 这不是真正的身份认证 —— 它的作用只是挡住"拿到地址就能白嫖额度"。
    // 令牌在 App 里，理论上可被逆向提取，所以**配额控制最终仍要服务端按账号做**；
    // 内测阶段用它省掉一次滥用就够了。
    //
    // 没配 APP_TOKEN 时直接拒绝服务，而不是悄悄放行：
    // 一个忘记配令牌就完全开放的代理，比没有代理更糟。
    if (!env.APP_TOKEN) {
      return fail("服务端未配置 APP_TOKEN，拒绝提供服务", 503);
    }
    if (request.headers.get("x-app-token") !== env.APP_TOKEN) {
      return fail("未授权", 401);
    }

    // 体量守卫要在读 body 之前做，避免大请求把内存吃满。
    const length = Number(request.headers.get("content-length") || "0");
    if (length > MAX_BODY_BYTES) {
      return fail("请求过大", 413);
    }

    const quota = await checkQuota(request);
    if (!quota.allowed) {
      return fail(`今天的使用次数已用完（${DAILY_LIMIT_PER_IP} 次），明天再来。`, 429);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return fail("请求体不是合法 JSON", 400);
    }

    try {
      switch (url.pathname) {
        case "/v1/assist":
          return await handleAssist(body, env);
        case "/v1/dispute/evaluate":
          return await handleDispute(body, env);
        case "/v1/relationship/analyze":
          return await handleAnalyze(body, env);
        default:
          return fail(`未知路径：${url.pathname}`, 404);
      }
    } catch (error) {
      // 只回消息，不回堆栈。
      return fail(error?.message || "服务端错误", 502);
    }
  },
};
