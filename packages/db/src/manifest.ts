import type { MigrationManifest } from "./types.js";

// Every migration the runner applies, in order, with the sha256 of its file.
// `pnpm --filter @saas/db run manifest:check` verifies the checksums;
// `manifest:fix` rewrites them after a migration file changes (only ever
// before that migration has been applied anywhere — an applied migration's
// checksum is immutable).
export const manifest: MigrationManifest = {
  version: 1,
  migrations: [
    {
      id: "000_control_baseline",
      context: "control",
      path: "000_control/up.sql",
      checksum:
        "2a5d7f30684c99e3ff441ca8a2c38038dedd1bab4db4a40e92cd36bb22be297f",
      description:
        "Baseline control migration — creates the migration tracking schema",
    },
    {
      id: "010_initial",
      context: "app",
      path: "010_initial/up.sql",
      checksum:
        "e4fae1018fc8f510c293e7d1ea0bc9006f7d4f95f6715a7f015c121bd0051825",
      description:
        "The chatbot's schema, verbatim from upstream lib/db/migrations/0000_initial.sql: User, Chat, Message_v2, Vote_v2, Document, Suggestion, Stream",
    },
  ],
};
