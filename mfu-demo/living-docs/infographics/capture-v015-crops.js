const {chromium}=require('/Users/chenruihua/.nvm/versions/node/v20.19.6/lib/node_modules/playwright');
const path=require('path');

const demo='file:///Users/chenruihua/Documents/Vaults/projects/ezagent-pr-1543/mfu-demo/versions/v0.15/demo/MFU-v0.15-%E5%8F%AF%E8%AF%95%E7%8E%A9%E5%8E%9F%E5%9E%8B.html';
const out=path.resolve(__dirname,'assets/demo-v0.15-crops');

async function snap(locator,name){
  await locator.waitFor({state:'visible'});
  await new Promise(resolve=>setTimeout(resolve,350));
  await locator.screenshot({path:path.join(out,name+'.png')});
}
async function fresh(browser){
  const page=await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:1});
  await page.goto(demo);
  await page.locator('#startBtn').click();
  return page;
}
async function routePage(browser){
  const page=await fresh(browser);
  await page.evaluate(()=>{setTab('orders');openRoleFlow('match',S.orders[0].id)});
  await page.locator('#mRoleFlow .btn-green').click();
  return page;
}

(async()=>{
  const browser=await chromium.launch({headless:true});

  let page=await fresh(browser);
  await page.evaluate(()=>openPost());
  await snap(page.locator('#mPost .modal'),'action-understand-demand');
  await snap(page.locator('#mPost .crew-pick'),'action-confirm-scope');
  await page.close();

  page=await routePage(browser);
  await snap(page.locator('#mRoute .modal'),'feature-routing');
  await snap(page.locator('#rtStages'),'action-route-task');
  await snap(page.locator('#rtStages .route-stage').first(),'action-choose-solution');
  await snap(page.locator('#rtStages .route-stage').nth(1),'action-arrange-member');
  await snap(page.locator('#rtStages .route-stage').nth(2),'action-arrange-agent');
  await page.close();

  page=await fresh(browser);
  await page.evaluate(()=>{setTab('orders');openRoleFlow('match',S.orders[0].id)});
  await snap(page.locator('#mRoleFlow .modal'),'feature-matching');
  await page.close();

  page=await routePage(browser);
  await page.evaluate(()=>{
    for(let i=0;i<routeSel.length;i++)pickRoute(i,0);
    document.querySelector('#rtGo').click();
    const p=S.projects[0];openRoleFlow('hunter',p.id);
  });
  await snap(page.locator('#mRoleFlow .modal'),'feature-hunter-workbench');
  await page.locator('#mRoleFlow .btn-green').click();
  await snap(page.locator('#mRoleFlow .modal'),'action-outsource');
  await page.evaluate(()=>{
    const p=S.projects[0];
    p.stages.forEach((st,i)=>{st.rem=0;st.q=72+i*3});p.ready=true;render();openDeliver(p.id);
  });
  await snap(page.locator('#mDeliver .modal'),'feature-delivery');
  await snap(page.locator('#dvDetail'),'action-check-quality');
  await page.evaluate(()=>{const p=S.projects[0];finishContest(p,78)});
  await snap(page.locator('#mDeliver .modal'),'action-real-feedback');
  await page.evaluate(()=>{closeM('mDeliver');openRoleFlow('network')});
  await snap(page.locator('#mRoleFlow .modal'),'feature-form-organization');
  await page.close();

  page=await fresh(browser);
  await page.evaluate(()=>{openPost();document.querySelector('#poGo').click()});
  await snap(page.locator('#mRoleFlow .modal'),'feature-decompose');
  await page.evaluate(()=>{
    closeM('mRoleFlow');
    const o=S.myOrders[0];o.decomposed=true;o.subs=[
      {co:'纸飞机工作室',q:82},{co:'长尾巴内容社',q:76},{co:'北辰项目组',q:71}
    ];openRoleFlow('reviewMy',o.id);
  });
  await snap(page.locator('#mRoleFlow .rf-card').nth(1),'action-accept-review');
  await page.evaluate(()=>{const o=S.myOrders[0];o.initialReviewed=true;closeM('mRoleFlow');judgeMy(o.id)});
  await snap(page.locator('#mDeliver .modal'),'feature-evaluation');
  await page.close();

  page=await fresh(browser);
  await page.evaluate(()=>openBiz('ov'));
  await snap(page.locator('#mBiz .modal'),'feature-organization-profile');
  await page.evaluate(()=>openBiz('ast'));
  await snap(page.locator('#mBiz .modal'),'feature-company-brain');
  await page.evaluate(()=>openBiz('me'));
  await snap(page.locator('#mBiz .modal'),'feature-certification');
  await page.evaluate(()=>{closeM('mBiz');openRoleFlow('incubator')});
  await snap(page.locator('#mRoleFlow .modal'),'feature-incubator');
  await page.evaluate(()=>{closeM('mRoleFlow');setTab('eco')});
  await snap(page.locator('#tab-eco'),'feature-opportunities');
  await page.close();

  page=await fresh(browser);
  await page.evaluate(()=>{
    S.reviews.push({name:'旧书店增长计划',domain:'growth',kind:'落选'});
    S.profile.judgeT=5;S.profile.judgeG=3;render();setTab('market');
  });
  await snap(page.locator('#tab-market'),'action-find-reason');
  await page.evaluate(()=>openBiz('log'));
  await snap(page.locator('#mBiz .modal'),'action-change-method');
  await page.evaluate(()=>openBiz('tree'));
  await snap(page.locator('#mBiz .modal'),'action-verify-again');
  await page.close();

  await browser.close();
})().catch(error=>{console.error(error);process.exit(1)});
