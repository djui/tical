/** Byte helpers that work the same in Workers and in Node, which runs the tests. */

/** Bytes backed by a plain ArrayBuffer, which is what Web Crypto accepts. */
export type Bytes = Uint8Array<ArrayBuffer>;

export function concat(parts: readonly Bytes[]): Bytes {
  const result = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

export function equal(a: Bytes, b: Bytes): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a[index]! ^ b[index]!;
  return difference === 0;
}

/** Orders byte strings the way DER sorts a SET OF: bytewise, with a prefix before longer strings. */
export function compare(a: Bytes, b: Bytes): number {
  const length = Math.min(a.length, b.length);
  for (let index = 0; index < length; index++) {
    if (a[index] !== b[index]) return a[index]! - b[index]!;
  }
  return a.length - b.length;
}

export function utf8(text: string): Bytes {
  return new TextEncoder().encode(text);
}

export function toBase64(bytes: Bytes): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
}

/** Decodes standard, padded base64, and returns undefined for anything else. */
export function fromBase64(text: string): Bytes | undefined {
  if (text.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return undefined;
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export async function sha256(data: Bytes): Promise<Bytes> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

export function randomBytes(count: number): Bytes {
  return crypto.getRandomValues(new Uint8Array(count));
}

/** Decodes every PEM block with the given label, such as CERTIFICATE or PRIVATE KEY. */
export function pemBlocks(text: string, label: string): Bytes[] {
  const pattern = new RegExp(`-----BEGIN ${label}-----([\\s\\S]*?)-----END ${label}-----`, "g");
  const blocks: Bytes[] = [];
  for (const match of text.matchAll(pattern)) {
    const bytes = fromBase64(match[1]!.replace(/\s+/g, ""));
    if (bytes) blocks.push(bytes);
  }
  return blocks;
}

export function pem(der: Bytes, label: string): string {
  const lines = toBase64(der).match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}
