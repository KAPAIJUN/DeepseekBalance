# deepseek用量监控组件

> deepseek用量监控组件：一个轻量、低占用的 **macOS 菜单栏小部件**，让你随时掌握 DeepSeek 余额与 Codex Token 消耗。
> 无需 Dock 图标，只在菜单栏安静陪伴 👀，余额不足还会提醒你充值 💡。

---

## 📖 基础说明

deepseek用量监控组件是一款为 **Codex + DeepSeek** 用户打造的菜单栏工具：

- 🎯 菜单栏实时显示 **DeepSeek 余额**（默认 `¥12.34`，低余额附加 `⚠️`）
- ⚡ Codex 正在跑任务时显示 ⚡ 标记，并**每 5 秒实时刷新**
- 📊 内置 **Tokens 消耗柱状图** 与 **项目详情**，一眼看懂钱花在哪
- 💰 可接入 **DeepSeek 官网记录**，人民币消耗与官网**完全一致**
- 🔔 余额低于 ¥1 自动发系统通知，提醒及时充值

数据全部保存在本机，**不收集、不上传任何隐私**。

### ✅ 环境要求
- **macOS 14+**
- **仅 Apple Silicon（arm64）**
- 仅需 **Xcode 命令行工具**（无需完整 Xcode）

---

## ✨ 详细特点

### 🖥️ 菜单栏 & 弹窗
- 💰 菜单栏显示 `¥余额`（**默认不带 🐋**，更紧凑不易被挤掉；右键菜单勾选「菜单栏显示 🐋」可开启）
- 低余额附加 `⚠️`，Codex 活跃附加 `⚡`
- 🪟 点击菜单栏打开弹窗：余额大字 + API Key 状态 + 总充值金额 + 消耗 tokens + 官网记录状态
- 🖱️ 右键菜单：刷新、刷新间隔、图表/项目详情、开机自启、设置/清除 Key、退出等

### ⚡ 智能实时刷新
- ⏱️ Codex 活跃时（会话文件 30 秒内有写入）**每 5 秒**刷新余额
- 😴 空闲时按设定间隔刷新（1 / 5 / 15 分钟可切换）
- 🔋 低占用：流式解析、不整文件载入（内存占用随单行大小变化，通常仅几百 KB）
- 🛡️ 单实例保护：重复启动会自动提示退出

### 📊 Tokens 消耗柱状图
- 📅 股票式周期筛选：今日 / 7天 / 30天 / 3月 / 6月 / 1年 / 全部
- 🖱️ 鼠标悬停查看该时段**各项目消耗明细**（中文项目名）
- 🔴 充值事件用红色竖线标记，鼠标悬停可见金额
- 🗂️ 统计范围包含 `sessions/` 与 `archived_sessions/`（归档会话不丢）

### 💰 人民币消耗（官网记录）
- 🔗 接入 DeepSeek 官网 `usage/cost` + `usage/amount` 接口，按日显示**官方消耗**，与官网一致
- ⏳ 图表打开时每 60 秒自动同步最新记录
- 📉 未接入或同步失败时自动回退「余额下降估算」，并显示红色错误提示
- 🔑 Token 接入时自动校验有效性，无效会提示重新接入

### 📁 项目详情
- 🏷️ 按项目聚合：中文标题、开始时间（以会话文件内 UTC 时间戳为准，更准确）、最后活跃、会话数
- ⏲️ 真实运行耗时（连续事件累加）+ 项目创建至今时长
- 📈 每个项目的 Tokens 消耗横向条形图

### 🔔 低余额提醒
- 💸 余额低于 ¥1 自动发送一次系统通知，回升后复位可再次提醒

### 🛠️ 开机自启 & 配置
- 🚀 右键菜单一键勾选「开机自启」（SMAppService）
- 🔑 弹窗内直接设置 / 清除 API Key、接入 / 清除官网记录，无需手动改文件

---

## 🚀 部署安装（详细教程）

> 仅需 macOS 命令行工具，**不需要安装 Xcode**。

