# ActivityTracker — Claude 开发总纲

## 项目结构

- **唯一工作目录**：`swift_app/`，根目录的 Python 文件已废弃
- **构建命令**：`bash build.sh`（在 `swift_app/` 下执行）
- **前端入口**：`templates/index.html`（单文件，HTML + CSS + JS 共 ~3000 行）
- **后端路由**：`Sources/SchemeHandler.swift` → `Sources/APIHandlers.swift` → `Sources/Database.swift`

## 架构关键约束

### WKWebView 请求体
WKWebView 会剥离 `fetch()` 的 `httpBody`。前端已通过 `SchemeHandler.fetchPatchScript` 将 body 转移到 `X-Body-Payload` 请求头（percent-encoded）。**不要绕过或重写这个机制。**

### 全局懒加载状态
以下变量**不随页面加载初始化**，只在特定 tab 被访问时才填充：

| 变量 | 何时填充 |
|------|---------|
| `_allCats` | 进入「⚙ 设置」或「按任务」tab |
| `_allTopics` | 同上 |
| `_tvAllTasks` | 进入「按任务」tab |

在日 / 周 / 月视图下，上述变量默认为空数组。

---

## 核心开发准则

### 准则 A：下拉框弹窗必须在打开瞬间确保数据就绪

> **任何包含下拉选择框的弹窗组件，必须在打开的瞬间主动加载所依赖的数据，绝不能假设数据已经存在。**

**已踩坑的案例**：
- `openAddTask()`：打开时 `_allCats` 为空 → 分类下拉框无内容
- `openEditTask()`：同上

**标准修复模式**（所有含下拉框的 `open*` 函数均须采用）：

```js
async function openXxxModal(...) {
  // 第一步：确保依赖数据已加载
  if (!_allCats.length || !_allTopics.length) {
    [_allCats, _allTopics] = await Promise.all([
      api('/api/categories'),
      api('/api/focus_topics')
    ]);
  }
  // 第二步：再填充 DOM
  ...
}
```

---

### 准则 B：新 UI 交互的前置检查清单（Prompt Interaction）

**当我提出涉及新 UI 交互的需求时，在输出代码前必须完成以下三步：**

1. **列出依赖的全局状态变量**  
   明确该功能读取哪些全局变量（`_allCats`、`_allTopics`、`_tvAllTasks`、`CATS`、`COLORS` 等）。

2. **确认初始化路径**  
   分析用户到达该交互时所经过的视图路径（日视图 / 周视图 / 月视图 / 任务视图 / 设置视图），逐一确认每个依赖变量在该路径下是否已被填充。

3. **若存在未初始化风险，优先提供异步等待方案**  
   不得依赖"用户应该先访问过某个 tab"的隐式假设，必须在函数内部显式 `await` 加载。

---

### 准则 C：视图切换时的渲染完整性

每个视图的渲染函数（`renderDay` / `renderWeek` / `renderMonth`）中，所有 early return 分支都必须执行与正常分支相同的副作用（如渲染任务面板）。

**已踩坑的案例**：
- `renderDay()` 在"当日无记录"时 early return，跳过了 `renderTaskPanel()` 调用 → 任务面板不显示

**检查规则**：函数中每条 `return` 之前，确认是否遗漏了应当始终执行的 DOM 更新操作。

---

### 准则 E：乐观更新（Optimistic Update）

> **任何涉及"缓存"与"网络请求"的保存逻辑，必须先更新本地缓存，再发起请求，绝不能等请求完成后才更新缓存。**

**已踩坑的案例**：
- `saveDetail()` 在 `await fetch(PATCH)` 之后才更新 `_dayActMap[id].detail`。用户点击 ✎ 时，blur 触发 saveDetail 发起 PATCH，但 openEdit 同步执行读缓存，读到旧值（null）。结果编辑弹窗备注字段为空，保存时以 `detail: null` 覆盖数据库。

**标准模式**：

```js
async function saveXxx(input) {
  const newValue = input.value.trim() || null;

  // ✅ 第一步：先更新本地缓存，让后续同步读缓存的代码立即拿到正确状态
  if (cache[id]) cache[id].field = newValue;

  // ✅ 第二步：再发起网络请求
  await fetch('/api/...', { method: 'PATCH', body: JSON.stringify({ field: newValue }) });
}
```

**判断规则**：只要存在"A 写缓存 → B 读缓存"的依赖，且 A 和 B 之间有任何异步间隙（`await`、事件队列、onblur/onclick 竞争），就必须乐观更新。

---

### 准则 D：`deleteTaskItem` 刷新回调

面板级删除（日/周/月任务面板）使用第 6 个参数 `onRefresh` 回调，不传 `containerEl` / `scope` / `scopeDate`：

```js
deleteTaskItem(tid, null, null, null, false, () => renderTaskPanel(el, viewScope, curDate));
```

任务视图（`renderTasksView`）删除传 `fromTasksView=true`。

---

### 准则 F：后端改动必须同回合完成前端同步

> **任何后端变更（新路由、新字段、行为修改）都必须在同一次回答里完成前端的对应修改，不得留到下一轮。**

每次改后端后，在提交代码前自检以下四项：

| 检查项 | 问题 |
|-------|------|
| **新路由** | 前端有没有对应 `fetch()`？URL、method、body 字段名三项都对吗？ |
| **新字段** | 前端的读路径（渲染）和写路径（保存）都传了这个字段吗？ |
| **权限门卫** | 后端现在允许某操作，前端有没有 `readonly` / `if(!past)` / `disabled` 还在挡着？ |
| **多入口** | 同一功能有几个 UI 入口（日视图 / 设置归档 / 弹窗）？每个入口都同步了吗？ |

**已踩坑的典型案例**：
- 新增 `quote` 字段 + `/api/period_goals/quote` 路由 → `renderGoalsPanel()` 里 `readonly` 和 `if(!past)` 没去掉，日视图历史日期无法补记
- 归档设置 tab 改成可编辑 → 日视图的 `renderGoalsPanel()` 用同一个 `past` 判断，没同步去掉 readonly，导致两套 UI 行为不一致
