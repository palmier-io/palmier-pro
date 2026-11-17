import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(new URL("./sync.mjs", import.meta.url));

test("blank compiler labels are skipped and nonempty copy is retained", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "compositor-localization-"));
  try {
    const input = path.join(root, "labels.stringsdata");
    const output = path.join(root, "Localizable.strings");
    fs.writeFileSync(input, JSON.stringify({ tables: { Localizable: [{ key: "" }, { key: "API type" }] } }));
    const run = spawnSync(process.execPath, [script, "--output", output, "--stringsdata", input], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const catalog = fs.readFileSync(output, "utf8");
    assert.ok(catalog.includes('"API type" = "API type";'));
    assert.ok(!catalog.includes('"" = "";'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("malformed compiler keys fail without replacing the catalog", () => {
  for (const entry of [{}, { key: null }, { key: 7 }]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "compositor-localization-"));
    try {
      const input = path.join(root, "labels.stringsdata");
      const output = path.join(root, "Localizable.strings");
      fs.writeFileSync(input, JSON.stringify({ tables: { Localizable: [entry] } }));
      fs.writeFileSync(output, "Original catalog");
      const run = spawnSync(process.execPath, [script, "--output", output, "--stringsdata", input], { encoding: "utf8" });
      assert.notEqual(run.status, 0);
      assert.ok(run.stderr.includes("invalid localization key"));
      assert.equal(fs.readFileSync(output, "utf8"), "Original catalog");
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});
