/**
 * Deno SHA-256 hashing utility for IP addresses and other rate-limiting keys.
 * Reusable across Edge Functions to avoid code duplication.
 */

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
