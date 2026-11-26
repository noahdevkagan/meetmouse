// Reference client for the team space, mirroring the Mac app's
// TeamCrypto (Models/TeamSpace.swift). Tests use it to play a member.
import { createHmac, createHash, createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export const b64u = bytes => Buffer.from(bytes).toString("base64url");
export const fromB64u = text => Buffer.from(text, "base64url");

const derive = (secret, label) => createHmac("sha256", secret).update(label).digest();
export const accessToken = secret => b64u(derive(secret, "meetmouse-team-access-v1"));
export const accessHash = secret => b64u(createHash("sha256").update(accessToken(secret)).digest());
export const notesKey = secret => derive(secret, "meetmouse-team-notes-v1");
export const noteID = (secret, memberID, sessionFile) =>
  b64u(derive(secret, `note:${memberID}:${sessionFile}`).subarray(0, 16));

const aad = (teamID, context) => Buffer.from(`meetmouse-team-v1:${teamID}:${context}`);

export function seal(secret, teamID, context, value, nonce = randomBytes(12)) {
  const cipher = createCipheriv("aes-256-gcm", notesKey(secret), nonce);
  cipher.setAAD(aad(teamID, context));
  const body = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final(), cipher.getAuthTag()]);
  return { nonce: b64u(nonce), ciphertext: b64u(body) };
}

export function unseal(secret, teamID, context, nonce, ciphertext) {
  const body = fromB64u(ciphertext);
  const decipher = createDecipheriv("aes-256-gcm", notesKey(secret), fromB64u(nonce));
  decipher.setAAD(aad(teamID, context));
  decipher.setAuthTag(body.subarray(body.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(body.subarray(0, body.length - 16)), decipher.final()]));
}

export function createBody(secret, teamID, name) {
  const sealed = seal(secret, teamID, "name", { name });
  return { id: teamID, accessHash: accessHash(secret), nameNonce: sealed.nonce, nameCiphertext: sealed.ciphertext };
}

export function notePayload(author, title, meetingDate, extra = {}) {
  return {
    schemaVersion: 1,
    author,
    note: {
      schemaVersion: 1, title, meetingDate, durationMinutes: 30,
      summary: `Summary of ${title}.`,
      sections: [{ heading: "Decisions", bullets: [`${title}: ship on Friday`] }],
      nextSteps: [{ text: "Send the deck", isDone: false }],
      ...extra,
    },
  };
}
