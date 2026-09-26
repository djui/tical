/**
 * The small subset of ASN.1 DER that pass signing and App Attest need: building CMS
 * structures, and reading certificates. It mirrors Tical/Wallet/DER.swift in the app.
 */
import { compare, concat, type Bytes } from "./bytes.ts";

export const Tag = {
  boolean: 0x01,
  integer: 0x02,
  bitString: 0x03,
  octetString: 0x04,
  null: 0x05,
  objectIdentifier: 0x06,
  utf8String: 0x0c,
  printableString: 0x13,
  teletexString: 0x14,
  ia5String: 0x16,
  utcTime: 0x17,
  generalizedTime: 0x18,
  bmpString: 0x1e,
  sequence: 0x30,
  set: 0x31,
} as const;

export const OID = {
  signedData: "1.2.840.113549.1.7.2",
  data: "1.2.840.113549.1.7.1",
  sha256: "2.16.840.1.101.3.4.2.1",
  rsaEncryption: "1.2.840.113549.1.1.1",
  sha256WithRSAEncryption: "1.2.840.113549.1.1.11",
  ecPublicKey: "1.2.840.10045.2.1",
  ecdsaWithSHA256: "1.2.840.10045.4.3.2",
  ecdsaWithSHA384: "1.2.840.10045.4.3.3",
  prime256v1: "1.2.840.10045.3.1.7",
  secp384r1: "1.3.132.0.34",
  contentType: "1.2.840.113549.1.9.3",
  messageDigest: "1.2.840.113549.1.9.4",
  signingTime: "1.2.840.113549.1.9.5",
  commonName: "2.5.4.3",
  countryName: "2.5.4.6",
  organizationName: "2.5.4.10",
  organizationalUnitName: "2.5.4.11",
  userID: "0.9.2342.19200300.100.1.1",
  keyUsage: "2.5.29.15",
  basicConstraints: "2.5.29.19",
  appAttestNonce: "1.2.840.113635.100.8.2",
} as const;

export class DERError extends Error {}

// MARK: - Encoding

export function tlv(tag: number, content: Bytes): Bytes {
  return concat([Uint8Array.of(tag), length(content.length), content]);
}

export function sequence(elements: readonly Bytes[]): Bytes {
  return tlv(Tag.sequence, concat(elements));
}

/** A SET OF, with its elements in the ascending byte order DER requires. */
export function set(elements: readonly Bytes[]): Bytes {
  return tlv(Tag.set, setContents(elements));
}

/** The contents of a DER SET OF without its tag, for `[n] IMPLICIT` encodings of the same set. */
export function setContents(elements: readonly Bytes[]): Bytes {
  return concat([...elements].sort(compare));
}

/** A constructed context-specific tag, `[number]`, around already encoded contents. */
export function context(number: number, content: Bytes): Bytes {
  return tlv(0xa0 | number, content);
}

export function integer(value: number | Bytes): Bytes {
  let bytes: Bytes;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) throw new DERError("Only non-negative integers are needed here.");
    const digits: number[] = [];
    let remaining = value;
    do {
      digits.unshift(remaining % 256);
      remaining = Math.floor(remaining / 256);
    } while (remaining > 0);
    bytes = Uint8Array.from(digits);
  } else {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) start++;
    bytes = value.subarray(start);
  }
  if (bytes.length === 0 || bytes[0]! & 0x80) bytes = concat([Uint8Array.of(0), bytes]);
  return tlv(Tag.integer, bytes);
}

export function boolean(value: boolean): Bytes {
  return Uint8Array.of(Tag.boolean, 1, value ? 0xff : 0);
}

export function objectIdentifier(dotted: string): Bytes {
  const arcs = dotted.split(".").map(Number);
  if (arcs.length < 2 || arcs.some((arc) => !Number.isSafeInteger(arc) || arc < 0)) {
    throw new DERError(`Not an object identifier: ${dotted}`);
  }
  const content = [base128(arcs[0]! * 40 + arcs[1]!), ...arcs.slice(2).map(base128)];
  return tlv(Tag.objectIdentifier, concat(content));
}

export const nullValue = Uint8Array.of(Tag.null, 0);

export function octetString(data: Bytes): Bytes {
  return tlv(Tag.octetString, data);
}

export function bitString(data: Bytes): Bytes {
  return tlv(Tag.bitString, concat([Uint8Array.of(0), data]));
}

export function utf8String(text: string): Bytes {
  return tlv(Tag.utf8String, new TextEncoder().encode(text));
}

