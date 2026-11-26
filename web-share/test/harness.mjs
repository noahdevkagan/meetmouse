// Loads src/index.js the way Wrangler would (text imports inlined) and
// backs D1 with an in-memory SQLite database carrying every migration.
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const src = name => new URL(`../src/${name}`, import.meta.url);

export async function loadWorker() {
  let source = readFileSync(src("index.js"), "utf8");
  source = source.replace(/import (\w+) from "\.\/([\w.-]+\.(?:html|css|txt))";/g,
    (_, name, file) => `const ${name} = ${JSON.stringify(readFileSync(src(file), "utf8"))};`);
  source = source.replace(/"\.\/([\w-]+\.js)"/g, (_, file) => JSON.stringify(src(file).href));
  const module = await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"));
  return module.default;
}

export function makeEnv() {
  const db = new DatabaseSync(":memory:");
  const migrations = new URL("../migrations/", import.meta.url);
  for (const file of readdirSync(migrations).sort()) {
    db.exec(readFileSync(new URL(file, migrations), "utf8"));
  }
  const env = {
    CREATE_RATE_LIMITER: { limit: async () => ({ success: true }) },
    DB: {
      prepare(sql) {
        return {
          bind(...args) {
            const statement = db.prepare(sql);
            return {
              run: async () => statement.run(...args),
              first: async () => statement.get(...args) ?? null,
              all: async () => ({ results: statement.all(...args) }),
            };
          },
        };
      },
    },
  };
  return { db, env };
}
