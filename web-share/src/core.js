const ID_PATTERN = /^[A-Za-z0-9_-]{22}$/;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;

export function shareIDFromPath(pathname) {
  const match = pathname.match(/^\/api\/shared-notes\/([A-Za-z0-9_-]{22})$/);
  return match?.[1] ?? null;
}

function decodedByteLength(base64URL) {
  if (!BASE64URL_PATTERN.test(base64URL)) return -1;
  const remainder = base64URL.length % 4;
  if (remainder === 1) return -1;
  return Math.floor((base64URL.length * 3) / 4);
}

export function validateCreateBody(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "Invalid request body.";
  }
  if (value.schemaVersion !== 1) return "Unsupported share format.";
  if (typeof value.id !== "string" || !ID_PATTERN.test(value.id)) {
    return "Invalid share id.";
  }
  if (typeof value.nonce !== "string" || decodedByteLength(value.nonce) !== 12) {
    return "Invalid encryption nonce.";
  }
  const ciphertextBytes = typeof value.ciphertext === "string"
    ? decodedByteLength(value.ciphertext) : -1;
  if (ciphertextBytes <= 16 || ciphertextBytes > 64 * 1024) {
    return "Encrypted note must be between 17 bytes and 64 KB.";
  }
  if (typeof value.revokeHash !== "string"
      || decodedByteLength(value.revokeHash) !== 32) {
    return "Invalid revocation capability.";
  }
  return null;
}

function bytesToBase64URL(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export async function sha256Base64URL(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToBase64URL(new Uint8Array(digest));
}
