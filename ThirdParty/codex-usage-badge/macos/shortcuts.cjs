'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {DatabaseSync,backup}=require('node:sqlite');
const bundleId='local.codexusagebadge.launcher';

// Delete only our application item. Existing database triggers maintain page ordering and icon cache.
function removeLaunchpadEntries(db){
  db.exec('BEGIN IMMEDIATE');
  try {
    const rows=db.prepare('SELECT apps.item_id,items.type FROM apps JOIN items ON items.rowid=apps.item_id WHERE bundleid=?').all(bundleId);
    if(rows.some(row=>![4,5].includes(row.type)))throw Error('Unexpected Launchpad item type');
    for(const {item_id} of rows){
      if(db.prepare('SELECT 1 FROM items WHERE parent_id=? LIMIT 1').get(item_id))throw Error('Launcher item contains children');
      db.prepare('DELETE FROM items WHERE rowid=?').run(item_id);
    }
    if(db.prepare('SELECT COUNT(*) AS n FROM apps WHERE bundleid=?').get(bundleId).n)throw Error('Launchpad cleanup was incomplete');
    db.exec('COMMIT');return rows.length;
  }catch(error){db.exec('ROLLBACK');throw error;}
}

async function cleanupLegacyLauncher({home,app,installDir,bridge,command,ownedLauncher,ownedShortcut}){
  const launcher=path.join(home,'Applications/Codex 用量条.app');
  const desktop=path.join(home,'Desktop/Codex 用量条.app');
  const ownsApp=ownedLauncher(),ownsLink=ownedShortcut();
  // Leave files with the same name but a different owner alone.
  if(fs.existsSync(launcher)&&!ownsApp)return {removed:0};
  const dock=JSON.parse(command(bridge,['restore-dock',app,launcher]));
  if(!dock.ok)throw Error('无法恢复原客户端 Dock 图标');
  let changed=!!dock.changed,removed=0;
  if(ownsApp||ownsLink){
    const trash=path.join(home,'.Trash',`CodexUsageBadge-shortcuts-${Date.now()}`);
    fs.mkdirSync(trash,{recursive:true,mode:0o700});
    if(ownsApp){
      try{command('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',['-u',launcher]);}catch{}
    }
    if(ownsLink){fs.renameSync(desktop,path.join(trash,'desktop-shortcut'));removed++;}
    if(ownsApp){fs.renameSync(launcher,path.join(trash,'Codex 用量条.app'));removed++;}
    changed=true;
  }
  try {
    const userDir=command('/usr/bin/getconf',['DARWIN_USER_DIR']).trim();
    const file=path.join(userDir,'com.apple.dock.launchpad/db/db');
    if(fs.existsSync(file)){
      const db=new DatabaseSync(file);
      try {
        const count=db.prepare('SELECT COUNT(*) AS n FROM apps WHERE bundleid=?').get(bundleId).n;
        if(count){
          const dir=path.join(installDir,'backups',`launchpad-${Date.now()}`);
          fs.mkdirSync(dir,{recursive:true,mode:0o700});
          const copy=path.join(dir,'before.db');await backup(db,copy);fs.chmodSync(copy,0o600);
          removed+=removeLaunchpadEntries(db);changed=true;
        }
      }finally{db.close();}
    }
  }finally{
    if(changed)try{command('/usr/bin/killall',['-u',String(process.getuid()),'Dock']);}catch{}
  }
  return {removed};
}
module.exports={cleanupLegacyLauncher,removeLaunchpadEntries};
