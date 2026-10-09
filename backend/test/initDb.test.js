const test = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');

const scriptPath = require.resolve('../src/scripts/initDb');

function loadInitDatabase(pool) {
  const originalLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (parent?.filename === scriptPath) {
      if (request === '../config/database') return { pool };
      if (request === 'dotenv') return { config: () => ({}) };
    }
    return originalLoad.apply(this, arguments);
  };
  try {
    delete require.cache[scriptPath];
    return require(scriptPath).initDatabase;
  } finally {
    Module._load = originalLoad;
    delete require.cache[scriptPath];
  }
}

test('initialization upgrades existing authentication tables and can run again', async () => {
  const statements = [];
  let releases = 0;
  const client = {
    query: async (sql) => { statements.push(sql); },
    release: () => { releases++; },
  };
  const initDatabase = loadInitDatabase({ connect: async () => client });
  await initDatabase();
  await initDatabase();

  assert.equal(releases, 2);
  assert.equal(statements.length % 2, 0);
  const sql = statements.join('\n');
  assert.match(sql, /ALTER TABLE users ADD COLUMN IF NOT EXISTS "displayName"/);
  assert.match(sql, /ALTER TABLE users ADD COLUMN IF NOT EXISTS "isLocked"/);
  assert.match(sql, /ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS "deviceId"/);
  assert.match(sql, /ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS "expiresAt"/);
});

test('initialization releases its connection on failure', async () => {
  let released = false;
  const failure = new Error('database unavailable');
  const initDatabase = loadInitDatabase({
    connect: async () => ({
      query: async () => { throw failure; },
      release: () => { released = true; },
    }),
  });
  await assert.rejects(initDatabase(), failure);
  assert.equal(released, true);
});
