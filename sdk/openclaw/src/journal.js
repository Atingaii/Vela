import {DatabaseSync} from 'node:sqlite';
import {mkdirSync,lstatSync,realpathSync,chmodSync} from 'node:fs';
import {join} from 'node:path';
import {IntegrationError} from './safety.js';

/** Pending claims are durable before any write. Unknown effects are not retried. */
export class CaptureJournal {
  constructor(directory){
    mkdirSync(directory,{recursive:true,mode:0o700});if(lstatSync(directory).isSymbolicLink())throw new IntegrationError('unsafe_state_directory');
    const filename=join(realpathSync(directory),'capture.sqlite');
    try{if(lstatSync(filename).isSymbolicLink()||!lstatSync(filename).isFile())throw new IntegrationError('unsafe_state_file');}catch(error){if(error.code!=='ENOENT')throw error;}
    this.db=new DatabaseSync(filename);chmodSync(filename,0o600);this.db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000; CREATE TABLE IF NOT EXISTS captures(id TEXT PRIMARY KEY, namespace TEXT NOT NULL, bytes INTEGER NOT NULL, state TEXT NOT NULL, receipt TEXT);');
  }
  claim(id,namespace,bytes,limits){
    this.db.exec('BEGIN IMMEDIATE');try{
      const existing=this.db.prepare('SELECT state FROM captures WHERE id=?').get(id);
      if(existing){this.db.exec('COMMIT');return {accepted:false,state:existing.state};}
      const totals=this.db.prepare('SELECT COUNT(*) AS count,COALESCE(SUM(bytes),0) AS bytes FROM captures').get();
      if(totals.count>=limits.maxCaptureOperations||totals.bytes+bytes>limits.maxCaptureBytes)throw new IntegrationError('capture_limit');
      this.db.prepare('INSERT INTO captures(id,namespace,bytes,state) VALUES(?,?,?,?)').run(id,namespace,bytes,'pending');this.db.exec('COMMIT');return {accepted:true};
    }catch(error){this.db.exec('ROLLBACK');throw error;}
  }
  finish(id,state,receipt){this.db.prepare('UPDATE captures SET state=?,receipt=? WHERE id=? AND state=?').run(state,JSON.stringify(receipt),id,'pending');}
  stats(namespace){return this.db.prepare('SELECT state,COUNT(*) AS count,COALESCE(SUM(bytes),0) AS bytes FROM captures WHERE namespace=? GROUP BY state ORDER BY state').all(namespace);}
  totals(){return this.db.prepare('SELECT COUNT(*) AS operations,COALESCE(SUM(bytes),0) AS bytes FROM captures').get();}
  close(){this.db.close();}
}