### 方式一：直接下载安装包（推荐给普通用户）📦
1. 到 **[Releases 页面](https://github.com/KAPAIJUN/deepseek-usage-monitor/releases/latest)** 下载 `DeepSeekBalance.app.zip`
2. 解压后把 `deepseek用量监控组件.app` 拖到 `访达 → 应用程序`
3. 双击运行（无 Dock 图标，菜单栏会出现余额）
4. 首次运行会请求「通知权限」，点击允许
5. 点击菜单栏图标 → 弹窗「API Key → 设置…」粘贴你的 DeepSeek API Key

> ⚠️ 若提示“无法打开，因为无法验证开发者”，右键应用 → 打开 → 再次打开即可（个人开发者的正常提示，本安装包为 ad-hoc 签名）。

### 方式二：从源码打包（推荐给开发者）🛠️
```bash
# 1️⃣ 克隆仓库
git clone https://github.com/KAPAIJUN/deepseek-usage-monitor.git
cd deepseek-usage-monitor

# 2️⃣ 一键打包（编译 + 生成图标 + 组装 .app + 签名）
./build.sh

# 3️⃣ 生成安装包 .zip
./build.sh package

# 4️⃣ 打包并安装到 /Applications 并启动
./build.sh install
```

### 方式三：手动编译（了解原理）⌨️
```bash
# 1) 编译二进制
xcrun swiftc -parse-as-library -O -warn-concurrency -o DeepSeekBalance DeepSeekBalance.swift \
  -framework SwiftUI -framework AppKit -framework UserNotifications -framework Charts

# 2) 组装 .app（目录结构与 Info.plist 见仓库 build.sh，或直接使用 ./build.sh）
mkdir -p DeepSeekBalance.app/Contents/MacOS DeepSeekBalance.app/Contents/Resources
cp DeepSeekBalance DeepSeekBalance.app/Contents/MacOS/
cp assets/*.png DeepSeekBalance.app/Contents/Resources/
# 需手动补充 Contents/Info.plist（CFBundleIdentifier / LSUIElement 等，参考 build.sh）

# 3) 签名
codesign --force -s - DeepSeekBalance.app
```

---

## ⚙️ 配置指南

### 🔑 1. 配置 API Key（必需）
余额接口需要 DeepSeek API Key，按优先级读取：
1. **弹窗内设置**：点击菜单栏 →「API Key → 设置…」粘贴（推荐）
2. 环境变量：`export DEEPSEEK_API_KEY=sk-xxx`
3. 兼容旧版 CodexBar 配置

> API Key 申请地址：https://platform.deepseek.com/api_keys
> 彻底删除：右键菜单 →「清除 API Key…」

### 🔗 2. 接入官网记录（可选，强烈推荐）
让人民币消耗与官网完全一致：
1. 浏览器登录 https://platform.deepseek.com
2. 按 `F12` → Console，输入并回车：
   ```js
   localStorage.getItem('userToken')
   ```
3. 复制返回的字符串
4. 点击菜单栏 → 弹窗「官网记录 → 接入…」→「读取剪贴板」→ 保存
5. 应用会自动校验 Token 有效性

> 彻底删除：右键菜单 →「清除官网记录…」

### 💰 3. 设置初始充值金额（可选）
右键菜单 →「设置初始充值金额…」，输入你已充值的总金额（元），用于累计充值统计（会自动重置基线，避免重复累计）。

---

## ⚠️ 已知限制
- 🔗 **官网接口为未公开内部接口**，DeepSeek 可能随时调整，导致官网记录失效（届时会回退为余额估算并提示）
- 📊 **消耗 tokens 口径与官网计费不等价**：本地按会话 `total_token_usage` 统计，与官网账单口径不同
- 💰 **充值 / 余额为本地估算**：基于余额变化记录，仅用于辅助参考
- 🍎 **仅 Apple Silicon（arm64）**，Intel Mac 暂不支持
- 🌏 **非中国时区按北京时间对齐**：人民币"按日"分桶使用北京时区，与官网一致

---

## 🔒 安全提示
- 🎫 `userToken` 是**网页会话凭证**（相当于登录态），泄露可导致账号被他人使用
- 📡 仅发送到 DeepSeek **官方域名**（`platform.deepseek.com` / `api.deepseek.com`），**绝不上传其他服务器**
- 💾 仅保存在本机 `config.json`（权限 `0600`）
- 🚫 请勿在共享 / 公用电脑上使用本组件
- 🔄 建议定期在官网「安全设置」中更新/重置 Token
- 🧹 不再使用时，右键菜单 →「清除官网记录…」即可彻底删除本机 Token

---

## 📁 数据与隐私
- 数据全部保存在本机：`~/Library/Application Support/DeepSeekBalance/`
  - `config.json` ｜ API Key / 官网 Token / 刷新间隔 / 🐋 开关（权限 600）
  - `state.json` ｜ 最近一次刷新状态
  - `balance_history.json` ｜ 余额读数历史
  - `platform_usage.json` ｜ 官网每日消耗缓存
  - `recharge.json` ｜ 充值记录
- 🚫 本项目**不收集、不上传**任何用户数据
- 🌏 官网每日消耗按北京时间对齐，与 DeepSeek 官网一致
- 📂 Codex 数据目录优先读取 `CODEX_HOME`，默认 `~/.codex`；统计范围含 `sessions/` 与 `archived_sessions/`

---

## 🧱 技术栈 & 项目结构
```
deepseek-usage-monitor/
├── DeepSeekBalance.swift   # 全部源码（SwiftUI + AppKit 菜单栏 + Charts）
├── build.sh                # 一键打包（编译 / 图标 / 签名 / 安装包）
├── assets/                 # 图标与立绘资源
├── tests/parse_tests.swift # 无 GUI 依赖的解析单测（swift 直接运行）
├── .github/workflows/ci.yml# CI：编译检查 + 单测 + 打包验证
└── README.md
```
技术栈：Swift 6 / SwiftUI / AppKit / Swift Charts / Foundation，无第三方依赖，纯标准库。

---

## 🧪 开发 & 测试
```bash
# 编译检查（含并发告警）
xcrun swiftc -parse-as-library -O -warn-concurrency -o /tmp/dsb DeepSeekBalance.swift \
  -framework SwiftUI -framework AppKit -framework UserNotifications -framework Charts

# 运行解析单测（无 GUI 依赖）
swift tests/parse_tests.swift

# 打包验证
./build.sh package
```

---

## ❓ 常见问题（FAQ）

**Q：菜单栏没有显示余额？**
A：到「应用程序」找到 `deepseek用量监控组件` 双击运行；首次可能需要在 系统设置 → 隐私与安全性 允许。

**Q：菜单栏图标被其他应用挤掉？**
A：应用在 **Codex 快速消耗（活跃）模式下会自动强制显示**（检测到被隐藏会重建图标）。此外可把菜单栏文字保持紧凑（默认无 🐋），或用 ⌘ 拖动其他图标腾出空间；也可以到 系统设置 → 控制中心 → 菜单栏 → 找到本应用 → 改为「始终显示」。

**Q：显示「未配置 API Key」？**
A：点击菜单栏 → 弹窗「API Key → 设置…」粘贴你的 Key。

**Q：人民币柱状图和官网对不上？**
A：确认已接入官网记录（弹窗「官网记录」显示「已接入 ✓」），并点击图表右上角「刷新」。若显示红色错误提示，说明官网接口暂时不可用，已回退为估算。

**Q：消耗 tokens 不更新？**
A：组件扫描 `~/.codex/sessions/` 与 `~/.codex/archived_sessions/` 下的 `rollout-*.jsonl` 会话文件；如果你自定义了 Codex 目录，请设置 `CODEX_HOME` 环境变量。

**Q：如何彻底删除 Key / Token？**
A：右键菜单 →「清除 API Key…」/「清除官网记录…」，删除的是本机 `config.json` 中的对应字段。

**Q：开机自启勾选失败？**
A：请确认应用已安装到 `/Applications` 并重新打开后再勾选。

---

## 🗑️ 卸载
```bash
# 1) 右键菜单「开机自启」取消勾选
# 2) 删除应用与本地数据
rm -rf /Applications/DeepSeekBalance.app
rm -rf ~/Library/Application\ Support/DeepSeekBalance
```

---

## 📜 License
MIT © KAPAI — 欢迎使用、修改、分享，注明出处即可 💙
