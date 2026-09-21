import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { sha256Base64URL } from '../src/core.js';
let source = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
for (const [name, path] of [['viewerHTML','viewer.html'],['viewerCSS','viewer.css'],['viewerJS','viewer.js.txt']]) {
  source = source.replace(`import ${name} from "./${path}";`, `const ${name} = ${JSON.stringify(readFileSync(new URL('../src/'+path, import.meta.url),'utf8'))};`);
}
source = source.replaceAll('"./core.js"', JSON.stringify(new URL('../src/core.js', import.meta.url).href));
const { default: worker } = await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const id = 'abcdefghijklmnopqrstuv', token = 'owner-token-with-at-least-20-characters';
const body = {schemaVersion:1,id,nonce:'AAAAAAAAAAAAAAAA',ciphertext:'AAAAAAAAAAAAAAAAAAAAAAAA',revokeHash:await sha256Base64URL(token)};
function fixture(t) {
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(new URL('../migrations/0001_shared_notes.sql', import.meta.url),'utf8'));
  t.after(()=>db.close());
  const env = { CREATE_RATE_LIMITER: {limit:async()=>({success:true})}, DB: {prepare(sql) {
    return {bind(...args) {const statement=db.prepare(sql); return {run:async()=>statement.run(...args),first:async()=>statement.get(...args)};}};
  }}};
  const req=(path,options={})=>worker.fetch(new Request('https://example.com'+path,options),env);
  return { db, env, req,
    create:()=>req('/api/shared-notes/create',{method:'POST',body:JSON.stringify(body)}),
    revoke:(key=token)=>req('/api/shared-notes/'+id,{method:'DELETE',headers:{Authorization:'Bearer '+key}}),
    read:()=>req('/api/shared-notes/'+id) };
}
test('revocation preserves a tombstone and cannot be undone by a late create', async t=>{
  const f=fixture(t);
  assert.equal((await f.revoke()).status,204);
  assert.equal((await f.create()).status,409);
  assert.equal((await f.read()).status,404);
  assert.equal((await f.revoke()).status,204);
});
test('only the owner can revoke, and ciphertext is removed immediately',async t=>{
  const f=fixture(t);
  assert.equal((await f.create()).status,201);
  assert.equal((await f.revoke('wrong-token-with-enough-characters')).status,403);
  const res=await f.read(); const data=await res.json();
  assert.equal(res.status,200); assert.equal(res.headers.get('cache-control'),'no-store');
  assert.equal(data.revokeHash,undefined); assert.equal(data.revoke_hash,undefined);
  assert.equal((await f.revoke()).status,204);
  assert.equal((await f.read()).status,404);
  assert.equal(f.db.prepare('SELECT ciphertext FROM shared_notes WHERE id = ?').get(id).ciphertext,'');
});
test('expiry and rate limits are enforced by the handler',async t=>{
  const f=fixture(t); await f.create();
  f.db.exec('UPDATE shared_notes SET expires_at=0');
  assert.equal((await f.read()).status,410);
  f.env.CREATE_RATE_LIMITER.limit=async()=>({success:false});
  assert.equal((await f.create()).status,429);
});

test('missing-ID revocation shares creation quota without blocking existing owners', async t => {
  const f = fixture(t);
  let calls = 0;
  f.env.CREATE_RATE_LIMITER.limit = async ({ key }) => {
    assert.equal(key, 'local-development');
    calls++;
    return { success: false };
  };
  assert.equal((await f.revoke()).status, 429);
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM shared_notes').get().n, 0);
  assert.equal(calls, 1);
  f.env.CREATE_RATE_LIMITER.limit = async () => ({ success: true });
  assert.equal((await f.create()).status, 201);
  f.env.CREATE_RATE_LIMITER.limit = async () => { throw new Error('Existing revocations must not consume quota'); };
  assert.equal((await f.revoke('wrong-token-with-enough-characters')).status, 403);
  assert.equal((await f.read()).status, 200);
  assert.equal((await f.revoke()).status, 204);
  assert.equal((await f.revoke()).status, 204);
  assert.equal((await f.read()).status, 404);
});

test('tombstone allocation uses the same client IP key as creation', async t => {
  const f = fixture(t);
  const keys = [];
  f.env.CREATE_RATE_LIMITER.limit = async ({ key }) => {
    keys.push(key);
    return { success: keys.length === 1 };
  };
  const headers = { 'cf-connecting-ip': '192.0.2.1', Authorization: 'Bearer ' + token };
  assert.equal((await f.req('/api/shared-notes/' + id, { method: 'DELETE', headers })).status, 204);
  assert.equal((await f.req('/api/shared-notes/create', { method: 'POST', headers, body: JSON.stringify(body) })).status, 429);
  assert.deepEqual(keys, ['192.0.2.1', '192.0.2.1']);
});
