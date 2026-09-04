import { describe, expect, test } from "bun:test";
import { buildEvalProcessEnv, shouldLoadDotEnv } from "./eval-helpers";

describe("eval helpers", () => {
  test("passes the selected eval model to ffx through FFX_MODEL", () => {
    const previous = process.env.FFX_MODEL;
    process.env.FFX_MODEL = "ambient/model";

    try {
      const env = buildEvalProcessEnv("/tmp/ffx-eval-home-test", "selected/model");

      expect(env.FFX_MODEL).toBe("selected/model");
      expect(env.HOME).toBe("/tmp/ffx-eval-home-test");
      expect(env.NO_COLOR).toBe("1");
    } finally {
      if (previous === undefined) {
        delete process.env.FFX_MODEL;
      } else {
        process.env.FFX_MODEL = previous;
      }
    }
  });

  test("does not load repository dotenv files in a hermetic run", () => {
    expect(shouldLoadDotEnv({ FFX_E2E_DISABLE_DOTENV: "1" })).toBe(false);
    expect(shouldLoadDotEnv({})).toBe(true);
  });
});
