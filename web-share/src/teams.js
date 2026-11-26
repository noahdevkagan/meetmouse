// Team space API. A team is an id plus a secret that never reaches this
// Worker: members derive an access token (sent as a Bearer token, stored
// here only as a SHA-256 hash) and an encryption key from it. Notes and the
// team name are opaque ciphertext to the server.
import { sha256Base64URL } from "./core.js";

const ID = "[A-Za-z0-9_-]{22}";
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
export const TEAM_NOTE_LIFETIME_SECONDS = 365 * 24 * 60 * 60;
export const MAX_TEAM_NOTES = 1000;
export const TEAM_PAGE_SIZE = 20;
const MAX_REQUEST_BYTES = 96 * 1024;
const MAX_NOTE_BYTES = 64 * 1024;
const MAX_NAME_BYTES = 512;

/// { action, teamID, noteID } for the team API paths, or null.
export function teamRoute(pathname) {
  if (pathname === "/api/teams/create") return { action: "create" };
  let match = pathname.match(new RegExp(`^/api/teams/(${ID})$`));
  if (match) return { action: "team", teamID: match[1] };
  match = pathname.match(new RegExp(`^/api/teams/(${ID})/notes$`));
  if (match) return { action: "notes", teamID: match[1] };
  match = pathname.match(new RegExp(`^/api/teams/(${ID})/notes/(${ID})$`));
  if (match) return { action: "note", teamID: match[1], noteID: match[2] };
  return null;
}

export function isTeamPagePath(pathname) {
  return new RegExp(`^/t/${ID}$`).test(pathname);
}

function decodedByteLength(base64URL) {
  if (typeof base64URL !== "string" || !BASE64URL_PATTERN.test(base64URL)) return -1;
  if (base64URL.length % 4 === 1) return -1;
  return Math.floor((base64URL.length * 3) / 4);
}

function validSealed(nonce, ciphertext, maxBytes) {
  const bytes = decodedByteLength(ciphertext);
  return decodedByteLength(nonce) === 12 && bytes > 16 && bytes <= maxBytes + 16;
}

export function validateCreateTeam(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "Invalid request body.";
  if (typeof value.id !== "string" || !new RegExp(`^${ID}$`).test(value.id)) return "Invalid team id.";
  if (decodedByteLength(value.accessHash) !== 32) return "Invalid access capability.";
  if (!validSealed(value.nameNonce, value.nameCiphertext, MAX_NAME_BYTES)) return "Invalid team name.";
  return null;
}

export function validateNote(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "Invalid request body.";
  if (!validSealed(value.nonce, value.ciphertext, MAX_NOTE_BYTES)) {
    return "Encrypted note must be between 17 bytes and 64 KB.";
  }
  return null;
}

function constantTimeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function readJSON(request, reply) {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_REQUEST_BYTES) return { failure: reply.error("Request is too large.", 413) };
  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_REQUEST_BYTES) {
    return { failure: reply.error("Request is too large.", 413) };
  }
  try {
    return { body: JSON.parse(raw) };
  } catch {
    return { failure: reply.error("Invalid JSON.", 400) };
  }
}

// Members prove they hold the team secret with the derived access token.
// Returns the team row, or a ready error response.
async function member(request, teamID, env, reply) {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return { failure: reply.error("Team access token required.", 401) };
  const token = authorization.slice("Bearer ".length);
  if (token.length < 20 || token.length > 100) return { failure: reply.error("Invalid team access token.", 401) };
  const team = await env.DB.prepare(
    "SELECT id, access_hash, name_nonce, name_ciphertext, created_at FROM teams WHERE id = ?1",
  ).bind(teamID).first();
  if (!team) return { failure: reply.error("This team was not found.", 404) };
  if (!constantTimeEqual(await sha256Base64URL(token), team.access_hash)) {
    return { failure: reply.error("Invalid team access token.", 403) };
  }
  return { team };
}

