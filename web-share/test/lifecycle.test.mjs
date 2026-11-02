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
source = source.replaceAll('"./referrals.js"', JSON.stringify(new URL('../src/referrals.js', import.meta.url).href));
source = source.replaceAll('"./usage.js"', JSON.stringify(new URL('../src/usage.js', import.meta.url).href));
source = source.replaceAll('"./feedback.js"', JSON.stringify(new URL('../src/feedback.js', import.meta.url).href));
const { default: worker } = await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const id = 'abcdefghijklmnopqrstuv', token = 'owner-token-with-at-least-20-characters';
const body = {schemaVersion:1,id,nonce:'AAAAAAAAAAAAAAAA',ciphertext:'AAAAAAAAAAAAAAAAAAAAAAAA',revokeHash:await sha256Base64URL(token)};
function fixture(t) {
  const db = new DatabaseSync(':memory:');
  for (const m of ['0001_shared_notes.sql','0002_referral_clicks.sql','0003_usage.sql','0004_feedback.sql']) db.exec(readFileSync(new URL('../migrations/'+m, import.meta.url),'utf8'));
  t.after(()=>db.close());
  const env = { CREATE_RATE_LIMITER: {limit:async()=>({success:true})}, USAGE_RATE_LIMITER: {limit:async()=>({success:true})}, DB: {prepare(sql) {
    return {bind(...args) {const statement=db.prepare(sql); return {run:async()=>statement.run(...args),first:async()=>statement.get(...args)};},
      first:async()=>db.prepare(sql).get(), all:async()=>({results:db.prepare(sql).all()})};
  }, batch:async(statements)=>Promise.all(statements.map(s=>s.run()))}};
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

test('referral: two distinct friends unlock, repeat clicks count once', async t => {
  const f = fixture(t);
  const code = 'abcd2345';
  const click = (ip, to = 'appsumo') => f.req(`/r/${code}/go?to=${to}`, { headers: { 'cf-connecting-ip': ip, 'user-agent': 'ua' } });
  assert.match(await (await f.req(`/r/${code}`)).text(), /A friend gave you MeetMouse/);
  const first = await click('1.1.1.1');
  assert.equal(first.status, 302);
  assert.equal(first.headers.get('location'), 'https://appsumo.com/products/meeting-coach/');
  await click('1.1.1.1');
  assert.match(await (await f.req(`/r/${code}/status`)).text(), /1 of 2 friends/);
  await click('2.2.2.2', 'appsumo');
  const done = await (await f.req(`/r/${code}/status`)).text();
  assert.match(done, /meetmouse:\/\/unlock\?code=MOUSE-/);
  assert.equal((await f.req('/r/NOTACODE')).status, 404);
});

test('usage reports are stored as counts and surface only as aggregates', async t=>{
  const f=fixture(t);
  const day=new Date().toISOString().slice(0,10);
  const report={installId:'3F2504E0-4F89-41D3-9A0C-0305E82C3301',appVersion:'0.34.0',osMajor:15,days:[{day,meetings:2,meetingMinutes:125,nudges:4}]};
  assert.equal((await f.req('/api/usage',{method:'POST',body:JSON.stringify(report)})).status,204);
  assert.equal((await f.req('/api/usage',{method:'POST',body:JSON.stringify({...report,notes:'x'})})).status,400);
  const res=await f.req('/api/stats'); const stats=await res.json();
  assert.equal(res.headers.get('cache-control'),'public, max-age=3600');
  assert.equal(res.headers.get('access-control-allow-origin'),'https://meetmouse.com');
  assert.deepEqual(stats,{meetings:2,hoursCoached:2,nudges:4,activeInstalls30d:1,downloads:0});
  assert.equal(JSON.stringify(stats).includes('3f2504e0'),false);
  f.env.USAGE_RATE_LIMITER.limit=async()=>({success:false});
  assert.equal((await f.req('/api/usage',{method:'POST',body:JSON.stringify(report)})).status,429);
});

test('feedback: accepted, deleted on opt-out, summary only with the admin token', async t=>{
  const f=fixture(t);
  const installId='3F2504E0-4F89-41D3-9A0C-0305E82C3301';
  const day=new Date().toISOString().slice(0,10);
  const report={installId,appVersion:'0.34.0',events:[{eventId:'6F9619FF-8B86-D011-B42D-00C04FC964FF',day,signal:'talkTime',rating:'useful',minute:5,meetingType:'general',features:{youShare:0.5}}]};
  assert.equal((await f.req('/api/feedback',{method:'POST',body:JSON.stringify(report)})).status,204);
  assert.equal((await f.req('/api/feedback',{method:'POST',body:JSON.stringify({...report,transcript:'x'})})).status,400);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM feedback_events').get().n,1);
  assert.equal((await f.req('/api/admin/feedback-summary')).status,404);
  f.env.ADMIN_TOKEN='a'.repeat(40);
  assert.equal((await f.req('/api/admin/feedback-summary',{headers:{Authorization:'Bearer wrong'}})).status,401);
  const ok=await f.req('/api/admin/feedback-summary',{headers:{Authorization:'Bearer '+'a'.repeat(40)}});
  assert.equal(ok.status,200); assert.deepEqual((await ok.json()).signals,[]);
  assert.equal((await f.req('/api/feedback/'+installId,{method:'DELETE'})).status,204);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM feedback_events').get().n,0);
  f.env.USAGE_RATE_LIMITER.limit=async()=>({success:false});
  assert.equal((await f.req('/api/feedback',{method:'POST',body:JSON.stringify(report)})).status,429);
});
