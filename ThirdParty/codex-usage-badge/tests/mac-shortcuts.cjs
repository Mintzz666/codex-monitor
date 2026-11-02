const assert=require('node:assert/strict');
const {DatabaseSync}=require('node:sqlite');
const {removeLaunchpadEntries}=require('../macos/shortcuts.cjs');
const db=new DatabaseSync(':memory:');
try{
  db.exec(`CREATE TABLE items(rowid INTEGER PRIMARY KEY,type INTEGER,parent_id INTEGER,ordering INTEGER);
    CREATE TABLE apps(item_id INTEGER PRIMARY KEY,title TEXT,bundleid TEXT);
    CREATE TABLE image_cache(item_id INTEGER);
    CREATE TRIGGER item_deleted AFTER DELETE ON items BEGIN DELETE FROM apps WHERE item_id=old.rowid;DELETE FROM image_cache WHERE item_id=old.rowid;UPDATE items SET ordering=ordering-1 WHERE parent_id=old.parent_id AND ordering>old.ordering;END;
    INSERT INTO items VALUES(1,4,10,0),(2,4,10,1),(3,4,10,2);
    INSERT INTO apps VALUES(1,'Other','example.other'),(2,'Codex 用量条','local.codexusagebadge.launcher'),(3,'Codex 用量条','example.same-title');
    INSERT INTO image_cache VALUES(1),(2),(3);`);
  assert.equal(removeLaunchpadEntries(db),1);
  assert.deepEqual(db.prepare('SELECT item_id FROM apps ORDER BY item_id').all().map(r=>r.item_id),[1,3]);
  assert.equal(db.prepare('SELECT ordering FROM items WHERE rowid=3').get().ordering,1);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM image_cache WHERE item_id=2').get().n,0);
  assert.equal(removeLaunchpadEntries(db),0);
  db.exec("INSERT INTO items VALUES(4,2,10,2);INSERT INTO apps VALUES(4,'Wrong type','local.codexusagebadge.launcher')");
  assert.throws(()=>removeLaunchpadEntries(db),/Unexpected/);
  assert.ok(db.prepare('SELECT 1 FROM items WHERE rowid=4').get());
  db.exec('UPDATE items SET type=4 WHERE rowid=4;INSERT INTO items VALUES(5,4,4,0)');
  assert.throws(()=>removeLaunchpadEntries(db),/children/);
  assert.ok(db.prepare('SELECT 1 FROM apps WHERE item_id=4').get());
  console.log('PASS exact launcher identity, ordering/cache cleanup, idempotence and refusal to delete folders');
}finally{db.close();}
