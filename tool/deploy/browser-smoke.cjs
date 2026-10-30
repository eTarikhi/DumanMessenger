// Optional real-browser smoke; dependencies installed only in ignored tool/.build.
// Loopback-only target and request interception: no external sites or real data.
const assert=require('node:assert/strict');
const {createRequire}=require('node:module'),{resolve}=require('node:path');
const tools=createRequire(resolve('tool/.build/browser-check/package.json'));
const chromium=tools('@sparticuz/chromium').default,puppeteer=tools('puppeteer-core');
const {MeshSimulation,DEFAULT_CONFIG}=require('../.build/src/simulation.js');
(async()=>{let browser;const errors=[],requests=[];try{
 browser=await puppeteer.launch({args:chromium.args,executablePath:await chromium.executablePath(),headless:true});
 const page=await browser.newPage();await page.setViewport({width:1440,height:1000});
 page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
 await page.setRequestInterception(true);page.on('request',r=>{requests.push(r.url());if(!r.url().startsWith('http://127.0.0.1:4173/')&&!r.url().startsWith('data:')){errors.push('Unexpected request '+r.url());r.abort();}else r.continue();});
 const click=async text=>{const h=await page.evaluateHandle(t=>[...document.querySelectorAll('button')].find(b=>b.textContent.trim()===t),text);const b=h.asElement();assert(b,'Missing button '+text);assert.equal(await b.evaluate(x=>x.disabled),false,text+' disabled');await b.click();await h.dispose();};
 const card=label=>page.evaluate(t=>[...document.querySelectorAll('div')].find(d=>!d.children.length&&d.textContent===t)?.previousElementSibling?.textContent,label);
 await page.goto('http://127.0.0.1:4173/',{waitUntil:'networkidle0'});
 assert.match(await page.$eval('body',x=>x.innerText),/Simulation only — synthetic data/);
 assert(await page.$eval('canvas',c=>c.width>0&&c.height>0&&c.getContext('2d').getImageData(0,0,c.width,c.height).data.some(v=>v!==0)));
 const initial=await card('Sim clock');await click('⏭ Step');await click('⏭ Step');assert.notEqual(await card('Sim clock'),initial);
 const beforeRun=await card('Sim clock');await click('▶ Run');await page.waitForFunction(()=>[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='⏸ Pause'));await new Promise(r=>setTimeout(r,1100));await click('⏸ Pause');const paused=await card('Sim clock');assert.notEqual(paused,beforeRun);await new Promise(r=>setTimeout(r,1100));assert.equal(await card('Sim clock'),paused);
 await page.focus('input[aria-label="Seed"]');await page.keyboard.press('ArrowRight');await click('Apply & rebuild world');
 const seed=await page.$eval('input[aria-label="Seed"]',x=>Number(x.value));assert.equal(seed,43);
 // Use only the deterministic public model for click coordinates, not browser internals.
 const sim=new MeshSimulation({...DEFAULT_CONFIG,seed});const node=sim.nodes[0];
 await page.$eval('canvas',c=>c.scrollIntoView({block:'center'}));const box=await (await page.$('canvas')).boundingBox();
 await page.mouse.click(box.x+1+node.pos.x*Math.max(1,640/Math.max(sim.config.areaWidth,sim.config.areaHeight)),box.y+1+node.pos.y*Math.max(1,640/Math.max(sim.config.areaWidth,sim.config.areaHeight)));
 await page.waitForSelector('button[aria-label="Close inspector"]');await click('New group with 4 nearest peers');
 const groupState=()=>page.evaluate(()=>{const s=[...document.querySelectorAll('span')].find(s=>/\/10 · epoch/.test(s.textContent));return s?.textContent.match(/(\d+)\/10 · epoch (\d+)/)?.slice(1).map(Number);});
 const created=await groupState();assert.equal(created[0],5);await click('Rotate key');assert.deepEqual(await groupState(),[created[0],created[1]+1]);
 await click('Invite nearest');assert.deepEqual(await groupState(),[created[0]+1,created[1]+2]);
 const options=await page.$$eval('select option',xs=>xs.map(x=>x.value));assert(options.some(x=>x.startsWith('grp-')));
 const selects=await page.$$('select');await selects[1].select('node-1');
 await page.type('input[aria-label="Message body"]','synthetic browser smoke only');await click('Send');
 await page.waitForFunction(()=>document.body.innerText.includes('synthetic browser smoke only'));
 for(let i=0;i<12;i++)await click('⏭ Step');
 const trace=await page.$('button[aria-label^="Trace "]');assert(trace,'Delivered trace control');await trace.click();await page.waitForSelector('button[aria-label="Clear hop trace"]');
 await page.focus('input[aria-label="File size in megabytes"]');await page.keyboard.press('Home');await click('Send file');await page.waitForSelector('[data-testid^="transfer-"]');
 const transfersBefore=await page.$$eval('[data-testid^="transfer-"]',xs=>xs.length);await click('PTT · stream');
 const transfersAfter=await page.$$eval('[data-testid^="transfer-"]',xs=>xs.length);assert(transfersAfter>transfersBefore);
 await click('↺ Reset');assert.equal(await page.$('button[aria-label="Close inspector"]'),null);assert.equal(await page.$('[data-testid^="transfer-"]'),null);assert.equal(await page.$('button[aria-label="Clear hop trace"]'),null);
 assert.deepEqual(errors,[]);
 console.log(JSON.stringify({browser:await browser.version(),scope:'real headless-browser automated DOM/canvas clicks, synthetic simulation only',passed:['warning','canvas paint','step','run/pause','seed apply','canvas node selection','group create/rotate/invite','synthetic send and delivered hop trace','file and streamed-voice simulated transfer rows','reset cleanup','same-origin requests only','no page/console errors'],requests},null,2));
}finally{if(browser)await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
