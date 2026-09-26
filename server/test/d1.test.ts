import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { getPlatformProxy } from "wrangler";
import { D1Store, type D1Database } from "../src/d1.ts";

/** D1Store against a local D1, as `wrangler dev` runs it, with the real migrations. */
describe("D1Store", () => {
  let proxy: Awaited<ReturnType<typeof getPlatformProxy<{ DB: D1Database }>>>;
  let store: D1Store;

  before(async () => {
    proxy = await getPlatformProxy<{ DB: D1Database }>({ persist: false });
    const db = proxy.env.DB;
    const migration = readFileSync(new URL("../migrations/0001_initial.sql", import.meta.url), "utf8");
    for (const statement of migration.split(";").map((part) => part.trim()).filter(Boolean)) {
      await db.prepare(statement).run();
    }
    store = new D1Store(db);
  });

  after(async () => {
    await proxy.dispose();
  });

  const key = {
    keyId: "a2V5",
    appId: "ABCDE12345.com.example.tical",
    publicKey: Uint8Array.of(1, 2, 3),
    counter: 0,
    environment: "production",
    receipt: Uint8Array.of(9),
    createdAt: 1_000,
  };

  test("hands out each challenge once, until it expires", async () => {
    await store.addChallenge("fresh", 2_000);
    await store.addChallenge("stale", 1_500);
    assert.equal(await store.takeChallenge("fresh", 1_600), true);
    assert.equal(await store.takeChallenge("fresh", 1_600), false);
    assert.equal(await store.takeChallenge("stale", 1_600), false);
    assert.equal(await store.takeChallenge("unknown", 1_600), false);
  });

  test("adds a key once and reads it back", async () => {
    assert.equal(await store.addKey(key), true);
    assert.equal(await store.addKey(key), false);
    const { receipt: _, ...stored } = key;
    assert.deepEqual(await store.key(key.keyId), stored);
    assert.equal(await store.key("unknown"), undefined);
  });

  test("only ever raises a key's counter", async () => {
    assert.equal(await store.advanceCounter(key.keyId, 5, 1_100), true);
    assert.equal(await store.advanceCounter(key.keyId, 5, 1_100), false);
    assert.equal(await store.advanceCounter(key.keyId, 4, 1_100), false);
    assert.equal(await store.advanceCounter("unknown", 9, 1_100), false);
    assert.equal((await store.key(key.keyId))?.counter, 5);
  });

  test("stops counting at the limit", async () => {
    const results = [];
    for (let index = 0; index < 4; index++) results.push(await store.consume("day", 3, 5_000));
    assert.deepEqual(results, [true, true, true, false]);
    assert.equal(await store.consume("other day", 3, 5_000), true);
  });

  test("forgets what has expired", async () => {
    await store.addChallenge("old", 1_000);
    await store.consume("old day", 3, 1_000);
    await store.removeExpired(1_200, 1_150);
    assert.equal(await store.takeChallenge("old", 0), false);
    assert.equal(await store.consume("old day", 1, 9_000), true, "the old count is gone");
    assert.equal(await store.key(key.keyId), undefined, "the key was last used before the cutoff");
  });
});