/** UTCTime, `YYMMDDHHMMSSZ`, which CMS uses for signing times between 1950 and 2049. */
export function utcTime(date: Date): Bytes {
  const text = date.toISOString().replace(/[-:T]/g, "").slice(2, 14) + "Z";
  return tlv(Tag.utcTime, new TextEncoder().encode(text));
}

export function algorithmIdentifier(oid: string, withNullParameters = true): Bytes {
  return sequence(withNullParameters ? [objectIdentifier(oid), nullValue] : [objectIdentifier(oid)]);
}

function length(count: number): Bytes {
  if (count < 0x80) return Uint8Array.of(count);
  const bytes: number[] = [];
  for (let remaining = count; remaining > 0; remaining = Math.floor(remaining / 256)) bytes.unshift(remaining % 256);
  return Uint8Array.from([0x80 | bytes.length, ...bytes]);
}

function base128(value: number): Bytes {
  const bytes = [value % 128];
  for (let remaining = Math.floor(value / 128); remaining > 0; remaining = Math.floor(remaining / 128)) {
    bytes.unshift((remaining % 128) | 0x80);
  }
  return Uint8Array.from(bytes);
}

// MARK: - Parsing

export interface Node {
  readonly tag: number;
  /** The element's contents, without tag and length. */
  readonly content: Bytes;
  /** The full encoding: tag, length, and contents. */
  readonly encoded: Bytes;
}

/** Parses the one element that makes up `data`. */
export function parse(data: Bytes): Node {
  const [node, end] = element(data, 0);
  if (end !== data.length) throw new DERError("Unexpected bytes after the element.");
  return node;
}

export function parseAll(data: Bytes): Node[] {
  const nodes: Node[] = [];
  let offset = 0;
  while (offset < data.length) {
    const [node, end] = element(data, offset);
    nodes.push(node);
    offset = end;
  }
  return nodes;
}

export function children(node: Node): Node[] {
  return parseAll(node.content);
}

export function expect(node: Node | undefined, tag: number): Node {
  if (!node) throw new DERError(`Missing element with tag 0x${tag.toString(16)}.`);
  if (node.tag !== tag) {
    throw new DERError(`Expected tag 0x${tag.toString(16)}, found 0x${node.tag.toString(16)}.`);
  }
  return node;
}

function element(data: Bytes, start: number): [Node, number] {
  let offset = start;
  if (offset + 2 > data.length) throw new DERError("Truncated element.");
  const tag = data[offset++]!;
  if ((tag & 0x1f) === 0x1f) throw new DERError("Multi-byte tags aren't supported.");
  let size = data[offset++]!;
  if (size & 0x80) {
    const count = size & 0x7f;
    if (count === 0 || count > 4 || offset + count > data.length) throw new DERError("Unsupported length.");
    size = 0;
    for (let index = 0; index < count; index++) size = size * 256 + data[offset++]!;
  }
  if (offset + size > data.length) throw new DERError("Truncated element.");
  const end = offset + size;
  return [{ tag, content: data.subarray(offset, end), encoded: data.subarray(start, end) }, end];
}

export function objectIdentifierString(content: Bytes): string {
  const arcs: number[] = [];
  let value = 0;
  for (const byte of content) {
    value = value * 128 + (byte & 0x7f);
    if (byte & 0x80) continue;
    if (arcs.length === 0) {
      const first = value < 80 ? Math.floor(value / 40) : 2;
      arcs.push(first, value - first * 40);
    } else {
      arcs.push(value);
    }
    value = 0;
  }
  return arcs.join(".");
}

export function stringValue(node: Node): string | undefined {
  switch (node.tag) {
    case Tag.utf8String:
    case Tag.printableString:
    case Tag.ia5String:
      return new TextDecoder().decode(node.content);
    case Tag.teletexString:
      return String.fromCharCode(...node.content);
    case Tag.bmpString: {
      let text = "";
      for (let index = 0; index + 1 < node.content.length; index += 2) {
        text += String.fromCharCode(node.content[index]! * 256 + node.content[index + 1]!);
      }
      return text;
    }
    default:
      return undefined;
  }
}

export function dateValue(node: Node): Date | undefined {
  const text = new TextDecoder().decode(node.content);
  let match: RegExpMatchArray | null;
  if (node.tag === Tag.utcTime && (match = text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    const year = Number(match[1]);
    // Two-digit years from 50 on are 19xx, per RFC 5280.
    return utc(year < 50 ? 2000 + year : 1900 + year, match.slice(2));
  }
  if (node.tag === Tag.generalizedTime && (match = text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\.\d+)?Z$/))) {
    return utc(Number(match[1]), match.slice(2));
  }
  return undefined;
}

function utc(year: number, [month, day, hour, minute, second]: string[]): Date {
  return new Date(Date.UTC(year, Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second)));
}
