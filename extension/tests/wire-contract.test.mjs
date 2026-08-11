import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {dirname, resolve} from "node:path";

import {validateNativeWireMessage} from "../dist/wire-contract.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(
  await readFile(resolve(here, "../../contracts/native-message-fixtures.json"), "utf8"),
);

test("shared native-message fixtures", () => {
  for (const message of fixtures.valid) assert.equal(validateNativeWireMessage(message), true);
  for (const message of fixtures.invalid) assert.equal(validateNativeWireMessage(message), false);
});
