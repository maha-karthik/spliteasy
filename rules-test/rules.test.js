const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { initializeTestEnvironment, assertFails, assertSucceeds } = require('@firebase/rules-unit-testing');
const { doc, setDoc, getDoc, getDocs, collection, deleteDoc, updateDoc, writeBatch, serverTimestamp, Timestamp } = require('firebase/firestore');

let env;
const G = 'group-1';
const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();
const hours = (h) => Timestamp.fromMillis(Date.now() + h * 3600 * 1000);

// alice creates group G as admin (group + her member document in one batch)
async function createGroup(uid = 'alice', gid = G) {
  const db = as(uid);
  const b = writeBatch(db);
  b.set(doc(db, 'groups', gid), { name: 'Travel', kitty: 0, adminUid: uid, createdAt: serverTimestamp() });
  b.set(doc(db, 'groups', gid, 'members', uid), { role: 'admin', memberUid: '', name: uid, inviteCode: '', joinedAt: serverTimestamp() });
  await b.commit();
}
async function invite(code = 'K7M2QX', expires = hours(24)) {
  await setDoc(doc(as('alice'), 'invites', code), {
    gid: G, groupName: 'Travel', createdBy: 'alice', createdAt: serverTimestamp(), expiresAt: expires, people: [{ uid: 'm1', name: 'Roshan' }],
  });
}
const joinDoc = (code, role = 'member') => ({ role, memberUid: 'm1', name: 'bob', inviteCode: code, joinedAt: serverTimestamp() });
const op = (uid, table = 'expense', extra = {}) => ({
  table, recUid: 'u1', action: 'upsert', payload: '{"title":"tea"}', updatedAt: 1000, origin: uid, createdAt: serverTimestamp(), ...extra,
});

describe('SplitEasy Firestore rules', () => {
  before(async () => {
    env = await initializeTestEnvironment({
      projectId: 'demo-spliteasy',
      firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
    });
  });
  beforeEach(async () => { await env.clearFirestore(); });
  after(async () => { await env.cleanup(); });

  it('a signed-in person can create a group as its admin', async () => { await assertSucceeds(createGroup()); });
  it('nobody can create a group naming someone else as admin', async () => {
    const db = as('mallory');
    await assertFails(setDoc(doc(db, 'groups', 'g2'), { name: 'x', kitty: 0, adminUid: 'alice', createdAt: serverTimestamp() }));
  });
  it('signed-out users can do nothing', async () => {
    await assertFails(setDoc(doc(anon(), 'groups', 'g2'), { name: 'x', kitty: 0, adminUid: 'a', createdAt: serverTimestamp() }));
  });
  it('a stranger cannot make themselves admin of someone else\'s group', async () => {
    await createGroup();
    await assertFails(setDoc(doc(as('mallory'), 'groups', G, 'members', 'mallory'), { role: 'admin', memberUid: '', name: 'm', inviteCode: '', joinedAt: serverTimestamp() }));
  });
  it('a non-member cannot read the group, its members or its changes', async () => {
    await createGroup();
    await assertFails(getDoc(doc(as('mallory'), 'groups', G)));
    await assertFails(getDocs(collection(as('mallory'), 'groups', G, 'ops')));
    await assertFails(getDocs(collection(as('mallory'), 'groups', G, 'members')));
  });
  it('invite codes: lookup of one code works, listing does not', async () => {
    await createGroup();
    await invite();
    await assertSucceeds(getDoc(doc(as('bob'), 'invites', 'K7M2QX')));
    await assertFails(getDocs(collection(as('bob'), 'invites')));
    await assertFails(getDoc(doc(anon(), 'invites', 'K7M2QX')));
  });
  it('only an admin can create an invite, and only for 8 days or less', async () => {
    await createGroup();
    await assertFails(setDoc(doc(as('bob'), 'invites', 'AAAAAA'), { gid: G, groupName: 'T', createdBy: 'bob', createdAt: serverTimestamp(), expiresAt: hours(24), people: [] }));
    await assertFails(invite('BBBBBB', hours(24 * 30)));
    await assertSucceeds(invite('CCCCCC', hours(24 * 7)));
  });
  it('a person with a valid code can join as a member', async () => {
    await createGroup();
    await invite();
    await assertSucceeds(setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('K7M2QX')));
    await assertSucceeds(getDoc(doc(as('bob'), 'groups', G)));
  });
  it('joining fails with a wrong, expired, or someone else\'s code, or as admin', async () => {
    await createGroup();
    await createGroup('dave', 'group-2');
    await invite();
    await invite('OLDOLD', hours(-1));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('ZZZZZZ')));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('OLDOLD')));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('K7M2QX', 'admin')));
    await assertFails(setDoc(doc(as('bob'), 'groups', 'group-2', 'members', 'bob'), joinDoc('K7M2QX'))); // code belongs to another group
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'members', 'carol'), joinDoc('K7M2QX'))); // for someone else's uid
  });
  it('members can add expense, payment and top-up changes as themselves', async () => {
    await createGroup();
    await invite();
    await setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('K7M2QX'));
    for (const t of ['expense', 'settlement', 'topup']) {
      await assertSucceeds(setDoc(doc(as('bob'), 'groups', G, 'ops', 'op-' + t), op('bob', t)));
    }
  });
  it('a member cannot forge another person\'s name on a change, or backdate its server time', async () => {
    await createGroup();
    await invite();
    await setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('K7M2QX'));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'ops', 'f1'), op('alice')));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'ops', 'f2'), op('bob', 'expense', { createdAt: Timestamp.fromMillis(1000) })));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'ops', 'f3'), op('bob', 'expense', { extra: 'x' })));
  });
  it('only the admin can change members or the group itself', async () => {
    await createGroup();
    await invite();
    await setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('K7M2QX'));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'ops', 'm1'), op('bob', 'member')));
    await assertFails(setDoc(doc(as('bob'), 'groups', G, 'ops', 'g1'), op('bob', 'grp')));
    await assertSucceeds(setDoc(doc(as('alice'), 'groups', G, 'ops', 'm2'), op('alice', 'member')));
    await assertSucceeds(setDoc(doc(as('alice'), 'groups', G, 'ops', 'g2'), op('alice', 'grp')));
  });
  it('a non-member cannot write changes', async () => {
    await createGroup();
    await assertFails(setDoc(doc(as('mallory'), 'groups', G, 'ops', 'x'), op('mallory')));
  });
  it('changes cannot be edited or deleted by anyone, including the admin', async () => {
    await createGroup();
    await setDoc(doc(as('alice'), 'groups', G, 'ops', 'o1'), op('alice'));
    await assertFails(updateDoc(doc(as('alice'), 'groups', G, 'ops', 'o1'), { payload: '{}' }));
    await assertFails(deleteDoc(doc(as('alice'), 'groups', G, 'ops', 'o1')));
    await assertFails(deleteDoc(doc(as('alice'), 'groups', G)));
  });
  it('members can read the shared changes', async () => {
    await createGroup();
    await invite();
    await setDoc(doc(as('bob'), 'groups', G, 'members', 'bob'), joinDoc('K7M2QX'));
    await setDoc(doc(as('alice'), 'groups', G, 'ops', 'o1'), op('alice'));
    const snap = await assertSucceeds(getDocs(collection(as('bob'), 'groups', G, 'ops')));
    assert.strictEqual(snap.size, 1);
  });
});
