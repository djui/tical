import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { fromBase64, pem, pemBlocks, toBase64 } from "../src/bytes.ts";
import * as CBOR from "../src/cbor.ts";
import * as DER from "../src/der.ts";

const hex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");

describe("DER", () => {
  test("encodes object identifiers", () => {
    assert.equal(hex(DER.objectIdentifier("1.2.840.113549.1.7.2")), "06092a864886f70d010702");
    assert.equal(hex(DER.objectIdentifier("0.9.2342.19200300.100.1.1")), "060a0992268993f22c640101");
  });

  test("round-trips object identifier strings", () => {
    for (const oid of ["1.2.840.113635.100.8.2", "2.16.840.1.101.3.4.2.1", "0.9.2342.19200300.100.1.1"]) {
      assert.equal(DER.objectIdentifierString(DER.parse(DER.objectIdentifier(oid)).content), oid);
    }
  });

  test("pads integers so they stay positive", () => {
    assert.equal(hex(DER.integer(0)), "020100");
    assert.equal(hex(DER.integer(127)), "02017f");
    assert.equal(hex(DER.integer(128)), "02020080");
    assert.equal(hex(DER.integer(Uint8Array.of(0, 0, 1))), "020101");
    assert.equal(hex(DER.integer(Uint8Array.of(0xff))), "020200ff");
  });

  test("encodes long lengths", () => {
    assert.equal(hex(DER.octetString(new Uint8Array(200)).subarray(0, 3)), "0481c8");
    assert.equal(hex(DER.octetString(new Uint8Array(300)).subarray(0, 4)), "0482012c");
  });

  test("sorts the elements of a SET", () => {
    assert.equal(hex(DER.set([Uint8Array.of(0x02, 0x01, 0x05), Uint8Array.of(0x02, 0x01, 0x01)])), "3106020101020105");
  });

  test("writes signing times as UTCTime", () => {
    const encoded = DER.utcTime(new Date("2026-09-26T12:34:56.789Z"));
    assert.equal(new TextDecoder().decode(DER.parse(encoded).content), "260926123456Z");
    assert.deepEqual(DER.dateValue(DER.parse(encoded)), new Date("2026-09-26T12:34:56Z"));
  });

  test("rejects truncated and trailing bytes", () => {
    assert.throws(() => DER.parse(Uint8Array.of(0x04, 0x05, 0x01)), DER.DERError);
    assert.throws(() => DER.parse(Uint8Array.of(0x05, 0x00, 0x00)), DER.DERError);
  });
});

describe("base64 and PEM", () => {
  test("round-trips", () => {
    const bytes = Uint8Array.from({ length: 70_000 }, (_, index) => index % 256);
    assert.deepEqual(fromBase64(toBase64(bytes)), bytes);
    assert.deepEqual(pemBlocks(pem(bytes, "CERTIFICATE") + pem(Uint8Array.of(1), "CERTIFICATE"), "CERTIFICATE"), [bytes, Uint8Array.of(1)]);
  });

  test("rejects malformed base64", () => {
    assert.equal(fromBase64("abc"), undefined);
    assert.equal(fromBase64("ab!="), undefined);
    assert.equal(fromBase64("YWJj ZA=="), undefined);
  });
});

describe("CBOR", () => {
  test("decodes a known map", () => {
    // {"fmt": "none", "n": [1, -2], "b": h'0102'}
    const decoded = CBOR.fields(CBOR.decode(Buffer.from("a363666d74646e6f6e65616e8201216162420102", "hex")));
    assert.equal(decoded.fmt, "none");
    assert.deepEqual(decoded.n, [1, -2]);
    assert.deepEqual(decoded.b, Uint8Array.of(1, 2));
  });

  test("round-trips what it encodes", () => {
    const value = { text: "Tical", bytes: new Uint8Array(300), list: [0, 23, 24, 255, 256, 65_536, -1, -500], nested: { yes: true, no: false, none: null } };
    const decoded = CBOR.fields(CBOR.decode(CBOR.encode(value)));
    assert.equal(decoded.text, "Tical");
    assert.deepEqual(decoded.bytes, new Uint8Array(300));
    assert.deepEqual(decoded.list, [0, 23, 24, 255, 256, 65_536, -1, -500]);
    assert.deepEqual(CBOR.fields(decoded.nested), { yes: true, no: false, none: null });
  });

  test("rejects indefinite lengths and truncated input", () => {
    assert.throws(() => CBOR.decode(Uint8Array.of(0x5f)), CBOR.CBORError);
    assert.throws(() => CBOR.decode(Uint8Array.of(0x43, 0x01)), CBOR.CBORError);
    assert.throws(() => CBOR.decode(Uint8Array.of(0x01, 0x02)), CBOR.CBORError);
  });
});
