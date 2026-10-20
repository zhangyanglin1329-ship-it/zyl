# 六基金基金净值｜Google 早间独立调度器

> 只需要现有 Google、GitHub 账号；无需 Cloudflare、Slack 或其他注册账号。此目录不会改变基金策略、净值计算、正式网页或自动更新工作流。

## 作用

GitHub 自身的 schedule 可能延迟。Google Apps Script 作为**独立触发层**，每 15 分钟唤醒，在北京时间 **08:00–10:45** 检查 GitHub 正式分支的六只基金净值状态：

- 已经在当天 08:00 后完成核验，并且六只基金的净值日期都达到脚本判定的最新应有交易日：**不再触发**。
- 更新缺失、任务未运行、数据仍为 `pending`、抓取失败：主动调用 GitHub `workflow_dispatch` 更新工作流。
- 避免重复任务：每次触发至少间隔 30 分钟；最多每天 6 次；如发现 GitHub 已有运行中任务，则跳过。
- 原来的 GitHub 08:00/09:30 定时任务保留作为备份；ChatGPT 的异常巡检保持独立。

**限制：** Google 触发器也有调度误差，不保证精确 08:00:00；GitHub 执行与第三方净值公布同样可能延迟。方案追求早间有冗余的**最终完成**，而不是声称绝对准点。

## 一次性安装（约 5–10 分钟）

### 1. GitHub 创建最小权限令牌

1. 打开 https://github.com/settings/personal-access-tokens/new
2. 选择 **Fine-grained personal access token**，资源所有者为你自己的 GitHub 账号。
3. Repository access 选择 **Only select repositories**，仅选择 `zyl`。
4. Repository permissions 仅将 **Actions** 调成 **Read and write**（其余保持默认最低权限）。
5. 设置适当到期日，创建令牌并妥善保管。

GitHub 官方权限说明：https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event

**切勿将令牌发到 ChatGPT、保存到 GitHub 文件、截图分享或直接写在 Code.gs 源码中。** 令牌到期后需要在 GitHub 换新，并在 Google Script Properties 中更新。

### 2. Google 创建 Apps Script

1. 打开 https://script.google.com/home/projects/create ，用现有 Google 账号登录。
2. 将本目录 [Code.gs](./Code.gs) 的**全部内容**粘贴进新项目的 `Code.gs` 并保存。
3. 到项目设置（齿轮）确认时区为 `Asia/Shanghai`。脚本本身也会以北京时间判断。
4. 在 **Script Properties（脚本属性）** 添加：
   - Property: `GITHUB_ACTIONS_TOKEN`
   - Value: 第 1 步新建的令牌（不要填进源码）。
5. 在函数下拉框选择 `installTrigger`，点击「运行」，按照 Google 提示授权。此步骤创建每 15 分钟自动触发器，重复运行不会产生重复的同名任务。
6. 选择 `testDispatchNow` 再点击「运行」。此动作将**真正发起一次** GitHub 更新工作流；成功则 Apps Script 执行日志显示 HTTP 204 已接受。
7. 打开 https://github.com/zhangyanglin1329-ship-it/zyl/actions ，核实存在新的 `workflow_dispatch` 运行且最终成功。

**不需要点击 Google「部署」**：定时触发器不是 Web App。

## 怎么判断真修好

- Google 项目的「触发器」里有 1 条 `morningNavCheck`，周期 15 分钟。
- GitHub Actions 中可看到事件类型为 `workflow_dispatch` 的任务；不依赖原定时器是否触发。
- 次日上午，六基金（002849、005125、007467、003027、002010、009690）都达到应有的上一个已完成交易日的正式净值，状态为 `current` 或 `updated`，没有 `pendingFunds`。
- GitHub Actions / Google 任一平台发生超时或第三方净值源延迟，ChatGPT 巡检依然需要报告异常。

## 紧急停止

在 Google Apps Script 项目「触发器」中删除 `morningNavCheck` 即可，不影响原 GitHub 工作流。GitHub 令牌可随时撤销。

## 技术边界

- 只使用 `POST /repos/zhangyanglin1329-ship-it/zyl/actions/workflows/update-and-deploy.yml/dispatches`，参数 `{"ref":"main"}`。
- 本脚本绝不写入基金历史数据、买卖点和策略参数。复权净值、双源验证、实际发布都由仓库现有 PowerShell 更新程序负责。
- **安全性：** 令牌仅保存在你本人 Google Apps Script 项目的 Script Properties。公共仓库不含任何凭证。
