# ⏱ ActivityTracker — 活動記録

> 一款基于《秀逗魔導士》主题的 macOS 菜单栏时间追踪工具，自动定时提醒记录当前活动，并提供完整的可视化 Dashboard。

[![Version](https://img.shields.io/badge/version-v1.0.4-c8320a)](https://github.com/Tychebian/Activitytracker/releases)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://github.com/Tychebian/Activitytracker)
[![Python](https://img.shields.io/badge/python-3.10%2B-blue)](https://python.org)

---

## 📸 截图

| 弹窗提醒 | Dashboard 主界面 | 设置页 |
|----------|-----------------|--------|
| ![弹窗](docs/screenshots/popup.png) | ![Dashboard](docs/screenshots/dashboard.png) | ![设置](docs/screenshots/settings.png) |

> *截图目录：`docs/screenshots/`，可替换为实际截图。*

---

## ✨ 功能简介

### 自动定时记录
- 每隔固定时间（默认 **20 分钟**）自动弹出系统对话框，提示记录当前活动
- 选择**一级分类**，弹窗第二步只展示该分类下预定义的**关注主题**（按优先级→频率排序），也可自定义输入
- 同一时间段重复记录时自动覆盖，不产生重复数据；提交后计时器重置

### 按天流水账
- 显示当日所有打卡记录：`开始时间 — 结束时间 · 分类 · 主题`
- 无实际结束时间时按弹窗间隔**自动推算**（斜体灰色标注）
- 同一主题最后一条记录显示**当日累积时长**
- 每条记录下方可直接填写**详情备注**（具体做了什么），失焦自动保存

### 活动时长追踪
- 点击任意记录可编辑：分类、主题、结束时间、详情备注
- 时长数据实时更新到所有统计报表

### 关注主题优先级
- 每个关注主题可标记**高 / 中 / 低**优先级
- **高优先级**每个分类仅限一个，设置新高时自动降级旧主题
- 优先级徽章在按天、按周、按主题视图中实时可见，随时提醒你是否专注在最重要的事情上

### 多视图 Dashboard
- **按天**：纯流水账；**按周**：七天对比；**按月**：热力日历
- **按主题**：独立 Tab，按分类分组展示所有关注主题的累计时长与次数
- 顶部分类汇总卡片，月视图展示总记录数、活跃天数、总时长

### Markdown 导出（AI 分析）
- 设置页「📤 导出」Tab：选择日期范围（快捷：最近 7 天 / 30 天 / 本月）
- 生成结构化 Markdown，含分类汇总表、高优先主题、每日打卡明细（含优先级、详情备注）
- 一键复制，直接粘贴给 ChatGPT / Claude / Gemini 做深度分析

### 手动补录
- 支持为任意过去时间段补录活动，提供开始/结束时间选择器

### 设置管理（⚙ 设置页）
- **计时设置**：自动弹窗开关 + 弹窗间隔（20 / 30 / 60 分钟或自定义）
- **分类与主题**：左栏选分类，右栏管理该分类的关注主题（改名、设优先级、迁移分类）
- **导出**：Markdown 导出

### 系统集成
- 菜单栏常驻图标 ⏱，支持手动唤醒记录弹窗
- 登录后通过 **LaunchAgent** 自动启动，无需手动开启
- 数据存储在本地 SQLite，完全离线，隐私安全

---

## 🖥 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | macOS 12 Monterey 及以上 |
| Python | 3.10+ |
| 包管理 | pip（推荐 Homebrew 或 Anaconda 环境）|

---

## 🚀 安装步骤

### 方式一：DMG 一键安装（推荐）

1. 在 [Releases](https://github.com/Tychebian/Activitytracker/releases) 页面下载最新 `ActivityTracker-vX.X.X.dmg`
2. 双击挂载 DMG
3. 双击运行 **「安装 ActivityTracker.command」**
4. Terminal 自动完成：检测 Python → 安装依赖 → 复制 App → 配置开机自启 → 首次启动
5. 菜单栏右上角出现 **⏱** 图标即安装成功

> **多 Python 环境说明**：若你同时安装了 Homebrew、Anaconda、Miniconda 等多个 Python，安装脚本会自动选定合适的解释器并记录路径，App 启动时直接使用同一环境，无需手动配置。

### 方式二：从源码运行（开发者）

```bash
git clone https://github.com/Tychebian/Activitytracker.git
cd Activitytracker
pip install -r requirements.txt
pip install pyobjc-framework-WebKit
python3 main_app.py
```

---

## 📖 如何使用

### 日常记录

1. 登录 Mac 后，菜单栏右上角出现 **⏱** 图标，表示已在后台运行
2. 按设定间隔（默认 20 分钟）自动弹出对话框 → 选择分类 → 输入或选择备注 → 点击「记录」
3. 点击「跳过」可跳过本次，不影响下一次计时

### 手动唤醒

点击菜单栏 **⏱** 图标 → **记录当前活动 …**，可随时手动触发记录弹窗。提交后计时器重置。

### 查看 Dashboard

点击菜单栏 **⏱** 图标 → **查看 Dashboard**，或直接双击 `ActivityTracker.app`。

### 为记录设置时长

在 Dashboard 任意视图中点击一条活动记录，弹出编辑窗口：
- 左侧显示**开始时间**（不可修改）
- 右侧选择**结束时间**（小时 + 分钟），系统实时显示计算出的时长
- 点击「保存」后时长数据同步到所有统计报表
- 点击「清除结束时间」可撤销时长设置

### 补录历史记录

在 Dashboard 右上角点击 **✚ 补录往期记录**：
1. 选择**日期**
2. 选择**开始时间**（小时 + 分钟），可选填**结束时间**（自动计算时长）
3. 选择分类，填写活动内容
4. 点击「✓ 补录」，自动跳转到该日期

### 设置弹窗间隔

Dashboard → **⚙ 设置** → 顶部「弹窗间隔」→ 下拉选择 20 / 30 / 60 分钟，或选「自定义」后输入任意 5–120 分钟数值。设置立即生效。

### 管理关注主题

Dashboard → **⚙ 设置** → 左侧「关注主题」：
- 输入主题名称（需与活动备注完全匹配），点击「+ 添加」
- 直接在输入框修改名称，失焦后自动保存
- 点击 ✕ 删除主题（历史统计数据不受影响）

设置后，Dashboard 主页「关注的主题 TOP 5」自动按累计时长排名，显示近 7 天选中次数角标。

### 管理活动分类

Dashboard → **⚙ 设置** → 右侧「活动分类」：
- 直接改名（失焦后自动保存到所有历史记录）
- 点击色点更换颜色
- 点击 ✕ 删除（历史记录保留原分类名）

---

## 📁 项目结构

```
activity_tracker/
├── tracker.py          # 菜单栏 App（rumps）+ 可配置计时器
├── main_app.py         # 主入口：启动 Dashboard 窗口 + tracker 子进程
├── dashboard.py        # Flask API 服务（REST 接口 + 页面渲染）
├── db.py               # SQLite 数据库操作（含 end_time 时长字段）
├── config.py           # 分类 & 设置管理（interval / categories）
├── dialog_helper.py    # tkinter 辅助弹窗（备用）
├── templates/
│   └── index.html      # Dashboard 前端（纯 HTML/CSS/JS，无外部依赖）
├── ActivityTracker.app # macOS App Bundle
├── setup.sh            # 一键安装脚本
└── requirements.txt    # Python 依赖
```

---

## 🗄 数据存储

数据库位于 `~/.activity_tracker/activities.db`，包含以下表：

| 表名 | 字段 | 说明 |
|------|------|------|
| `activities` | id, timestamp, end_time, category, note | 活动记录，`end_time` 为可选结束时间 |
| `focus_topics` | id, name, created_at | 用户设定的关注主题列表 |

设置文件：`~/.activity_tracker/config.json`（分类列表 + 弹窗间隔）

日志文件：
- `~/.activity_tracker/error.log` — 运行错误日志
- `~/.activity_tracker/output.log` — 标准输出日志

---

## 🔄 版本历史

| 版本 | 说明 |
|------|------|
| v1.0.4 | 修复补录/编辑弹窗缺少专注主题选择的问题；切换分类时同步刷新建议列表 |
| v1.0.3 | 活动详情备注（行内编辑）；Markdown 一键导出（可粘贴给 AI 分析）；修复双弹窗 bug（PID 文件单例保护） |
| v1.0.2 | 关注主题优先级（高/中/低）；弹窗按分类过滤主题；「按主题」独立 Tab；设置页双 Tab 重构；自动弹窗开关 |
| v1.0.1 | 时长追踪、可配置弹窗间隔、设置页重构、补录时间选择器；修复多 Python 环境安装问题 |
| v1.0.0 | 初始版本：菜单栏弹窗、Dashboard 按天/周/月视图、分类管理 |

---

## 🔧 卸载

```bash
launchctl unload ~/Library/LaunchAgents/com.activitytracker.tracker.plist
rm ~/Library/LaunchAgents/com.activitytracker.tracker.plist
```

---

## 🎨 设计说明

界面配色灵感来自日本动画《秀逗魔導士（スレイヤーズ）》：

| 色值 | 对应元素 |
|------|----------|
| `#c8320a` 深红 | Lina 的火球魔法 |
| `#1a5fa3` 蓝色 | Freeze Arrow |
| `#6b1a8a` 紫色 | Shadow Magic |
| `#c8960a` 金色 | 魔法阵 |
| `#f8f0df` 羊皮纸 | 背景底色 |

---

## 📄 License

MIT License — 自由使用、修改与分发。
