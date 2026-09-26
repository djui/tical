import assert from "node:assert/strict";
import { createHash, verify, X509Certificate } from "node:crypto";
import { describe, test } from "node:test";
import { fromBase64, randomBytes, toBase64, utf8 } from "../src/bytes.ts";
import { Certificate } from "../src/certificate.ts";
import * as DER from "../src/der.ts";
import { OID, Tag } from "../src/der.ts";
import { createService, type ServiceConfig } from "../src/service.ts";
import { rsaSigner } from "../src/signing.ts";
import { MemoryStore } from "../src/store.ts";
import { bytes, passSigningChain } from "../scripts/pki.ts";
import { AppAttestFixture, appId } from "./support.ts";

const chain = passSigningChain("pass.example.tickets", "ABCDE12345");
const pass = new Certificate(chain.pass);
const signer = await rsaSigner(chain.passKey.export({ type: "pkcs8", format: "pem" }) as string);
const fixture = new AppAttestFixture();

function setUp(overrides: Partial<ServiceConfig> = {}) {
  const store = new MemoryStore();
  const service = createService({
    store,
    signing: { signer, certificate: pass, intermediates: [new Certificate(chain.authority)] },
    appIds: [appId],
    appAttestRoot: fixture.root,
    allowDevelopmentAttestation: false,
    allowUnattested: false,
    limits: { signaturesPerKeyPerDay: 3, signaturesPerDay: 100, keysPerDay: 100 },
    ...overrides,
  });
  const call = async (method: string, path: string, body?: object | string, assertion?: string) => {
    const raw = typeof body === "string" ? utf8(body) : utf8(body ? JSON.stringify(body) : "");
    const response = await service({ method, path, body: raw, assertion });
    return { status: response.status, json: JSON.parse(response.body) as Record<string, string> };
  };

  let counter = 0;
  return {
    store,
    call,
    async register() {
      const { json } = await call("POST", "/v1/challenges");
      const challenge = fromBase64(json.challenge!)!;
      return call("POST", "/v1/keys", {
        keyId: toBase64(fixture.keyId),
        challenge: json.challenge,
        attestation: toBase64(fixture.attestation(challenge)),
      });
    },
    /** Signs with the fixture's key, as the app does: the assertion covers the exact body. */
    async sign(manifestDigest = digest(), options: { assertionCounter?: number; keyId?: string } = {}) {
      const body = JSON.stringify({ keyId: options.keyId ?? toBase64(fixture.keyId), manifestDigest: toBase64(manifestDigest) });
      counter = options.assertionCounter ?? counter + 1;
      return call("POST", "/v1/signatures", body, toBase64(fixture.assertion(utf8(body), counter)));
    },
  };
}

function digest(): Uint8Array<ArrayBuffer> {
  return randomBytes(32);
}

describe("the signing service", () => {
  test("tells the app which pass type to use", async () => {
    const { call } = setUp();
    assert.deepEqual(await call("GET", "/v1/pass-type"), {
      status: 200,
      json: { passTypeIdentifier: "pass.example.tickets", teamIdentifier: "ABCDE12345" },
    });
  });

  test("registers a key and signs a manifest digest", async () => {
    const service = setUp();
    assert.equal((await service.register()).status, 201);

    const manifest = utf8('{"pass.json":"abc"}');
    const manifestDigest = bytes(createHash("sha256").update(manifest).digest());
    const { status, json } = await service.sign(manifestDigest);
    assert.equal(status, 200);

    // The signature file signs attributes that carry the digest, with the pass certificate.
    const signedData = DER.children(DER.children(DER.parse(fromBase64(json.signature!)!))[1]!)[0]!;
    const info = DER.children(DER.children(DER.children(signedData)[4]!)[0]!);
    const messageDigest = DER.children(info[3]!).find(
      (attribute) => DER.objectIdentifierString(DER.children(attribute)[0]!.content) === OID.messageDigest,
    );
    assert.deepEqual(DER.children(DER.children(messageDigest!)[1]!)[0]!.content, manifestDigest);
    assert.ok(verify("sha256", DER.tlv(Tag.set, info[3]!.content), new X509Certificate(pass.der).publicKey, info[5]!.content));
  });

  test("uses each challenge once", async () => {
    const { call } = setUp();
    const { json } = await call("POST", "/v1/challenges");
    const attestation = toBase64(fixture.attestation(fromBase64(json.challenge!)!));
    const body = { keyId: toBase64(fixture.keyId), challenge: json.challenge, attestation };
    assert.equal((await call("POST", "/v1/keys", body)).status, 201);
    assert.equal((await call("POST", "/v1/keys", body)).json.error, "invalid-challenge");
  });

  test("rejects attestations that don't check out", async () => {
    const { call } = setUp();
    const { json } = await call("POST", "/v1/challenges");
    const attestation = toBase64(fixture.attestation(randomBytes(32)));
    const response = await call("POST", "/v1/keys", { keyId: toBase64(fixture.keyId), challenge: json.challenge, attestation });
    assert.deepEqual([response.status, response.json.error], [403, "invalid-attestation"]);
  });

  test("asks unknown keys to register", async () => {
    const response = await setUp().sign();
    assert.deepEqual([response.status, response.json.error], [401, "unknown-key"]);
  });

  test("rejects missing, replayed, and mismatched assertions", async () => {
    const service = setUp();
    await service.register();
    const body = JSON.stringify({ keyId: toBase64(fixture.keyId), manifestDigest: toBase64(digest()) });
    assert.equal((await service.call("POST", "/v1/signatures", body)).json.error, "assertion-required");
    assert.equal((await service.sign(digest(), { assertionCounter: 5 })).status, 200);
    assert.equal((await service.sign(digest(), { assertionCounter: 5 })).json.error, "invalid-assertion");
    const other = JSON.stringify({ keyId: toBase64(fixture.keyId), manifestDigest: toBase64(digest()) });
    const assertion = toBase64(fixture.assertion(utf8(body), 9));
    assert.equal((await service.call("POST", "/v1/signatures", other, assertion)).json.error, "invalid-assertion");
  });

  test("limits signatures per key per day", async () => {
    const service = setUp();
    await service.register();
    for (let index = 0; index < 3; index++) assert.equal((await service.sign()).status, 200);
    const response = await service.sign();
    assert.deepEqual([response.status, response.json.error], [429, "rate-limited"]);
  });

  test("signs without App Attest only when allowed", async () => {
    const body = { manifestDigest: toBase64(digest()) };
    assert.equal((await setUp().call("POST", "/v1/signatures", body)).json.error, "attestation-required");
    assert.equal((await setUp({ allowUnattested: true }).call("POST", "/v1/signatures", body)).status, 200);
  });

  test("rejects malformed requests", async () => {
    const { call } = setUp({ allowUnattested: true });
    assert.equal((await call("POST", "/v1/signatures", "not json")).status, 400);
    assert.equal((await call("POST", "/v1/signatures", { manifestDigest: toBase64(randomBytes(20)) })).status, 400);
    assert.equal((await call("POST", "/v1/signatures", { manifestDigest: "%%%%" })).status, 400);
    assert.equal((await call("GET", "/v1/signatures")).status, 405);
    assert.equal((await call("GET", "/")).status, 404);
  });

  test("reports when no certificate is set up", async () => {
    const { call } = setUp({ signing: undefined, allowUnattested: true });
    assert.equal((await call("GET", "/v1/pass-type")).status, 503);
    assert.equal((await call("POST", "/v1/signatures", { manifestDigest: toBase64(digest()) })).status, 503);
  });
});
