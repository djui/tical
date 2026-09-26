/**
 * Tical's pass signing service. The app sends the SHA-256 digest of a pass's `manifest.json`
 * and gets back the pass's `signature` file. Ticket details never reach the server.
 *
 *   GET  /v1/pass-type   the pass type and team a pass must name to match the certificate
 *   POST /v1/challenges  a one-time challenge for registering an App Attest key
 *   POST /v1/keys        registers an App Attest key: { keyId, challenge, attestation }
 *   POST /v1/signatures  signs a pass: { keyId, manifestDigest }, with an App Attest
 *                        assertion over the exact body in the X-Tical-Assertion header
 */
import { AppAttestError, verifyAssertion, verifyAttestation } from "./appattest.ts";
import { fromBase64, randomBytes, toBase64, type Bytes } from "./bytes.ts";
import type { Certificate } from "./certificate.ts";
import { detachedSignature } from "./cms.ts";
import type { Signer } from "./signing.ts";
import type { Store } from "./store.ts";

export interface ServiceConfig {
  store: Store;
  /** Missing until the Pass Type ID certificate and its key are set up. */
  signing?: {
    signer: Signer;
    certificate: Certificate;
    /** Apple's WWDR intermediate, which Wallet needs in every signature. */
    intermediates: readonly Certificate[];
  };
  appIds: readonly string[];
  appAttestRoot: Certificate;
  /** Accepts keys from development-signed builds, which Xcode installs. */
  allowDevelopmentAttestation: boolean;
  /** Signs without App Attest, for the simulator and `wrangler dev` only. */
  allowUnattested: boolean;
  limits: {
    signaturesPerKeyPerDay: number;
    signaturesPerDay: number;
    keysPerDay: number;
  };
  now?: () => Date;
  log?: (message: string) => void;
}

export interface ServiceRequest {
  method: string;
  path: string;
  /** The X-Tical-Assertion header. */
  assertion?: string | null;
  body: Bytes;
}

export interface ServiceResponse {
  status: number;
  /** JSON. */
  body: string;
}

export type Service = (request: ServiceRequest) => Promise<ServiceResponse>;

/** Keys unused for this long are forgotten; the app registers a new one when needed. */
export const keyLifetime = 400 * 86_400;
const challengeLifetime = 5 * 60;
/** Far more than an attestation, the largest field, needs. */
const maxFieldLength = 64 * 1024;

class Rejection extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function createService(config: ServiceConfig): Service {
  const now = () => config.now?.() ?? new Date();
  const seconds = () => Math.floor(now().getTime() / 1000);

  async function passType(): Promise<object> {
    const certificate = signing().certificate;
    return { passTypeIdentifier: certificate.passTypeIdentifier, teamIdentifier: certificate.teamIdentifier };
  }

  async function createChallenge(): Promise<object> {
    const challenge = toBase64(randomBytes(32));
    await config.store.addChallenge(challenge, seconds() + challengeLifetime);
    return { challenge };
  }

  async function registerKey(body: Bytes): Promise<object> {
    const request = json(body);
    const keyId = text(request, "keyId");
    const keyBytes = base64(request, "keyId", 32);
    const challenge = text(request, "challenge");
    const attestation = base64(request, "attestation");
    if (!(await config.store.takeChallenge(challenge, seconds()))) {
      throw new Rejection(403, "invalid-challenge", "The challenge is unknown or has expired. Ask for a new one.");
    }
    let attested;
    try {
      attested = await verifyAttestation({
        attestation,
        challenge: base64(request, "challenge"),
        keyId: keyBytes,
        appIds: config.appIds,
        root: config.appAttestRoot,
        now: now(),
        allowDevelopment: config.allowDevelopmentAttestation,
      });
    } catch (error) {
      if (error instanceof AppAttestError) {
        config.log?.(`Rejected an attestation: ${error.message}`);
        throw new Rejection(403, "invalid-attestation", "The attestation isn't valid.");
      }
      throw error;
    }
    await consume(`keys:${day()}`, config.limits.keysPerDay);
    const added = await config.store.addKey({
      keyId,
      appId: attested.appId,
      publicKey: attested.publicKey,
      counter: 0,
      environment: attested.environment,
      receipt: attested.receipt,
      createdAt: seconds(),
    });
    if (!added) throw new Rejection(409, "key-exists", "This key is already registered.");
    return {};
  }

