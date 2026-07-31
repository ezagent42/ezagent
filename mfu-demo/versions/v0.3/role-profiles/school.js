window.MFU_ROLE_PROFILES ??= {};
window.MFU_ROLE_PROFILES.school = {
  roleId: "school",
  label: "学校课程负责人",
  subtitle: "让跨专业学生通过课余真实任务形成创业能力和学生 MVO",
  brand: "🏫 城南学院 · 学校课程负责人",
  reputationLabel: "课程声望",
  reputation: 316,
  recommendedIndustries: ["教育与校园", "社会创新", "内容与品牌"],
  initial: {
    cash: 12000,
    compute: 180,
    coachHours: 6,
    tasks: [
      {id:"school-campus",icon:"🎓",name:"校园开放日体验设计",client:"招生办公室",reward:"¥3,600",difficulty:"普通",industry:"教育与校园",status:"unassigned",orgId:null,quotedAmount:3600,invoiceStatus:"not_issued",paymentStatus:"not_due",cost:0,income:0},
      {id:"school-lab",icon:"🧪",name:"实验室成果科普计划",client:"材料学院",reward:"¥4,800",difficulty:"进阶",industry:"内容与品牌",status:"unassigned",orgId:null,quotedAmount:4800,invoiceStatus:"not_issued",paymentStatus:"not_due",cost:0,income:0}
    ],
    orgs: [
      {id:"school-cross",icon:"🧩",name:"跨专业实践 MVO",level:3,status:"working",task:"校园无障碍调研",progress:64,eta:"预计 2 天",steps:["观察","共创","验证"],gems:["👩‍🎓","🧑‍🎨","🤖"]},
      {id:"school-media",icon:"🎥",name:"学生内容 MVO",level:2,status:"idle",task:null,progress:0,eta:"",steps:["选题","制作","发布"],gems:["🧑‍🎓","✍️","📱"]},
      {id:"school-data",icon:"📐",name:"课程评价 MVO",level:2,status:"working",task:"实践课程学习证据整理",progress:38,eta:"预计 3 天",steps:["采集","分析","反馈"],gems:["👨‍🏫","🤖","📊"]}
    ],
    people: [
      {id:"school-lin",icon:"👩‍🎓",name:"林晓 · 建筑",ability:66,experience:9,cert:"空间观察认证",portfolio:3,status:"跨专业实践 MVO"},
      {id:"school-he",icon:"🧑‍🎓",name:"阿禾 · 商科",ability:61,experience:7,cert:"判断力认证",portfolio:2,status:"空闲"},
      {id:"school-mia",icon:"🧑‍🎨",name:"米娅 · 视觉",ability:68,experience:10,cert:"设计认证",portfolio:4,status:"跨专业实践 MVO"},
      {id:"school-teacher",icon:"👨‍🏫",name:"周老师 · 创业教练",ability:82,experience:31,cert:"教练资质",portfolio:12,status:"课程评价 MVO"}
    ],
    agents: [
      {id:"school-agent-research",icon:"🤖",name:"课程调研 Agent",ability:5.7,assets:2,status:"跨专业实践 MVO",history:["写守则：引用可核验来源"]},
      {id:"school-agent-feedback",icon:"📝",name:"反馈 Agent",ability:5.3,assets:1,status:"课程评价 MVO",history:["喂范例：形成性评价"]}
    ],
    assets: [
      {id:"school-tool-form",icon:"📝",name:"Form 工具",kind:"工具",meta:"校内许可 · 已安装"},
      {id:"school-ip-rubric",icon:"📏",name:"课程评价量规",kind:"IP",meta:"可复用"},
      {id:"school-data-campus",icon:"🏫",name:"校园场景数据",kind:"IP / 数据",meta:"校内授权"}
    ],
    actions: [],
    logs: ["W18 · 跨专业实践 MVO 正在完成校园观察", "W18 · 课程评价 MVO 收到 8 份学习证据"],
    archive: [],
    chats: {}
  }
};
