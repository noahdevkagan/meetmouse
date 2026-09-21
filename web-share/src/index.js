import viewerHTML from "./viewer.html";
import viewerCSS from "./viewer.css";
import viewerJS from "./viewer.js.txt";
import { shareIDFromPath, sha256Base64URL, validateCreateBody } from "./core.js";

export { shareIDFromPath, sha256Base64URL, validateCreateBody } from "./core.js";

const THIRTY_DAYS_SECONDS = 30 * 24 * 60 * 60;
const MAX_REQUEST_BYTES = 96 * 1024;

const securityHeaders = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

const contentSecurityPolicy = [
  "default-src 'none'",
  "connect-src 'self'",
  "img-src 'self' data:",
  "script-src 'self'",
  "style-src 'self'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
  "form-action 'none'",
].join("; ");

function response(body, status, headers = {}) {
  return new Response(body, {
    status,
    headers: { ...securityHeaders, ...headers },
  });
}

function json(value, status = 200) {
  return response(JSON.stringify(value), status, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
  });
}

function error(message, status) {
  return json({ error: message }, status);
}

function constantTimeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function createShare(request, env) {
  // This endpoint is intentionally account-free, so the Cloudflare client IP
  // is the only stable abuse-control key available. It is consumed by the
  // rate-limit binding and is never stored in D1 or application logs.
  const clientKey = request.headers.get("cf-connecting-ip") ?? "local-development";
  const limit = await env.CREATE_RATE_LIMITER.limit({ key: clientKey });
  if (!limit.success) return error("Too many private links. Try again shortly.", 429);

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_REQUEST_BYTES) return error("Encrypted note is too large.", 413);

  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_REQUEST_BYTES) {
    return error("Encrypted note is too large.", 413);
  }
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return error("Invalid JSON.", 400);
  }
  const invalid = validateCreateBody(body);
  if (invalid) return error(invalid, 400);

  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + THIRTY_DAYS_SECONDS;
  try {
    await env.DB.prepare(
      `INSERT INTO shared_notes
       (id, schema_version, nonce, ciphertext, revoke_hash, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
    ).bind(body.id, body.schemaVersion, body.nonce, body.ciphertext,
      body.revokeHash, now, expiresAt).run();
  } catch (cause) {
    if (String(cause).toLowerCase().includes("unique")) {
      return error("That private link already exists. Try again.", 409);
    }
    throw cause;
  }
  return json({ id: body.id, expiresAt }, 201);
}

async function readShare(id, env) {
  const row = await env.DB.prepare(
    `SELECT schema_version, nonce, ciphertext, expires_at
     FROM shared_notes WHERE id = ?1`,
  ).bind(id).first();
  if (!row || !row.ciphertext) return error("This private link was not found.", 404);

  const now = Math.floor(Date.now() / 1000);
  if (Number(row.expires_at) <= now) {
    await env.DB.prepare("DELETE FROM shared_notes WHERE id = ?1").bind(id).run();
    return error("This private link has expired.", 410);
  }
  return json({
    schemaVersion: Number(row.schema_version),
    nonce: row.nonce,
    ciphertext: row.ciphertext,
    expiresAt: Number(row.expires_at),
  });
}

async function revokeShare(request, id, env) {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return error("Revocation token required.", 401);
  const token = authorization.slice("Bearer ".length);
  if (token.length < 20 || token.length > 100) return error("Invalid revocation token.", 401);

  const candidate = await sha256Base64URL(token);
  const now = Math.floor(Date.now() / 1000);
  const existing = await env.DB.prepare(
    "SELECT revoke_hash FROM shared_notes WHERE id = ?1",
  ).bind(id).first();
  if (!existing) {
    // A missing-ID DELETE allocates storage just like POST. Share its quota,
    // but never let exhausted creation quota prevent an existing owner revoking.
    const clientKey = request.headers.get("cf-connecting-ip") ?? "local-development";
    const limit = await env.CREATE_RATE_LIMITER.limit({ key: clientKey });
    if (!limit.success) return error("Too many private links. Try again shortly.", 429);
  }
  // Reserve cancelled IDs even if a timed-out POST has not arrived yet. An empty
  // ciphertext is a tombstone; late creates collide instead of resurrecting it.
  await env.DB.prepare(
    `INSERT OR IGNORE INTO shared_notes
     (id, schema_version, nonce, ciphertext, revoke_hash, created_at, expires_at)
     VALUES (?1, 1, '', '', ?2, ?3, ?4)`,
  ).bind(id, candidate, now, now + THIRTY_DAYS_SECONDS).run();
  const row = await env.DB.prepare(
    "SELECT revoke_hash, expires_at FROM shared_notes WHERE id = ?1",
  ).bind(id).first();
  if (!row || !constantTimeEqual(candidate, row.revoke_hash)) {
    return error("Invalid revocation token.", 403);
  }
  await env.DB.prepare(
    "UPDATE shared_notes SET ciphertext = '', nonce = '' WHERE id = ?1 AND revoke_hash = ?2",
  ).bind(id, candidate).run();
  return response(null, 204, { "Cache-Control": "no-store" });
}

function serveViewerAsset(pathname) {
  if (pathname === "/p/assets/viewer-v4.css") {
    return response(viewerCSS, 200, {
      "Cache-Control": "public, max-age=3600",
      "Content-Type": "text/css; charset=utf-8",
    });
  }
  if (pathname === "/p/assets/viewer-v4.js") {
    return response(viewerJS, 200, {
      "Cache-Control": "public, max-age=3600",
      "Content-Type": "text/javascript; charset=utf-8",
    });
  }
  return null;
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      const asset = serveViewerAsset(url.pathname);
      if (asset && request.method === "GET") return asset;

      if (request.method === "GET" && /^\/p\/[A-Za-z0-9_-]{22}$/.test(url.pathname)) {
        return response(viewerHTML, 200, {
          "Cache-Control": "no-store",
          "Content-Security-Policy": contentSecurityPolicy,
          "Content-Type": "text/html; charset=utf-8",
        });
      }
      if (request.method === "POST" && url.pathname === "/api/shared-notes/create") {
        return await createShare(request, env);
      }
      const id = shareIDFromPath(url.pathname);
      if (id && request.method === "GET") return await readShare(id, env);
      if (id && request.method === "DELETE") return await revokeShare(request, id, env);
      return error("Not found.", 404);
    } catch {
      // Never reflect thrown database/request details: ciphertext is opaque,
      // and operational errors do not belong in a public response.
      return error("Sharing is temporarily unavailable.", 500);
    }
  },

  async scheduled(_controller, env, context) {
    const now = Math.floor(Date.now() / 1000);
    context.waitUntil(
      env.DB.prepare("DELETE FROM shared_notes WHERE expires_at <= ?1")
        .bind(now)
        .run(),
    );
  },
};
