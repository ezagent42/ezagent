window.MFU_ROLE_PROFILES ??= {};
window.MFU_ROLE_PROFILES.student = {
  roleId: "student",
  label: "学生创业者",
  subtitle: "正在成长为 OPC",
  brand: "🌱 小满的创业工作台",
  reputationLabel: "个人声望",
  reputation: 86,
  recommendedIndustries: ["教育与校园", "内容与品牌", "社会创新"],
  initial: {
    cash: 1200,
    compute: 48,
    coachHours: 1,
    tasks: [
      {id:"student-copy",icon:"✍️",name:"社团招新文案",client:"校园骑行社",reward:"¥480",difficulty:"入门",industry:"内容与品牌",status:"unassigned",orgId:null,quotedAmount:480,invoiceStatus:"not_issued",paymentStatus:"not_due",cost:0,income:0},
      {id:"student-research",icon:"🔎",name:"旧书摊用户访谈",client:"循环书店 MVO",reward:"¥320",difficulty:"入门",industry:"教育与校园",status:"running",orgId:"student-first",quotedAmount:320,invoiceStatus:"not_issued",paymentStatus:"not_due",cost:40,income:0}
    ],
    orgs: [
      {id:"student-first",icon:"🌱",name:"小满的一人 MVO",level:1,status:"working",task:"旧书摊用户访谈",progress:51,eta:"预计 1 天",steps:["理解","访谈","整理"],gems:["👩‍🎓","🤖","📝"]},
      {id:"student-content",icon:"🪁",name:"校园内容搭档",level:1,status:"idle",task:null,progress:0,eta:"",steps:["选题","制作","检查"],gems:["👩‍🎓","✍️","👀"]}
    ],
    people: [
      {id:"student-self",icon:"👩‍🎓",name:"小满 · 本人",ability:48,experience:3,cert:"判断力认证",portfolio:1,status:"小满的一人 MVO"}
    ],
    agents: [
      {id:"student-agent",icon:"🤖",name:"小角 · 第一个 Agent",ability:3.8,assets:1,status:"小满的一人 MVO",history:["写守则：不清楚时先提问"]}
    ],
    assets: [
      {id:"student-tool-form",icon:"📝",name:"Form 工具",kind:"工具",meta:"新手赠送 · 已安装"},
      {id:"student-ip-example",icon:"🍱",name:"第一份好范例",kind:"IP",meta:"可用于调教 Agent"}
    ],
    actions: [],
    logs: ["W18 · 小角完成第一轮访谈提纲", "W18 · 你被动连接进循环书店订单"],
    archive: [],
    chats: {"student-first":[{who:"上游协作者",text:"访谈对象名单已经放进共享文件。"}]}
  }
};
