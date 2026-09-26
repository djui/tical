import { concat, type Bytes } from "./bytes.ts";
import type { Certificate } from "./certificate.ts";
import * as DER from "./der.ts";
import { OID } from "./der.ts";
import type { Signer } from "./signing.ts";

/**
 * Builds the detached PKCS #7 / CMS `SignedData` that Wallet expects in a pass's `signature`
 * file, from the SHA-256 digest of the pass's `manifest.json`. It's the same structure as
 * Tical/Wallet/CMSSignature.swift, which signs on the device with your own certificate.
 */
export async function detachedSignature(options: {
  /** SHA-256 of the signed content, which for a pass is `manifest.json`. */
  contentDigest: Bytes;
  /** The Pass Type ID certificate. */
  signer: Certificate;
  /** Certificates that link the signer to Apple's root: the WWDR intermediate. */
  intermediates: readonly Certificate[];
  signingTime: Date;
  sign: Signer["sign"];
}): Promise<Bytes> {
  const { contentDigest, signer, intermediates, signingTime } = options;
  const attributes = [
    attribute(OID.contentType, DER.objectIdentifier(OID.data)),
    attribute(OID.signingTime, DER.utcTime(signingTime)),
    attribute(OID.messageDigest, DER.octetString(contentDigest)),
  ];
  // The signature covers the attributes encoded as a SET; the SignerInfo carries the same
  // bytes under an implicit [0] tag.
  const signature = await options.sign(DER.set(attributes));

  const signerInfo = DER.sequence([
    DER.integer(1),
    DER.sequence([signer.issuer, signer.serialNumber]),
    DER.algorithmIdentifier(OID.sha256),
    DER.context(0, DER.setContents(attributes)),
    DER.algorithmIdentifier(OID.rsaEncryption),
    DER.octetString(signature),
  ]);

  const signedData = DER.sequence([
    DER.integer(1),
    DER.set([DER.algorithmIdentifier(OID.sha256)]),
    DER.sequence([DER.objectIdentifier(OID.data)]),
    DER.context(0, concat([signer, ...intermediates].map((certificate) => certificate.der))),
    DER.set([signerInfo]),
  ]);

  return DER.sequence([DER.objectIdentifier(OID.signedData), DER.context(0, signedData)]);
}

function attribute(type: string, value: Bytes): Bytes {
  return DER.sequence([DER.objectIdentifier(type), DER.set([value])]);
}
