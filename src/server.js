const { execFile, spawn } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const fs = require("node:fs/promises");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const {
  clearSessionCookie,
  createSessionCookie,
  ensureAuthConfig,
  verifyPassword,
  verifySession,
} = require("./auth-store");

const PORT = Number(process.env.PORT || 5454);
const HOST = process.env.HOST || "127.0.0.1";
const PUBLIC_URL =
  process.env.PUBLIC_URL ||
  (process.env.PUBLIC_HOST ? `https://${process.env.PUBLIC_HOST}/` : `http://${HOST}:${PORT}/`);
const SYNC_DEBOUNCE_MS = Number(process.env.SYNC_DEBOUNCE_MS || 180);
const publicDir = path.join(__dirname, "..", "public");
const dataPath = process.env.VOICE_RELAY_DATA_PATH || path.join(__dirname, "..", ".voicerelay-data.json");
const macInputWriterPath = process.env.MAC_INPUT_WRITER_PATH || path.join(__dirname, "..", "bin", "mac-input-writer");
const defaultTypingCharsPerMinute = Number(process.env.TYPING_CHARS_PER_MINUTE || 60);
const maxHistoryItems = Number(process.env.MAX_HISTORY_ITEMS || 50);

let latestText = "";
let latestRevision = 0;
let writerProcess = null;
let writerStdoutBuffer = "";
let writerPending = [];
let dataMutationQueue = Promise.resolve();

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  res.end(body);
}

function emptyRelayData() {
  return {
    history: [],
    stats: {
      sendCount: 0,
      sentChars: 0,
      manualInputMs: 0,
      actualInputMs: 0,
      savedMs: 0,
    },
    currentInput: {
      chars: 0,
      actualInputMs: 0,
      manualInputMs: 0,
      savedMs: 0,
      updatedAt: 0,
    },
    typingCharsPerMinute: defaultTypingCharsPerMinute,
    updatedAt: 0,
  };
}

function normalizeRelayData(data) {
  const fallback = emptyRelayData();
  const stats = data?.stats || {};
  const current = data?.currentInput || {};
  return {
    history: Array.isArray(data?.history) ? data.history.filter((item) => typeof item === "string").slice(0, maxHistoryItems) : [],
    stats: {
      sendCount: Number.isFinite(stats.sendCount) ? stats.sendCount : 0,
      sentChars: Number.isFinite(stats.sentChars) ? stats.sentChars : 0,
      manualInputMs: Number.isFinite(stats.manualInputMs) ? stats.manualInputMs : 0,
      actualInputMs: Number.isFinite(stats.actualInputMs) ? stats.actualInputMs : 0,
      savedMs: Number.isFinite(stats.savedMs) ? stats.savedMs : 0,
    },
    currentInput: {
      chars: Number.isFinite(current.chars) ? current.chars : 0,
      actualInputMs: Number.isFinite(current.actualInputMs) ? current.actualInputMs : 0,
      manualInputMs: Number.isFinite(current.manualInputMs) ? current.manualInputMs : 0,
      savedMs: Number.isFinite(current.savedMs) ? current.savedMs : 0,
      updatedAt: Number.isFinite(current.updatedAt) ? current.updatedAt : 0,
    },
    typingCharsPerMinute: Number.isFinite(data?.typingCharsPerMinute) && data.typingCharsPerMinute > 0
      ? data.typingCharsPerMinute
      : fallback.typingCharsPerMinute,
    updatedAt: Number.isFinite(data?.updatedAt) ? data.updatedAt : 0,
  };
}

async function readRelayData() {
  try {
    const raw = await fs.readFile(dataPath, "utf8");
    return normalizeRelayData(JSON.parse(raw));
  } catch (error) {
    if (error.code === "ENOENT") return emptyRelayData();
    if (error instanceof SyntaxError) return recoverRelayData(error);
    throw error;
  }
}

async function recoverRelayData(parseError) {
  const raw = await fs.readFile(dataPath, "utf8");
  const end = findFirstJsonObjectEnd(raw);
  if (end === -1) throw parseError;

  const suffix = raw.slice(end).trim();
  if (!suffix) throw parseError;

  const recovered = normalizeRelayData(JSON.parse(raw.slice(0, end)));
  await writeRelayDataFile(recovered);
  console.error(`统计数据文件尾部残留已自动修复: ${parseError.message}`);
  return recovered;
}

function findFirstJsonObjectEnd(raw) {
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = 0; index < raw.length; index += 1) {
    const char = raw[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === "\"") {
        inString = false;
      }
      continue;
    }

    if (char === "\"") {
      inString = true;
    } else if (char === "{") {
      depth += 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0) return index + 1;
    }
  }

  return -1;
}

