// AES-GCM encryption for the stored app-specific password. The key lives in the Edge
// Function's secrets (ARIA_ENCRYPTION_KEY), never in the database.

async function keyFrom(secret: string): Promise<CryptoKey> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`aria-icloud:${secret}`));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

const toBase64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const fromBase64 = (text: string) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

export async function encrypt(plain: string, secret: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await keyFrom(secret), new TextEncoder().encode(plain));
  return `v1:${toBase64(iv)}:${toBase64(new Uint8Array(data))}`;
}

export async function decrypt(sealed: string, secret: string): Promise<string> {
  const [version, iv, data] = sealed.split(":");
  if (version !== "v1" || !iv || !data) throw new Error("Unrecognised secret format.");
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64(iv) }, await keyFrom(secret), fromBase64(data));
  return new TextDecoder().decode(plain);
}
