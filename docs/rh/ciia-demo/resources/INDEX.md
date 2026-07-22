# CIIA-DIPC 网站爬取结果

**爬取时间**: 2026-07-22
**源站**: https://ciia-dipc.com
**技术栈**: Vue 3.5 (Vite 构建), SPA 客户端渲染
**有效页面数**: 14（已剔除 2 个锚点/外链噪音 + 1 个重复首页）

## 网站结构

```
ciia-dipc.com
├── /                         首页 (Homepage)
├── /about                    关于我们 (About Us)
├── /news                     新闻资讯 (News)
├── /site-monitoring          站点监测 (Site Monitoring)
│   ├── ?parentCode=home&menuCode=home_menu_3         — 要闻聚焦
│   ├── ?parentCode=home&menuCode=home_menu_6         — 通知公告
│   │   ├── &articleId=7                               — 文章: 2024 大赛通知
│   │   └── &articleId=15                              — 文章: 协会简介
│   ├── ?parentCode=home&menuCode=home_1783777566975  — 近期活动预告
│   │   ├── &articleId=6                               — 文章: WAIC 2026 分论坛
│   │   └── &articleId=13                              — 文章: AI智能体×医疗赛道
└── /services/
    ├── /think-tank           智库咨询 (Think Tank)
    ├── /training             人才培养 (Training)
    ├── /assessment           评估服务 (Assessment)
    ├── /expo                 会展活动 (Expo)
    └── /public-package       公共服务 (Public Service Package)
```

## 核心页面

| 路由 | 页面标题 | HTML | TXT | 大小 |
|------|----------|------|-----|------|
| `/` | 首页 | [index.html](index.html) | [index.txt](index.txt) | 143 KB |
| `/about` | 关于我们 | [about.html](about.html) | [about.txt](about.txt) | 146 KB |
| `/news` | 新闻资讯 | [news.html](news.html) | [news.txt](news.txt) | 7 KB |
| `/site-monitoring` | 站点监测 | [site-monitoring.html](site-monitoring.html) | [site-monitoring.txt](site-monitoring.txt) | 7 KB |

## 服务子页面

| 路由 | 页面标题 | HTML | TXT | 大小 |
|------|----------|------|-----|------|
| `/services/think-tank` | 智库咨询 | [services_think-tank.html](services_think-tank.html) | [services_think-tank.txt](services_think-tank.txt) | 19 KB |
| `/services/training` | 人才培养 | [services_training.html](services_training.html) | [services_training.txt](services_training.txt) | 25 KB |
| `/services/assessment` | 评估服务 | [services_assessment.html](services_assessment.html) | [services_assessment.txt](services_assessment.txt) | 14 KB |
| `/services/expo` | 会展活动 | [services_expo.html](services_expo.html) | [services_expo.txt](services_expo.txt) | 28 KB |
| `/services/public-package` | 公共服务 | [services_public-package.html](services_public-package.html) | [services_public-package.txt](services_public-package.txt) | 18 KB |

## 文章详情页（site-monitoring query 参数路由）

| 分类 | articleId | 标题 | HTML | TXT |
|------|-----------|------|------|-----|
| 要闻聚焦 (home_menu_3) | — | 列表页 | [html](site-monitoring_parentCode_home_menuCode_home_menu_3.html) | [txt](site-monitoring_parentCode_home_menuCode_home_menu_3.txt) |
| 通知公告 (home_menu_6) | — | 列表页 | [html](site-monitoring_parentCode_home_menuCode_home_menu_6.html) | [txt](site-monitoring_parentCode_home_menuCode_home_menu_6.txt) |
| 通知公告 | 7 | 2024"数据要素×"大赛通知 | [html](site-monitoring_parentCode_home_menuCode_home_menu_6_articleId_7.html) | [txt](site-monitoring_parentCode_home_menuCode_home_menu_6_articleId_7.txt) |
| 通知公告 | 15 | 协会简介 | [html](site-monitoring_parentCode_home_menuCode_home_menu_6_articleId_15.html) | [txt](site-monitoring_parentCode_home_menuCode_home_menu_6_articleId_15.txt) |
| 近期活动预告 | 6 | WAIC 2026 数据要素×行业智能体分论坛 | [html](site-monitoring_parentCode_home_menuCode_home_1783777566975_articleId_6.html) | [txt](site-monitoring_parentCode_home_menuCode_home_1783777566975_articleId_6.txt) |
| 近期活动预告 | 13 | AI智能体管理能力评估标准落地医疗赛道 | [html](site-monitoring_parentCode_home_menuCode_home_1783777566975_articleId_13.html) | [txt](site-monitoring_parentCode_home_menuCode_home_1783777566975_articleId_13.txt) |

## 路由发现方式

- **静态路由**（从 JS bundle `index-ZtK2PjT_.js` 中提取）: `/`, `/site-monitoring`, `/services/:slug`, `/about`, `/news`
- **动态 slug**（从导航链接中发现）: `think-tank`, `training`, `assessment`, `expo`, `public-package`
- **文章详情**（从 site-monitoring 列表页链接发现）: 通过 `parentCode` + `menuCode` + `articleId` query 参数

## 爬取方法

使用 Playwright 1.61 无头 Chromium 渲染 SPA，等待 `networkidle` + 2s hydration 后捕获 `page.content()` + `body.innerText`，每个页面保存 `.html`（完整 DOM）和 `.txt`（纯文本）。