async function writeRelayDataFile(data) {
  const normalized = normalizeRelayData({ ...data, updatedAt: Date.now() });
  const tempPath = `${dataPath}.${process.pid}.${randomUUID()}.tmp`;
  await fs.writeFile(tempPath, `${JSON.stringify(normalized, null, 2)}\n`, { mode: 0o600 });
  await fs.rename(tempPath, dataPath);
  await fs.chmod(dataPath, 0o600);
  return normalized;
}

async function mutateRelayData(mutator) {
  const task = dataMutationQueue.then(async () => {
    const data = await readRelayData();
    const nextData = await mutator(data);
    return writeRelayDataFile(nextData || data);
  });

  dataMutationQueue = task.catch(() => {});
  return task;
}

function inputMetrics(text, inputDurationMs = 0, charsPerMinute = defaultTypingCharsPerMinute) {
  const chars = text.length;
  const actualInputMs = Math.max(0, Number(inputDurationMs) || 0);
  const manualInputMs = charsPerMinute > 0 ? (chars / charsPerMinute) * 60_000 : 0;
  return {
    chars,
    actualInputMs,
    manualInputMs,
    savedMs: Math.max(0, manualInputMs - actualInputMs),
  };
}

function addHistory(data, text) {
  if (!text) return data;
  data.history = [text, ...data.history.filter((item) => item !== text)].slice(0, maxHistoryItems);
  return data;
}

async function updateCurrentInput(text, inputDurationMs) {
  return mutateRelayData((data) => {
    data.currentInput = { ...inputMetrics(text, inputDurationMs, data.typingCharsPerMinute), updatedAt: Date.now() };
    return data;
  });
}

async function rememberSubmissionAttempt(text, inputDurationMs) {
  return mutateRelayData((data) => {
    addHistory(data, text);
    data.currentInput = { ...inputMetrics(text, inputDurationMs, data.typingCharsPerMinute), updatedAt: Date.now() };
    return data;
  });
}

async function recordSuccessfulSubmission(text, inputDurationMs) {
  return mutateRelayData((data) => {
    const metrics = inputMetrics(text, inputDurationMs, data.typingCharsPerMinute);
    data.stats.sendCount += 1;
    data.stats.sentChars += metrics.chars;
    data.stats.actualInputMs += metrics.actualInputMs;
    data.stats.manualInputMs += metrics.manualInputMs;
    data.stats.savedMs = Math.max(0, data.stats.manualInputMs - data.stats.actualInputMs);
    data.currentInput = { ...inputMetrics("", 0, data.typingCharsPerMinute), updatedAt: Date.now() };
    return data;
  });
}

async function clearHistory() {
  return mutateRelayData((data) => {
    data.history = [];
    return data;
  });
}

async function resetStats() {
  return mutateRelayData((data) => {
    data.stats = emptyRelayData().stats;
    data.currentInput = { ...inputMetrics("", 0, data.typingCharsPerMinute), updatedAt: Date.now() };
    return data;
  });
}

function shouldUseSecureCookie(req) {
  const host = req.headers.host || "";
  return !host.startsWith("127.0.0.1") && !host.startsWith("localhost");
}

function readBody(req, limit = 512 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("请求体过大"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function execFilePromise(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    execFile(command, args, options, (error, stdout, stderr) => {
      if (error) {
        error.stderr = stderr;
        reject(error);
        return;
      }
      resolve(stdout);
    });
  });
}

function pipeToCommand(command, args, text) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`${command} 退出码 ${code}: ${stderr}`));
    });
    child.stdin.end(text);
  });
}

async function setFocusedFieldValue(text) {
  await execFilePromise("osascript", [
    "-e",
    "on run argv",
    "-e",
    "set newText to item 1 of argv",
    "-e",
    'tell application "System Events"',
    "-e",
    "set frontProcess to first application process whose frontmost is true",
    "-e",
    'set focusedElement to value of attribute "AXFocusedUIElement" of frontProcess',
    "-e",
    'set roleName to value of attribute "AXRole" of focusedElement',
    "-e",
    'if roleName is "AXTextField" or roleName is "AXTextArea" or roleName is "AXComboBox" then',
    "-e",
    "set value of focusedElement to newText",
    "-e",
    "else",
    "-e",
    'error "当前焦点不是可编辑文本框: " & roleName',
    "-e",
    "end if",
    "-e",
    "end tell",
    "-e",
    "end run",
    text,
  ]);
}

async function writeWithMacInputWriter(text) {
  await fs.access(macInputWriterPath);
  const writer = ensureMacInputWriter();
  const payload = Buffer.from(text, "utf8").toString("base64");
  return sendWriterCommand(writer, payload);
}

