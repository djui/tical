/** Just enough CBOR (RFC 8949) to read App Attest objects, and to write them in tests. */
import type { Bytes } from "./bytes.ts";

export type Value = number | bigint | string | boolean | null | undefined | Bytes | Value[] | Map<Value, Value>;

export class CBORError extends Error {}

export function decode(data: Bytes): Value {
  const reader = { data, offset: 0 };
  const value = read(reader, 0);
  if (reader.offset !== data.length) throw new CBORError("Unexpected bytes after the value.");
  return value;
}

interface Reader {
  data: Bytes;
  offset: number;
}

function read(reader: Reader, depth: number): Value {
  if (depth > 16) throw new CBORError("Nested too deeply.");
  const initial = take(reader, 1)[0]!;
  const major = initial >> 5;
  const info = initial & 0x1f;
  if (major === 7) return simple(reader, info);
  const argument = readArgument(reader, info);
  switch (major) {
    case 0:
      return argument;
    case 1:
      return typeof argument === "bigint" ? -1n - argument : -1 - argument;
    case 2:
      return new Uint8Array(take(reader, count(argument)));
    case 3:
      return new TextDecoder("utf-8", { fatal: true }).decode(take(reader, count(argument)));
    case 4:
      return Array.from({ length: count(argument) }, () => read(reader, depth + 1));
    case 5: {
      const map = new Map<Value, Value>();
      for (let index = 0; index < count(argument); index++) {
        const key = read(reader, depth + 1);
        map.set(key, read(reader, depth + 1));
      }
      return map;
    }
    default: // 6: a tag, which only annotates the value that follows
      return read(reader, depth + 1);
  }
}

function readArgument(reader: Reader, info: number): number | bigint {
  if (info < 24) return info;
  const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
  if (size === 0) throw new CBORError("Indefinite lengths aren't supported.");
  let value = 0n;
  for (const byte of take(reader, size)) value = (value << 8n) | BigInt(byte);
  return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : value;
}

function simple(reader: Reader, info: number): Value {
  switch (info) {
    case 20:
      return false;
    case 21:
      return true;
    case 22:
      return null;
    case 23:
      return undefined;
    default:
      // App Attest never uses floating-point numbers.
      throw new CBORError(`Unsupported simple value ${info}.`);
  }
}

function count(argument: number | bigint): number {
  if (typeof argument !== "number") throw new CBORError("Length too large.");
  return argument;
}

function take(reader: Reader, size: number): Bytes {
  if (reader.offset + size > reader.data.length) throw new CBORError("Truncated value.");
  const bytes = reader.data.subarray(reader.offset, reader.offset + size);
  reader.offset += size;
  return bytes;
}

/** Reads a text-keyed map, as App Attest uses, into a plain object. */
export function fields(value: Value): Record<string, Value> {
  if (!(value instanceof Map)) throw new CBORError("Expected a map.");
  const result: Record<string, Value> = {};
  for (const [key, entry] of value) {
    if (typeof key === "string") result[key] = entry;
  }
  return result;
}

// MARK: - Encoding

/** What `encode` accepts: CBOR values, and plain objects for text-keyed maps. */
export type Encodable = Value | readonly Encodable[] | { readonly [key: string]: Encodable };

export function encode(value: Encodable): Bytes {
  const parts: number[] = [];
  write(parts, value);
  return Uint8Array.from(parts);
}

function write(parts: number[], value: Encodable): void {
  if (typeof value === "number" && Number.isInteger(value)) {
    head(parts, value >= 0 ? 0 : 1, value >= 0 ? value : -1 - value);
  } else if (typeof value === "string") {
    const bytes = new TextEncoder().encode(value);
    head(parts, 3, bytes.length);
    parts.push(...bytes);
  } else if (value instanceof Uint8Array) {
    head(parts, 2, value.length);
    parts.push(...value);
  } else if (Array.isArray(value)) {
    head(parts, 4, value.length);
    for (const item of value) write(parts, item);
  } else if (value instanceof Map) {
    head(parts, 5, value.size);
    for (const [key, entry] of value) {
      write(parts, key);
      write(parts, entry);
    }
  } else if (typeof value === "boolean") {
    parts.push(value ? 0xf5 : 0xf4);
  } else if (value === null) {
    parts.push(0xf6);
  } else if (typeof value === "object" && value !== undefined) {
    head(parts, 5, Object.keys(value).length);
    for (const [key, entry] of Object.entries(value)) {
      write(parts, key);
      write(parts, entry);
    }
  } else {
    throw new CBORError("Can't encode that value.");
  }
}

function head(parts: number[], major: number, argument: number): void {
  if (argument < 24) {
    parts.push((major << 5) | argument);
  } else {
    const size = argument < 0x100 ? 1 : argument < 0x10000 ? 2 : argument < 0x100000000 ? 4 : 8;
    parts.push((major << 5) | (size === 1 ? 24 : size === 2 ? 25 : size === 4 ? 26 : 27));
    for (let index = size - 1; index >= 0; index--) parts.push(Number((BigInt(argument) >> BigInt(index * 8)) & 0xffn));
  }
}