async function createTeam(request, env, reply) {
  // Account-free like share links: the client IP is the abuse-control key,
  // used by the rate limiter only and never stored.
  const clientKey = request.headers.get("cf-connecting-ip") ?? "local-development";
  const limit = await env.CREATE_RATE_LIMITER.limit({ key: clientKey });
  if (!limit.success) return reply.error("Too many requests. Try again shortly.", 429);
  const { body, failure } = await readJSON(request, reply);
  if (failure) return failure;
  const invalid = validateCreateTeam(body);
  if (invalid) return reply.error(invalid, 400);
  const now = Math.floor(Date.now() / 1000);
  try {
    await env.DB.prepare(
      `INSERT INTO teams (id, access_hash, name_nonce, name_ciphertext, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(body.id, body.accessHash, body.nameNonce, body.nameCiphertext, now).run();
  } catch (cause) {
    if (String(cause).toLowerCase().includes("unique")) {
      return reply.error("That team already exists. Try again.", 409);
    }
    throw cause;
  }
  return reply.json({ id: body.id }, 201);
}

async function readTeam(request, teamID, env, reply) {
  const { team, failure } = await member(request, teamID, env, reply);
  if (failure) return failure;
  const now = Math.floor(Date.now() / 1000);
  const count = await env.DB.prepare(
    "SELECT count(*) AS n FROM team_notes WHERE team_id = ?1 AND expires_at > ?2",
  ).bind(teamID, now).first();
  return reply.json({
    nameNonce: team.name_nonce,
    nameCiphertext: team.name_ciphertext,
    createdAt: Number(team.created_at),
    noteCount: Number(count?.n ?? 0),
  });
}

// Newest shared first. `before` is "<created_at>.<id>" from the last row
// of the previous page.
async function listNotes(request, teamID, env, reply, url) {
  const { failure } = await member(request, teamID, env, reply);
  if (failure) return failure;
  const now = Math.floor(Date.now() / 1000);
  let beforeTime = Number.MAX_SAFE_INTEGER;
  let beforeID = "";
  const before = url.searchParams.get("before");
  if (before) {
    const match = before.match(new RegExp(`^(\\d{1,12})\\.(${ID})$`));
    if (!match) return reply.error("Invalid page cursor.", 400);
    beforeTime = Number(match[1]);
    beforeID = match[2];
  }
  const result = await env.DB.prepare(
    `SELECT id, nonce, ciphertext, created_at, updated_at FROM team_notes
     WHERE team_id = ?1 AND expires_at > ?2
       AND (created_at < ?3 OR (created_at = ?3 AND id < ?4))
     ORDER BY created_at DESC, id DESC LIMIT ?5`,
  ).bind(teamID, now, beforeTime, beforeID, TEAM_PAGE_SIZE + 1).all();
  const rows = result.results ?? [];
  const page = rows.slice(0, TEAM_PAGE_SIZE);
  const last = page.at(-1);
  return reply.json({
    notes: page.map(row => ({
      id: row.id,
      nonce: row.nonce,
      ciphertext: row.ciphertext,
      createdAt: Number(row.created_at),
      updatedAt: Number(row.updated_at),
    })),
    next: rows.length > TEAM_PAGE_SIZE && last ? `${Number(last.created_at)}.${last.id}` : null,
  });
}

// PUT is an upsert: sharing the same meeting again replaces its note and
// keeps its place in the list.
async function putNote(request, teamID, noteID, env, reply) {
  const { failure } = await member(request, teamID, env, reply);
  if (failure) return failure;
  const limit = await env.CREATE_RATE_LIMITER.limit({ key: `team:${teamID}` });
  if (!limit.success) return reply.error("Too many notes at once. Try again shortly.", 429);
  const { body, failure: badBody } = await readJSON(request, reply);
  if (badBody) return badBody;
  const invalid = validateNote(body);
  if (invalid) return reply.error(invalid, 400);

  const now = Math.floor(Date.now() / 1000);
  const existing = await env.DB.prepare(
    "SELECT id FROM team_notes WHERE team_id = ?1 AND id = ?2",
  ).bind(teamID, noteID).first();
  if (existing) {
    await env.DB.prepare(
      `UPDATE team_notes SET nonce = ?3, ciphertext = ?4, updated_at = ?5, expires_at = ?6
       WHERE team_id = ?1 AND id = ?2`,
    ).bind(teamID, noteID, body.nonce, body.ciphertext, now, now + TEAM_NOTE_LIFETIME_SECONDS).run();
    return reply.json({ id: noteID, updated: true }, 200);
  }
  const count = await env.DB.prepare(
    "SELECT count(*) AS n FROM team_notes WHERE team_id = ?1 AND expires_at > ?2",
  ).bind(teamID, now).first();
  if (Number(count?.n ?? 0) >= MAX_TEAM_NOTES) {
    return reply.error(`This team page is full (${MAX_TEAM_NOTES} notes). Remove old notes to add more.`, 409);
  }
  await env.DB.prepare(
    `INSERT INTO team_notes (team_id, id, nonce, ciphertext, created_at, updated_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6)`,
  ).bind(teamID, noteID, body.nonce, body.ciphertext, now, now + TEAM_NOTE_LIFETIME_SECONDS).run();
  return reply.json({ id: noteID, updated: false }, 201);
}

async function deleteNote(request, teamID, noteID, env, reply) {
  const { failure } = await member(request, teamID, env, reply);
  if (failure) return failure;
  await env.DB.prepare("DELETE FROM team_notes WHERE team_id = ?1 AND id = ?2")
    .bind(teamID, noteID).run();
  return reply.empty();
}

/// Returns a Response for a team API route, or null when the method doesn't fit.
export async function handleTeam(route, request, env, url, reply) {
  const method = request.method;
  if (route.action === "create" && method === "POST") return createTeam(request, env, reply);
  if (route.action === "team" && method === "GET") return readTeam(request, route.teamID, env, reply);
  if (route.action === "notes" && method === "GET") return listNotes(request, route.teamID, env, reply, url);
  if (route.action === "note" && method === "PUT") return putNote(request, route.teamID, route.noteID, env, reply);
  if (route.action === "note" && method === "DELETE") return deleteNote(request, route.teamID, route.noteID, env, reply);
  return null;
}

export function sweepExpiredTeamNotes(env, now) {
  return env.DB.prepare("DELETE FROM team_notes WHERE expires_at <= ?1").bind(now).run();
}
