import { defineConfig } from "vitest/config";
import * as path from "node:path";

const web = path.resolve(__dirname, "../../apps/web");

export default defineConfig({
  resolve: {
    alias: {
      // The route handlers under test import @opennextjs/cloudflare through
      // apps/web's own copy; pointing the tests' mocks at that same copy is
      // what makes `vi.mock("@opennextjs/cloudflare")` apply to them.
      "@opennextjs/cloudflare": path.resolve(web, "node_modules/@opennextjs/cloudflare"),
      "@": web,
    },
  },
  test: {
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    environment: "node",
  },
});
