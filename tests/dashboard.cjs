// Playwrightによる画面の補助検証。実VM・ネイティブWebKitの確認はdashboard_smoke.pyで行う。
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require('playwright');
const root = path.dirname(__dirname);
const output = path.join(root, 'test-results', 'dashboard-browser');
fs.mkdirSync(output, { recursive: true });
const fixture = {
  session: 'fixture-session', phase: '公開中', active: true, canStart: false,
  url: 'https://honeyobs-test.example', detail: '画面検証用データ', total: 5,
  geoAvailable: true, geoEdition: 'DB-IP Lite 2026-10',
  events: [
    ['5','DE','ドイツ','192.0.2.17','GET','/wp-admin',404],
    ['4','US','アメリカ','198.51.100.24','POST','/login',401],
    ['3','AU','オーストラリア','203.0.113.8','GET','/.env',404],
    ['2','FR','フランス','192.0.2.45','GET','/robots.txt',404],
    ['1','JP','日本','203.0.113.19','GET','/',404]
  ].map(([id,countryCode,country,ip,method,request,status])=>({id,countryCode,country,ip,method,path:request,status,time:'2026-10-15T05:32:08Z',test:false}))
};
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  try {
    const page=await browser.newPage({viewport:{width:1024,height:970},colorScheme:'dark'});
    const errors=[],external=[];
    page.on('pageerror',e=>errors.push(e.message));
    page.on('request',r=>{if(/^https?:/.test(r.url()))external.push(r.url())});
    await page.addInitScript(()=>{window.actions=[];window.webkit={messageHandlers:{honeyobs:{postMessage:message=>window.actions.push(message.action)}}}});
    await page.goto('file://'+path.join(root,'Resources/Dashboard/index.html'));
    await page.evaluate(s=>window.honeyobs.update(s),{...fixture,active:false,canStart:true,phase:'停止中',url:'',total:0,events:[]});
    await page.getByRole('button',{name:'一時公開を開始',exact:true}).click();
    assert((await page.evaluate(()=>window.actions)).includes('start-public'));
    await page.evaluate(s=>window.honeyobs.update(s),fixture);
    await page.screenshot({path:path.join(output,'populated.png')});
    await page.locator('.event').nth(1).click();
    assert.equal(await page.locator('#country').textContent(),'アメリカ');
    assert.equal(await page.locator('#request').textContent(),'POST /login');
    assert.equal(await page.locator('.route').getAttribute('data-selected'),'4');
    assert.equal(await page.locator('.home').getAttribute('cx'),'400');
    // 非選択の新着で、利用者が見ている詳細を奪わない。
    const next={...fixture,total:6,events:[{...fixture.events[0],id:'6'},...fixture.events]};
    await page.evaluate(s=>window.honeyobs.update(s),next);
    assert.equal(await page.locator('#request').textContent(),'POST /login');
    // 信頼しないHTTP文字列をDOMへ入れても、コード・タグとして解釈しない。
    const malicious='</script><img src=x onerror="window.injected=true">';
    const unknown={...fixture.events[0],id:'7',countryCode:'',country:'位置不明',ip:'',path:malicious,test:true};
    await page.evaluate(s=>window.honeyobs.update(s),{...next,total:7,events:[unknown,...next.events]});
    await page.locator('.event').first().click();
    assert.equal(await page.locator('#request').textContent(),'GET '+malicious);
    assert.equal(await page.locator('img').count(),0);
    assert.equal(await page.evaluate(()=>window.injected),undefined);
    assert.equal(await page.locator('.route').count(),0);
    assert.equal(await page.locator('.test').first().textContent(),'確認用');
    await page.getByRole('button',{name:'停止',exact:true}).click();
    assert((await page.evaluate(()=>window.actions)).includes('stop'));
    await page.evaluate(s=>window.honeyobs.update(s),{...fixture,active:false,canStart:true,phase:'停止中'});
    assert.equal(await page.locator('#url').textContent(),'公開URLなし');
    assert.equal(await page.locator('.packet').count(),0);
    assert.equal(await page.locator('.event').count(),5);
    // 停止要求や停止失敗を、終了確認済みとして表示しない。
    for (const phase of ['停止処理中','停止失敗']) {
      await page.evaluate(s=>window.honeyobs.update(s),{...fixture,active:false,canStart:false,shutdownComplete:false,phase,detail:'終了確認を待っています'});
      assert.equal(await page.locator('#phase').textContent(),phase);
      assert.equal(await page.locator('#vm-status').textContent(),'内蔵VM：停止未確認');
      assert.equal(await page.locator('#toggle').isDisabled(),true);
      await page.screenshot({path:path.join(output,phase==='停止失敗'?'stop-failed.png':'stopping.png')});
    }
    await page.evaluate(s=>window.honeyobs.update(s),{...fixture,active:false,canStart:true,shutdownComplete:true,phase:'停止完了'});
    assert.equal(await page.locator('#vm-status').textContent(),'内蔵VM：停止確認済み');
    await page.evaluate(s=>window.honeyobs.update(s),{...fixture,session:'new-session',events:[],total:0});
    assert.equal(await page.locator('.event').count(),0);
    assert.equal(await page.locator('#request').textContent(),'—');
    // 保持上限でのスクロール・小さいウィンドウ・長いパス。
    const many=Array.from({length:128},(_,i)=>({...fixture.events[i%5],id:String(128-i),path:'/'+ 'x'.repeat(512)}));
    await page.evaluate(s=>window.honeyobs.update(s),{...fixture,session:'large-session',events:many,total:128});
    await page.setViewportSize({width:860,height:650});
    await page.locator('.event').last().click();
    assert.equal(await page.locator('.event[aria-pressed=true]').getAttribute('data-id'),'1');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    await page.screenshot({path:path.join(output,'compact.png')});
    assert.deepEqual(external,[]);assert.deepEqual(errors,[]);
    console.log('画面・選択維持・未知位置・HTML文字列・128件・通信なし: PASS');
  } finally {await browser.close()}
})().catch(error=>{console.error(error);process.exit(1)});
