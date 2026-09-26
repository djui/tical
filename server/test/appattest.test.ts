import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { AppAttestError, verifyAssertion, verifyAttestation } from "../src/appattest.ts";
import { randomBytes, utf8 } from "../src/bytes.ts";
import { ecKeys } from "../scripts/pki.ts";
import { AppAttestFixture, appId } from "./support.ts";

const fixture = new AppAttestFixture();
const challenge = randomBytes(32);
const now = new Date();

function attest(attestation: Uint8Array<ArrayBuffer>, options: { allowDevelopment?: boolean; at?: Date; root?: AppAttestFixture["root"] } = {}) {
  return verifyAttestation({
    attestation,
    challenge,
    keyId: fixture.keyId,
    appIds: ["OTHERTEAM1.com.example.other", appId],
    root: options.root ?? fixture.root,
    now: options.at ?? now,
    allowDevelopment: options.allowDevelopment ?? false,
  });
}

describe("verifyAttestation", () => {
  test("accepts a key attested for one of our apps", async () => {
    const key = await attest(fixture.attestation(challenge));
    assert.equal(key.appId, appId);
    assert.equal(key.environment, "production");
    assert.deepEqual(key.publicKey, fixture.publicKey);
    assert.deepEqual(key.receipt, utf8("receipt"));
  });

  test("accepts development keys only when allowed", async () => {
    const attestation = fixture.attestation(challenge, { aaguid: utf8("appattestdevelop") });
    await assert.rejects(attest(attestation), AppAttestError);
    assert.equal((await attest(attestation, { allowDevelopment: true })).environment, "development");
  });

  const failures: [string, RegExp, () => Uint8Array<ArrayBuffer>, Parameters<typeof attest>[1]?][] = [
    ["another challenge", /nonce/, () => fixture.attestation(randomBytes(32))],
    ["another app", /another app/, () => fixture.attestation(challenge, { appId: "ABCDE12345.com.example.evil" })],
    ["a used key", /counter/, () => fixture.attestation(challenge, { counter: 1 })],
    ["another credential", /credential ID/, () => fixture.attestation(challenge, { credentialId: randomBytes(32) })],
    ["an unknown environment", /environment/, () => fixture.attestation(challenge, { aaguid: new Uint8Array(16) })],
    ["another format", /Not an App Attest/, () => fixture.attestation(challenge, { fmt: "packed" })],
    ["an expired certificate", /expired/, () => fixture.attestation(challenge, { notAfter: new Date(now.getTime() - 60_000) })],
    ["another root", /root/, () => fixture.attestation(challenge), { root: new AppAttestFixture().root }],
    ["garbage", /malformed/, () => randomBytes(64)],
  ];
  for (const [label, reason, attestation, options] of failures) {
    test(`rejects ${label}`, async () => {
      await assert.rejects(attest(attestation(), options), (error) => error instanceof AppAttestError && reason.test(error.message));
    });
  }

  test("rejects a key that isn't the attested one", async () => {
    await assert.rejects(
      verifyAttestation({
        attestation: fixture.attestation(challenge),
        challenge,
        keyId: randomBytes(32),
        appIds: [appId],
        root: fixture.root,
        now,
        allowDevelopment: false,
      }),
      /key identifier/,
    );
  });
});

describe("verifyAssertion", () => {
  const body = utf8('{"manifestDigest":"..."}');
  const check = (assertion: Uint8Array<ArrayBuffer>, clientData = body, previousCounter = 0) =>
    verifyAssertion({ assertion, clientData, publicKey: fixture.publicKey, appId, previousCounter });

  test("returns the new counter", async () => {
    assert.equal(await check(fixture.assertion(body, 1)), 1);
    assert.equal(await check(fixture.assertion(body, 7), body, 6), 7);
  });

  test("reads only the counter when more data follows", async () => {
    assert.equal(await check(fixture.assertion(body, 2, { extra: new Uint8Array(40).fill(0xa5) })), 2);
    // Real devices set the attested-data flag in assertions too, with nothing after the counter.
    assert.equal(await check(fixture.assertion(body, 3, { flags: 0x41 }), body, 2), 3);
  });

  test("rejects a replayed assertion", async () => {
    await assert.rejects(check(fixture.assertion(body, 3), body, 3), AppAttestError);
  });

  test("rejects a changed body", async () => {
    await assert.rejects(check(fixture.assertion(body, 1), utf8('{"manifestDigest":"!!!"}')), AppAttestError);
  });

  test("rejects another app and another key", async () => {
    await assert.rejects(check(fixture.assertion(body, 1, { appId: "ABCDE12345.com.example.evil" })), AppAttestError);
    await assert.rejects(check(fixture.assertion(body, 1, { signingKey: ecKeys("P-256") })), AppAttestError);
  });
});