  async function sign(body: Bytes, assertion: string | null | undefined): Promise<object> {
    const request = json(body);
    const manifestDigest = base64(request, "manifestDigest", 32);
    const configured = signing();

    if (request.keyId === undefined) {
      if (!config.allowUnattested) {
        throw new Rejection(401, "attestation-required", "Requests need an App Attest key.");
      }
    } else {
      const keyId = text(request, "keyId");
      const record = await config.store.key(keyId);
      if (!record) throw new Rejection(401, "unknown-key", "This key isn't registered. Register a new one.");
      const assertionBytes = assertion ? fromBase64(assertion) : undefined;
      if (!assertionBytes) throw new Rejection(401, "assertion-required", "The X-Tical-Assertion header is missing.");
      let counter: number;
      try {
        counter = await verifyAssertion({
          assertion: assertionBytes,
          clientData: body,
          publicKey: record.publicKey,
          appId: record.appId,
          previousCounter: record.counter,
        });
      } catch (error) {
        if (error instanceof AppAttestError) {
          config.log?.(`Rejected an assertion: ${error.message}`);
          throw new Rejection(403, "invalid-assertion", "The assertion isn't valid.");
        }
        throw error;
      }
      if (!(await config.store.advanceCounter(keyId, counter, seconds()))) {
        throw new Rejection(403, "invalid-assertion", "The assertion was used before.");
      }
      await consume(`key:${keyId}:${day()}`, config.limits.signaturesPerKeyPerDay);
    }
    await consume(`signatures:${day()}`, config.limits.signaturesPerDay);

    const signature = await detachedSignature({
      contentDigest: manifestDigest,
      signer: configured.certificate,
      intermediates: configured.intermediates,
      signingTime: now(),
      sign: (data) => configured.signer.sign(data),
    });
    return { signature: toBase64(signature) };
  }

  function signing(): NonNullable<ServiceConfig["signing"]> {
    if (!config.signing) {
      throw new Rejection(503, "not-configured", "The signing certificate isn't set up yet.");
    }
    return config.signing;
  }

  async function consume(bucket: string, limit: number): Promise<void> {
    // Counts last for the day plus a day, which covers every time zone's idea of "today".
    const expiresAt = Math.floor(Date.parse(`${day()}T00:00:00Z`) / 1000) + 2 * 86_400;
    if (!(await config.store.consume(bucket, limit, expiresAt))) {
      throw new Rejection(429, "rate-limited", "Too many passes today. Try again tomorrow.");
    }
  }

  function day(): string {
    return now().toISOString().slice(0, 10);
  }

  const routes: Record<string, Record<string, (request: ServiceRequest) => Promise<object>>> = {
    "/v1/pass-type": { GET: passType },
    "/v1/challenges": { POST: createChallenge },
    "/v1/keys": { POST: (request) => registerKey(request.body) },
    "/v1/signatures": { POST: (request) => sign(request.body, request.assertion) },
  };

  return async (request) => {
    try {
      const route = routes[request.path];
      if (!route) throw new Rejection(404, "not-found", "There's nothing here.");
      const handler = route[request.method];
      if (!handler) throw new Rejection(405, "method-not-allowed", `Use ${Object.keys(route).join(" or ")}.`);
      const result = await handler(request);
      return { status: request.path === "/v1/keys" ? 201 : 200, body: JSON.stringify(result) };
    } catch (error) {
      if (error instanceof Rejection) {
        return { status: error.status, body: JSON.stringify({ error: error.code, message: error.message }) };
      }
      config.log?.(`Failed: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
      return { status: 500, body: JSON.stringify({ error: "internal", message: "Something went wrong." }) };
    }
  };
}

function json(body: Bytes): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch {
    // Reported below.
  }
  throw new Rejection(400, "bad-request", "The body must be a JSON object.");
}

function text(request: Record<string, unknown>, field: string): string {
  const value = request[field];
  if (typeof value !== "string" || value.length === 0 || value.length > maxFieldLength) {
    throw new Rejection(400, "bad-request", `"${field}" must be a string.`);
  }
  return value;
}

function base64(request: Record<string, unknown>, field: string, length?: number): Bytes {
  const bytes = fromBase64(text(request, field));
  if (!bytes || (length !== undefined && bytes.length !== length)) {
    const size = length === undefined ? "" : ` of ${length} bytes`;
    throw new Rejection(400, "bad-request", `"${field}" must be base64${size}.`);
  }
  return bytes;
}
