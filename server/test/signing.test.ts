import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, verify, X509Certificate } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { pem } from "../src/bytes.ts";
import { Certificate } from "../src/certificate.ts";
import { detachedSignature } from "../src/cms.ts";
import * as DER from "../src/der.ts";
import { OID, Tag } from "../src/der.ts";
import { rsaSigner, signerMatches } from "../src/signing.ts";
import { bytes, passSigningChain } from "../scripts/pki.ts";

const chain = passSigningChain("pass.example.tickets", "ABCDE12345");
const pass = new Certificate(chain.pass);
const authority = new Certificate(chain.authority);
const signer = await rsaSigner(chain.passKey.export({ type: "pkcs8", format: "pem" }) as string);
const manifest = new TextEncoder().encode('{"pass.json":"0123456789abcdef"}');
const manifestDigest = bytes(createHash("sha256").update(manifest).digest());

describe("Certificate", () => {
  test("reads the pass type and team from a Pass Type ID certificate", () => {
    assert.equal(pass.passTypeIdentifier, "pass.example.tickets");
    assert.equal(pass.teamIdentifier, "ABCDE12345");
    assert.equal(pass.commonName, "Pass Type ID: pass.example.tickets");
    assert.ok(pass.isIssuedBy(authority));
    assert.ok(authority.isCertificateAuthority);
    assert.ok(!pass.isCertificateAuthority);
  });

  test("reads Apple's certificates", async () => {
    const { readFile } = await import("node:fs/promises");
    const [wwdr] = Certificate.fromPEM(await readFile(new URL("../certificates/AppleWWDRCAG4.pem", import.meta.url), "utf8"));
    assert.equal(wwdr?.subjectAttributes.get(OID.organizationalUnitName), "G4");
    const [root] = Certificate.fromPEM(await readFile(new URL("../certificates/AppleAppAttestationRootCA.pem", import.meta.url), "utf8"));
    assert.equal(root?.commonName, "Apple App Attestation Root CA");
    assert.equal(root?.signatureAlgorithm, OID.ecdsaWithSHA384);
  });
});

describe("rsaSigner", () => {
  test("matches only its own certificate", async () => {
    assert.ok(await signerMatches(signer, pass));
    assert.ok(!(await signerMatches(signer, authority)));
  });
});

const signingTime = new Date("2026-09-26T10:00:00Z");
const signature = await detachedSignature({
  contentDigest: manifestDigest,
  signer: pass,
  intermediates: [authority],
  signingTime,
  sign: (data) => signer.sign(data),
});

describe("detachedSignature", () => {
  test("signs the attributes that carry the manifest digest", () => {
    const [type, content] = DER.children(DER.parse(signature));
    assert.equal(DER.objectIdentifierString(type!.content), OID.signedData);
    const [version, , , certificates, signerInfos] = DER.children(DER.children(content!)[0]!);
    assert.deepEqual(version!.content, Uint8Array.of(1));
    const included = DER.children(certificates!).map((node) => new Certificate(node.encoded.slice()));
    assert.deepEqual(included.map((certificate) => certificate.der), [pass.der, authority.der]);

    const info = DER.children(DER.children(signerInfos!)[0]!);
    const attributes = DER.children(info[3]!);
    const values = new Map(attributes.map((attribute) => {
      const [oid, set] = DER.children(attribute);
      return [DER.objectIdentifierString(oid!.content), DER.children(set!)[0]!] as const;
    }));
    assert.deepEqual(values.get(OID.messageDigest)?.content, manifestDigest);
    assert.deepEqual(DER.dateValue(values.get(OID.signingTime)!), signingTime);
    assert.equal(DER.objectIdentifierString(values.get(OID.contentType)!.content), OID.data);

    // The signature covers the attributes re-encoded as a SET.
    const signed = DER.tlv(Tag.set, info[3]!.content);
    assert.ok(verify("sha256", signed, new X509Certificate(pass.der).publicKey, info[5]!.content));
  });

  const openssl = spawnSync("openssl", ["version"]).status === 0;
  test("verifies with OpenSSL", { skip: !openssl && "OpenSSL isn't installed" }, () => {
    const folder = mkdtempSync(join(tmpdir(), "tical-cms-"));
    after(() => rmSync(folder, { recursive: true, force: true }));
    writeFileSync(join(folder, "manifest.json"), manifest);
    writeFileSync(join(folder, "signature"), signature);
    writeFileSync(join(folder, "authority.pem"), pem(authority.der, "CERTIFICATE"));
    const result = spawnSync("openssl", [
      "cms", "-verify", "-binary", "-inform", "DER",
      "-in", join(folder, "signature"),
      "-content", join(folder, "manifest.json"),
      "-CAfile", join(folder, "authority.pem"),
      "-purpose", "any",
      "-out", join(folder, "verified"),
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  });
});
