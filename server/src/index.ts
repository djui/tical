/** The Cloudflare Worker: configuration from the environment, and HTTP around the service. */
import appAttestRootPEM from "../certificates/AppleAppAttestationRootCA.pem";
import { Certificate } from "./certificate.ts";
import { D1Store, type D1Database } from "./d1.ts";
import { createService, keyLifetime, type Service, type ServiceConfig } from "./service.ts";
import { rsaSigner, signerMatches } from "./signing.ts";

interface Env {
  DB: D1Database;
  /** Secret: the Pass Type ID certificate's RSA private key, PKCS #8 PEM. */
  SIGNING_KEY?: string;
  /** Secret: the Pass Type ID certificate, then Apple's WWDR intermediate, as PEM. */
  SIGNING_CERTIFICATES?: string;
  /** Comma-separated, like `ABCDE12345.com.example.app`. */
  APP_IDS?: string;
  ALLOW_DEVELOPMENT_ATTESTATION?: string;
  /** Only ever set in .dev.vars, for the simulator, which can't use App Attest. */
  ALLOW_UNATTESTED?: string;
  SIGNATURES_PER_KEY_PER_DAY?: string;
  SIGNATURES_PER_DAY?: string;
  KEYS_PER_DAY?: string;
}

/** Bodies are small JSON objects; the largest, a key registration, is under 10 KB. */
const maxBodySize = 64 * 1024;

let cached: { env: Env; service: Promise<Service> } | undefined;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!cached || cached.env !== env) cached = { env, service: makeService(env) };
    const service = await cached.service;

    const declared = Number(request.headers.get("content-length") ?? 0);
    const body = declared > maxBodySize ? undefined : new Uint8Array(await request.arrayBuffer());
    if (!body || body.length > maxBodySize) {
      return respond(413, JSON.stringify({ error: "too-large", message: "The request is too large." }));
    }
    const result = await service({
      method: request.method,
      path: new URL(request.url).pathname,
      assertion: request.headers.get("x-tical-assertion"),
      body,
    });
    return respond(result.status, result.body);
  },

  async scheduled(_controller: unknown, env: Env): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    await new D1Store(env.DB).removeExpired(now, now - keyLifetime);
  },
};

function respond(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

async function makeService(env: Env): Promise<Service> {
  const log = (message: string) => console.log(message);
  return createService({
    store: new D1Store(env.DB),
    signing: await signing(env, log),
    appIds: (env.APP_IDS ?? "").split(",").map((id) => id.trim()).filter(Boolean),
    appAttestRoot: Certificate.fromPEM(appAttestRootPEM)[0]!,
    allowDevelopmentAttestation: env.ALLOW_DEVELOPMENT_ATTESTATION === "true",
    allowUnattested: env.ALLOW_UNATTESTED === "true",
    limits: {
      signaturesPerKeyPerDay: number(env.SIGNATURES_PER_KEY_PER_DAY, 30),
      signaturesPerDay: number(env.SIGNATURES_PER_DAY, 5_000),
      keysPerDay: number(env.KEYS_PER_DAY, 2_000),
    },
    log,
  });
}

/** Loads the signing identity, or leaves signing off with a log message when it's missing or wrong. */
async function signing(env: Env, log: (message: string) => void): Promise<ServiceConfig["signing"]> {
  if (!env.SIGNING_KEY || !env.SIGNING_CERTIFICATES) {
    log("Signing is off: set the SIGNING_KEY and SIGNING_CERTIFICATES secrets.");
    return undefined;
  }
  try {
    const [certificate, ...intermediates] = Certificate.fromPEM(env.SIGNING_CERTIFICATES);
    if (!certificate?.passTypeIdentifier || !certificate.teamIdentifier) {
      log("Signing is off: the first certificate in SIGNING_CERTIFICATES isn't a Pass Type ID certificate.");
      return undefined;
    }
    if (intermediates.length === 0) log("Warning: SIGNING_CERTIFICATES has no intermediate, which Wallet needs.");
    const signer = await rsaSigner(env.SIGNING_KEY);
    if (!(await signerMatches(signer, certificate))) {
      log("Signing is off: SIGNING_KEY doesn't belong to the certificate in SIGNING_CERTIFICATES.");
      return undefined;
    }
    return { signer, certificate, intermediates };
  } catch (error) {
    log(`Signing is off: ${error instanceof Error ? error.message : String(error)}`);
    return undefined;
  }
}

function number(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