async function pasteWithMacInputWriter(text) {
  await fs.access(macInputWriterPath);
  const writer = ensureMacInputWriter();
  const payload = Buffer.from(text, "utf8").toString("base64");
  return sendWriterCommand(writer, `PASTE ${payload}`);
}

async function insertPasteWithMacInputWriter(text) {
  await fs.access(macInputWriterPath);
  const writer = ensureMacInputWriter();
  const payload = Buffer.from(text, "utf8").toString("base64");
  return sendWriterCommand(writer, `INSERT_PASTE ${payload}`);
}

async function submitWithMacInputWriter() {
  await fs.access(macInputWriterPath);
  const writer = ensureMacInputWriter();
  return sendWriterCommand(writer, "SUBMIT");
}

function sendWriterCommand(writer, command) {
  return new Promise((resolve, reject) => {
    writerPending.push({ resolve, reject });
    writer.stdin.write(`${command}\n`, "utf8", (error) => {
      if (!error) return;
      const pending = writerPending.pop();
      pending?.reject(error);
    });
  });
}

async function writeIntoFocusedField(text) {
  await writeWithMacInputWriter(text);
}

async function submitFocusedField() {
  await submitWithMacInputWriter();
}

async function replaceFocusedFieldForSubmit(text) {
  if (text.includes("\n")) {
    await pasteWithMacInputWriter(text);
    return;
  }
  await writeWithMacInputWriter(text);
}

async function insertIntoFocusedFieldForSubmit(text) {
  await insertPasteWithMacInputWriter(text);
}

