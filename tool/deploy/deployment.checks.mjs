import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { request } from 'node:http';
import { packageSimulator } from './package.mjs';
import { verifyPackage } from './verify.mjs';
import { createStagingServer } from './serve.mjs';
function fixture(t) {
 const root=mkdtempSync(join(tmpdir(),'duman-package-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const source=join(root,'dist'),output=join(root,'package');mkdirSync(join(source,'assets'),{recursive:true});
 writeFileSync(join(source,'index.html'),'<h1>Simulator</h1>');writeFileSync(join(source,'assets','app.js'),'console.log("synthetic")');
 return {source,output};
}
test('package verifies exactly its files, refuses overwrite and detects tampering',t=>{
 const {source,output}=fixture(t);packageSimulator(source,output,{sourceSha:'fixture'});assert.equal(verifyPackage(output).manifest.routingProfile,'baseline');
 assert.throws(()=>packageSimulator(source,output,{}),/Output exists/);
 writeFileSync(join(output,'web','assets','app.js'),'changed');assert.throws(()=>verifyPackage(output),/Integrity/);
});
test('rejects secret/source-map/extra files and symlinks instead of packaging them',t=>{
 const {source,output}=fixture(t);writeFileSync(join(source,'.env'),'synthetic-not-a-secret');assert.throws(()=>packageSimulator(source,output,{}),/Unexpected/);
 rmSync(join(source,'.env'));writeFileSync(join(source,'assets','app.js.map'),'{}');assert.throws(()=>packageSimulator(source,output,{}),/Unexpected/);
 rmSync(join(source,'assets','app.js.map'));symlinkSync('app.js',join(source,'assets','link.js'));assert.throws(()=>packageSimulator(source,output,{}),/symlink/);
});
test('rejects unlisted files and malicious manifest paths',t=>{
 const {source,output}=fixture(t);packageSimulator(source,output,{});writeFileSync(join(output,'extra.txt'),'x');assert.throws(()=>verifyPackage(output),/Unlisted/);
 rmSync(join(output,'extra.txt'));writeFileSync(join(output,'manifest.json'),JSON.stringify({schema:1,kind:'duman-simulator-staging',routingProfile:'baseline',files:[{path:'../outside'}]}));assert.throws(()=>verifyPackage(output),/Unsafe/);
});
test('HTTP smoke: security headers, HEAD, missing assets, methods, traversal and immutable bytes',async t=>{
 const {source,output}=fixture(t);packageSimulator(source,output,{});const server=createStagingServer(output);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>server.close(resolve)));
 const port=server.address().port;
 const get=(path,method='GET')=>new Promise((resolve,reject)=>{const req=request({host:'127.0.0.1',port,path,method},res=>{const chunks=[];res.on('data',x=>chunks.push(x));res.on('end',()=>resolve({code:res.statusCode,headers:res.headers,body:Buffer.concat(chunks).toString()}));});req.on('error',reject);req.end();});
 const index=await get('/');assert.equal(index.code,200);assert.match(index.body,/Simulator/);assert.match(index.headers['content-security-policy'],/frame-ancestors 'self'/);assert.equal(index.headers['x-content-type-options'],'nosniff');
 assert.equal((await get('/','HEAD')).body,'');assert.equal((await get('/missing.js')).code,404);assert.equal((await get('/','POST')).code,405);
 for(const path of ['/../package.json','/%2e%2e/package.json','/%ZZ','/%5c..%5c.env','/%00'])assert.equal((await get(path)).code,400);
 assert.equal((await get('/manifest.json')).code,404);assert.equal((await get('/.env')).code,404);
 writeFileSync(join(output,'web','index.html'),'changed');assert.equal((await get('/')).body,index.body);
});
