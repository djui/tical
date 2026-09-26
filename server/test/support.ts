/**
 * App Attest objects built the way Apple documents them, signed by a made-up App
 * Attestation root, so the checks can be tested without a device.
 */
import { createHash, sign } from "node:crypto";
import { concat, utf8, type Bytes } from "../src/bytes.ts";
import * as CBOR from "../src/cbor.ts";
import { Certificate } from "../src/certificate.ts";
import * as DER from "../src/der.ts";
import { OID } from "../src/der.ts";
import { ecPoint } from "../src/signing.ts";
import { authorityExtensions, bytes, certificate, ecKeys, extension, name, type KeyPair } from "../scripts/pki.ts";

export const appId = "ABCDE12345.com.example.tical";

export function sha256(data: Bytes): Bytes {
  return bytes(createHash("sha256").update(data).digest());
}

export class AppAttestFixture {
  readonly rootKeys = ecKeys("P-384");
  readonly rootName = name([[OID.commonName, "Test App Attestation Root CA"]]);
  readonly root = new Certificate(
    certificate({
      subject: this.rootName,
      issuer: this.rootName,
      publicKey: this.rootKeys.publicKey,
      signingKey: this.rootKeys.privateKey,
      extensions: authorityExtensions,
    }),
  );
  readonly intermediateKeys = ecKeys("P-384");
  readonly intermediateName = name([[OID.commonName, "Test App Attestation CA 1"]]);
  readonly intermediate = certificate({
    subject: this.intermediateName,
    issuer: this.rootName,
    publicKey: this.intermediateKeys.publicKey,
    signingKey: this.rootKeys.privateKey,
    extensions: authorityExtensions,
  });
  /** The key the Secure Enclave would hold. */
  readonly credential: KeyPair = ecKeys("P-256");
  readonly publicKey = bytes(this.credential.publicKey.export({ type: "spki", format: "der" }));
  readonly keyId = sha256(ecPoint(this.publicKey));

  attestation(
    challenge: Bytes,
    options: {
      appId?: string;
      counter?: number;
      aaguid?: Bytes;
      credentialId?: Bytes;
      nonce?: Bytes;
      notAfter?: Date;
      fmt?: string;
    } = {},
  ): Bytes {
    const aaguid = options.aaguid ?? concat([utf8("appattest"), new Uint8Array(7)]);
    const credentialId = options.credentialId ?? this.keyId;
    const point = ecPoint(this.publicKey);
    const coseKey = CBOR.encode(new Map<CBOR.Value, CBOR.Value>([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, point.slice(1, 33)],
      [-3, point.slice(33)],
    ]));
    const authData = concat([
      sha256(utf8(options.appId ?? appId)),
      Uint8Array.of(0x41),
      counter(options.counter ?? 0),
      aaguid,
      Uint8Array.of(credentialId.length >> 8, credentialId.length & 0xff),
      credentialId,
      coseKey,
    ]);
    const nonce = options.nonce ?? sha256(concat([authData, sha256(challenge)]));
    const credentialCertificate = certificate({
      subject: name([[OID.commonName, Buffer.from(this.keyId).toString("hex")]]),
      issuer: this.intermediateName,
      publicKey: this.credential.publicKey,
      signingKey: this.intermediateKeys.privateKey,
      notAfter: options.notAfter,
      extensions: [extension(OID.appAttestNonce, DER.sequence([DER.context(1, DER.octetString(nonce))]))],
    });
    return CBOR.encode({
      fmt: options.fmt ?? "apple-appattest",
      attStmt: { x5c: [credentialCertificate, this.intermediate], receipt: utf8("receipt") },
      authData,
    });
  }

  assertion(clientData: Bytes, counterValue: number, options: { appId?: string; signingKey?: KeyPair; extra?: Bytes; flags?: number } = {}): Bytes {
    const authenticatorData = concat([
      sha256(utf8(options.appId ?? appId)),
      Uint8Array.of(options.flags ?? 0x01),
      counter(counterValue),
      options.extra ?? new Uint8Array(0),
    ]);
    const nonce = sha256(concat([authenticatorData, sha256(clientData)]));
    const signature = bytes(sign("sha256", nonce, (options.signingKey ?? this.credential).privateKey));
    return CBOR.encode({ signature, authenticatorData });
  }
}

function counter(value: number): Bytes {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, value);
  return bytes;
}
