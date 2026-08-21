# deepseek用量监控组件

> deepseek用量监控组件：一个轻量、低占用的 **macOS 菜单栏小部件**，让你随时掌握 DeepSeek 余额与 Codex Token 消耗。
> 无需 Dock 图标，只在菜单栏安静陪伴 👀，余额不足还会提醒你充值 💡。

---

## 📖 基础说明

DeepSeek 余额小组件是一款为 **Codex + DeepSeek** 用户打造的菜单栏工具：

- 🎯 菜单栏实时显示 **DeepSeek 余额**（🐋 ¥12.34）
- ⚡ Codex 正在跑任务时显示 ⚡ 标记，并**每 5 秒实时刷新**
- 📊 内置 **Tokens 消耗柱状图** 与 **项目详情**，一眼看懂钱花在哪
- 💰 可接入 **DeepSeek 官网记录**，人民币消耗与官网**完全一致**
- 🔔 余额低于 ¥1 自动发系统通知，提醒及时充值

数据全部保存在本机，**不收集、不上传任何隐私**。

---

## ✨ 详细特点

### 🖥️ 菜单栏 & 弹窗
- 🐋 菜单栏图标显示 `¥余额`，低余额附加 `⚠️`，Codex 活跃附加 `⚡`
- 🪟 点击菜单栏打开弹窗：余额大字 + 总充值金额 + 消耗 tokens + 更新时间
- 🖱️ 右键菜单：刷新、切换刷新间隔、打开图表/项目详情、开机自启、设置等

### ⚡ 智能实时刷新
- ⏱️ Codex 活跃时（会话文件 30 秒内有写入）**每 5 秒**刷新余额
- 😴 空闲时按设定间隔刷新（1 / 5 / 15 分钟可切换）
- 🔋 低占用：流式解析会话文件，峰值内存仅 ~256KB，不整文件载入

### 📊 Tokens 消耗柱状图
- 📅 股票式周期筛选：今日 / 7天 / 30天 / 3月 / 6月 / 1年 / 全部
- 🖱️ 鼠标悬停查看该时段**各项目消耗明细**（中文项目名）
- 🔴 充值事件用红色竖线标记，鼠标悬停可见金额

### 💰 人民币消耗（官网记录）
- 🔗 接入 DeepSeek 官网 `usage/cost` + `usage/amount` 接口，按日显示**官方消耗**，与官网一致
- ⏳ 图表打开时每 60 秒自动同步最新记录
- 📉 未接入时自动回退为「余额下降估算」，功能不中断

### 📁 项目详情
- 🏷️ 按项目聚合：中文标题、开始时间、最后活跃、会话数
- ⏲️ 真实运行耗时（连续事件累加）+ 项目创建至今时长
- 📈 每个项目的 Tokens 消耗横向条形图

### 🔔 低余额提醒
- 💸 余额低于 ¥1 自动发送一次系统通知，回升后复位可再次提醒

### 🛠️ 开机自启 & 配置
- 🚀 右键菜单一键勾选「开机自启」（SMAppService）
- 🔑 弹窗内直接设置 API Key / 接入官网记录，无需手动改文件

---

## 🚀 部署安装（详细教程）

> 仅需 macOS 命令行工具，**不需要安装 Xcode**。

### 方式一：直接下载 .app（推荐给普通用户）📦
1. 下载 `DeepSeekBalance.app`
2. 把它拖到 `访达 → 应用程序`
3. 双击运行（无 Dock 图标，菜单栏会出现 🐋）
4. 首次运行会请求「通知权限」，点击允许
5. 点击 🐋 → 弹窗「API Key → 设置…」粘贴你的 DeepSeek API Key

> ⚠️ 若提示“无法打开，因为无法验证开发者”，右键应用 → 打开 → 再次打开即可（个人开发者的正常提示）。

### 方式二：从源码打包（推荐给开发者）🛠️
```bash
# 1️⃣ 克隆仓库
git clone https://github.com/KAPAIJUN/DeepSeekBalance.git
cd DeepSeekBalance

# 2️⃣ 一键打包（自动编译 + 组装 .app + 复制资源 + 签名）
./build.sh

# 3️⃣ 打包并安装到 /Applications 并启动
./build.sh install
```

### 方式三：手动编译（了解原理）⌨️
```bash
xcrun swiftc -parse-as-library -O -o DeepSeekBalance DeepSeekBalance.swift \
  -framework SwiftUI -framework AppKit -framework UserNotifications -framework Charts
# 把资源复制进 .app/Contents/Resources/ 后
codesign --force -s - DeepSeekBalance.app
```

---

## ⚙️ 配置指南

### 🔑 1. 配置 API Key（必需）
余额接口需要 DeepSeek API Key，按优先级读取：
1. **弹窗内设置**：点击 🐋 → 「API Key → 设置…」粘贴（推荐）
2. 环境变量：`export DEEPSEEK_API_KEY=sk-xxx`
3. 兼容旧版 CodexBar 配置

> API Key 申请地址：https://platform.deepseek.com/api_keys

### 🔗 2. 接入官网记录（可选，强烈推荐）
让人民币消耗与官网完全一致：
1. 浏览器登录 https://platform.deepseek.com
2. 按 `F12` → Console，输入并回车：
   ```js
   localStorage.getItem('userToken')
   ```
3. 复制返回的字符串
4. 点击 🐋 → 弹窗「官网记录 → 接入…」→「读取剪贴板」→ 保存

> Token 仅保存在本机 `config.json`（权限 600），绝不上传。

### 💰 3. 设置初始充值金额（可选）
右键 🐋 →「设置初始充值金额…」，输入你已充值的总金额（元），用于累计充值统计。

---

## 📁 数据与隐私
- 数据全部保存在本机：`~/Library/Application Support/DeepSeekBalance/`
  - `config.json` ｜ API Key / 官网 Token / 刷新间隔（权限 600）
  - `state.json` ｜ 最近一次刷新状态
  - `balance_history.json` ｜ 余额读数历史
  - `platform_usage.json` ｜ 官网每日消耗缓存
  - `recharge.json` ｜ 充值记录
- 🚫 本项目**不收集、不上传**任何用户数据
- 🌏 官网每日消耗按北京时间对齐，与 DeepSeek 官网一致
- 📂 Codex 数据目录优先读取 `CODEX_HOME`，默认 `~/.codex`

---

## ❓ 常见问题（FAQ）

**Q：菜单栏没有 🐋？**
A：到「应用程序」找到 DeepSeekBalance 双击运行；首次可能需要在 系统设置 → 隐私与安全性 允许。

**Q：显示「未配置 API Key」？**
A：点击 🐋 → 弹窗「API Key → 设置…」粘贴你的 Key。

**Q：人民币柱状图和官网对不上？**
A：确认已接入官网记录（弹窗「官网记录」显示「已接入 ✓」），并点击图表右上角「刷新」。

**Q：消耗 tokens 不更新？**
A：组件扫描 `~/.codex/sessions/` 下的会话文件；如果你自定义了 Codex 目录，请设置 `CODEX_HOME` 环境变量。

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
