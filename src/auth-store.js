const crypto = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");

const AUTH_PATH = path.join(__dirname, "..", ".voicerelay-auth.json");
const SESSION_COOKIE = "vr_session";
const TEN_YEARS = 60 * 60 * 24 * 365 * 10;

function newSecret(bytes = 32) {
  return crypto.randomBytes(bytes).toString("base64url");
}

function hashPassword(password, salt = newSecret(16)) {
  const hash = crypto.scryptSync(password, salt, 32).toString("base64url");
  return { salt, hash };
}

function timingSafeEqualString(a, b) {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

async function readAuthConfig() {
  const raw = await fs.readFile(AUTH_PATH, "utf8");
  return JSON.parse(raw);
}

async function writeAuthConfig(config) {
  const body = `${JSON.stringify(config, null, 2)}\n`;
  const tempPath = `${AUTH_PATH}.tmp`;
  await fs.writeFile(tempPath, body, { mode: 0o600 });
  await fs.rename(tempPath, AUTH_PATH);
  await fs.chmod(AUTH_PATH, 0o600);
}

async function ensureAuthConfig() {
  try {
    return { config: await readAuthConfig(), createdPassword: null };
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const password = newSecret(12);
  const passwordHash = hashPassword(password);
  const now = new Date().toISOString();
  const config = {
    version: 1,
    passwordSalt: passwordHash.salt,
    passwordHash: passwordHash.hash,
    sessionSecret: newSecret(),
    createdAt: now,
    updatedAt: now,
  };

  await writeAuthConfig(config);
  return { config, createdPassword: password };
}

async function verifyPassword(password) {
  const config = await readAuthConfig();
  const candidate = hashPassword(password, config.passwordSalt);
  return timingSafeEqualString(candidate.hash, config.passwordHash);
}

function signPayload(payload, secret) {
  return crypto.createHmac("sha256", secret).update(payload).digest("base64url");
}

function createSessionCookie(config, options = {}) {
  const secure = options.secure === false ? "" : "; Secure";
  const payload = Buffer.from(JSON.stringify({ iat: Date.now(), v: 1 })).toString("base64url");
  const signature = signPayload(payload, config.sessionSecret);
  return `${SESSION_COOKIE}=${payload}.${signature}; Path=/; Max-Age=${TEN_YEARS}; HttpOnly; SameSite=Lax${secure}`;
}

function clearSessionCookie(options = {}) {
  const secure = options.secure === false ? "" : "; Secure";
  return `${SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax${secure}`;
}

function parseCookies(header = "") {
  return Object.fromEntries(
    header
      .split(";")
      .map((item) => item.trim())
      .filter(Boolean)
      .map((item) => {
        const index = item.indexOf("=");
        if (index === -1) return [item, ""];
        return [item.slice(0, index), decodeURIComponent(item.slice(index + 1))];
      }),
  );
}

async function verifySession(req) {
  const cookies = parseCookies(req.headers.cookie);
  const token = cookies[SESSION_COOKIE];
  if (!token || !token.includes(".")) return false;

  const [payload, signature] = token.split(".");
  const config = await readAuthConfig();
  const expected = signPayload(payload, config.sessionSecret);
  return timingSafeEqualString(signature, expected);
}

async function resetSessions() {
  const config = await readAuthConfig();
  config.sessionSecret = newSecret();
  config.updatedAt = new Date().toISOString();
  await writeAuthConfig(config);
}

async function resetPassword() {
  const config = await readAuthConfig().catch(() => null);
  const password = newSecret(12);
  const passwordHash = hashPassword(password);
  const now = new Date().toISOString();
  const nextConfig = {
    version: 1,
    passwordSalt: passwordHash.salt,
    passwordHash: passwordHash.hash,
    sessionSecret: newSecret(),
    createdAt: config?.createdAt || now,
    updatedAt: now,
  };

  await writeAuthConfig(nextConfig);
  return password;
}

module.exports = {
  AUTH_PATH,
  clearSessionCookie,
  createSessionCookie,
  ensureAuthConfig,
  resetPassword,
  resetSessions,
  verifyPassword,
  verifySession,
};