function ensureMacInputWriter() {
  if (writerProcess && !writerProcess.killed) return writerProcess;

  writerStdoutBuffer = "";
  writerPending = [];
  writerProcess = spawn(macInputWriterPath, ["--daemon"], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  writerProcess.stdout.on("data", (chunk) => {
    writerStdoutBuffer += chunk.toString("utf8");
    const lines = writerStdoutBuffer.split(/\r?\n/);
    writerStdoutBuffer = lines.pop() || "";

    for (const line of lines) {
      if (!line) continue;
      const pending = writerPending.shift();
      if (!pending) continue;

      if (line === "OK") {
        pending.resolve();
      } else {
        pending.reject(new Error(line));
      }
    }
  });

  writerProcess.stderr.on("data", (chunk) => {
    console.error("mac-input-writer:", chunk.toString("utf8").trim());
  });

  writerProcess.on("exit", (code, signal) => {
    const error = new Error(`mac-input-writer 已退出 code=${code} signal=${signal}`);
    for (const pending of writerPending.splice(0)) {
      pending.reject(error);
    }
    writerProcess = null;
  });

  writerProcess.on("error", (error) => {
    for (const pending of writerPending.splice(0)) {
      pending.reject(error);
    }
    writerProcess = null;
  });

  return writerProcess;
}

async function serveStatic(req, res, url) {
  const safePath = url.pathname === "/" ? "/index.html" : decodeURIComponent(url.pathname);
  const filePath = path.normalize(path.join(publicDir, safePath));

  if (!filePath.startsWith(publicDir)) {
    res.writeHead(403).end("Forbidden");
    return;
  }

  try {
    const data = await fs.readFile(filePath);
    const ext = path.extname(filePath);
    res.writeHead(200, {
      "content-type": mimeTypes[ext] || "application/octet-stream",
      "cache-control": ext === ".html" ? "no-store" : "public, max-age=3600",
    });
    res.end(data);
  } catch (error) {
    if (error.code === "ENOENT") {
      res.writeHead(404).end("Not found");
      return;
    }
    console.error(error);
    res.writeHead(500).end("Server error");
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || `${HOST}:${PORT}`}`);

  if (req.method === "GET" && url.pathname === "/api/auth/status") {
    sendJson(res, 200, { ok: true, authenticated: await verifySession(req) });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/auth/login") {
    try {
      const raw = await readBody(req, 16 * 1024);
      const payload = JSON.parse(raw || "{}");
      const password = typeof payload.password === "string" ? payload.password : "";

      if (!(await verifyPassword(password))) {
        sendJson(res, 401, { ok: false, error: "unauthorized" });
        return;
      }

      const { config } = await ensureAuthConfig();
      const body = JSON.stringify({ ok: true });
      res.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "content-length": Buffer.byteLength(body),
        "cache-control": "no-store",
        "set-cookie": createSessionCookie(config, { secure: shouldUseSecureCookie(req) }),
      });
      res.end(body);
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/auth/logout") {
    const body = JSON.stringify({ ok: true });
    res.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "content-length": Buffer.byteLength(body),
      "cache-control": "no-store",
      "set-cookie": clearSessionCookie({ secure: shouldUseSecureCookie(req) }),
    });
    res.end(body);
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/status") {
    sendJson(res, 200, {
      ok: true,
      publicUrl: PUBLIC_URL,
      authenticated: await verifySession(req),
      latestRevision,
      latestLength: latestText.length,
      platform: os.platform(),
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/history") {
    if (!(await verifySession(req))) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    try {
      sendJson(res, 200, { ok: true, ...(await readRelayData()) });
    } catch (error) {
      console.error("读取统计失败:", error.message);
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/draft") {
    if (!(await verifySession(req))) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    try {
      const raw = await readBody(req);
      const payload = JSON.parse(raw || "{}");
      const text = typeof payload.text === "string" ? payload.text : "";
      const inputDurationMs = Number.isFinite(payload.inputDurationMs) ? payload.inputDurationMs : 0;
      sendJson(res, 200, { ok: true, ...(await updateCurrentInput(text, inputDurationMs)) });
    } catch (error) {
      console.error("暂存本次输入统计失败:", error.message);
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/history/clear") {
    if (!(await verifySession(req))) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    try {
      sendJson(res, 200, { ok: true, ...(await clearHistory()) });
    } catch (error) {
      console.error("清空发送历史失败:", error.message);
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/stats/reset") {
    if (!(await verifySession(req))) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    try {
      sendJson(res, 200, { ok: true, ...(await resetStats()) });
    } catch (error) {
      console.error("重置统计失败:", error.message);
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/sync") {
    if (!(await verifySession(req))) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    try {
      const raw = await readBody(req);
      const payload = JSON.parse(raw || "{}");
      const text = typeof payload.text === "string" ? payload.text : "";
      const revision = Number.isFinite(payload.revision) ? payload.revision : Date.now();
      const inputDurationMs = Number.isFinite(payload.inputDurationMs) ? payload.inputDurationMs : 0;

      latestText = text;
      latestRevision = revision;
      const relayData = await updateCurrentInput(text, inputDurationMs);
      await writeIntoFocusedField(text);
      console.log(`已同步 revision=${revision} chars=${text.length}`);
      sendJson(res, 200, { ok: true, revision, length: text.length, ...relayData });
    } catch (error) {
      console.error("同步到当前焦点失败:", error.stderr || error.message);
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/submit") {
    if (!(await verifySession(req))) {
      sendJson(res, 401, { ok: false, error: "unauthorized" });
      return;
    }

    try {
      const raw = await readBody(req);
      const payload = JSON.parse(raw || "{}");
      const text = typeof payload.text === "string" ? payload.text : "";
      const revision = Number.isFinite(payload.revision) ? payload.revision : Date.now();
      const inputMode = payload.mode === "send" ? "send" : "realtime";
      const inputDurationMs = Number.isFinite(payload.inputDurationMs) ? payload.inputDurationMs : 0;

      latestText = text;
      latestRevision = revision;
      await rememberSubmissionAttempt(text, inputDurationMs);
      if (inputMode === "send") {
        await insertIntoFocusedFieldForSubmit(text);
      } else {
        await replaceFocusedFieldForSubmit(text);
      }
      await submitFocusedField();
      const relayData = await recordSuccessfulSubmission(text, inputDurationMs);
      console.log(`已发送 revision=${revision} mode=${inputMode} chars=${text.length}`);
      sendJson(res, 200, { ok: true, revision, length: text.length, mode: inputMode, submitted: true, ...relayData });
    } catch (error) {
      console.error("提交当前焦点失败:", error.stderr || error.message);
      sendJson(res, 500, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "GET" || req.method === "HEAD") {
    await serveStatic(req, res, url);
    return;
  }

  res.writeHead(405, { allow: "GET, HEAD, POST" }).end("Method not allowed");
});

ensureAuthConfig()
  .then(({ createdPassword }) => {
    server.listen(PORT, HOST, () => {
      console.log("VoiceRelay 已启动");
      console.log(`本地地址: http://${HOST}:${PORT}/`);
      console.log(`访问地址: ${PUBLIC_URL}`);
      if (createdPassword) {
        console.log(`首次认证密码: ${createdPassword}`);
      } else {
        console.log("认证密码已存在；需要重置请运行 npm run auth:reset");
      }
      console.log("清除手机端登录状态: npm run auth:clear");
      console.log("使用前请把 Mac 输入焦点放到目标文本框，并给运行终端授予“辅助功能”权限。");
    });
  })
  .catch((error) => {
    console.error("启动失败:", error.message);
    process.exitCode = 1;
  });
