# 六基金波段策略系统（在线版）

该版本只展示六只基金的策略信号、回撤、走势图、买点表和策略备注，不包含个人持仓或资产金额。

GitHub Actions 每天北京时间 00:17、02:17、04:17、06:17、07:17 分批尝试获取并交叉校验上一已完成交易日的正式净值，更新页面后发布到 GitHub Pages。目标是每天 09:00 前完成六只基金更新；GitHub `schedule` 可能延迟，以上时刻为计划触发时间，不构成准时保障。也可在 Actions 页面手动运行 `Update fund data and deploy Pages`。

首次部署时，在仓库 `Settings → Pages → Build and deployment` 中选择 `GitHub Actions`。
