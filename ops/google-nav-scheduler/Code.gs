/**
 * 六基金净值早间外部补偿调度器（Google Apps Script）
 *
 * 只触发 GitHub 工作流，不修改净值、策略或基金持仓。
 * 自有 Google 账号授权一次；GitHub fine-grained PAT 只放在脚本属性中。
 * 时区固定为 Asia/Shanghai。运行频率 15 分钟，实际执行有平台误差。
 */
const NAV_CONFIG = Object.freeze({
  timezone: 'Asia/Shanghai',
  owner: 'zhangyanglin1329-ship-it',
  repo: 'zyl',
  branch: 'main',
  workflow: 'update-and-deploy.yml',
  windowStartMinutes: 8 * 60,
  windowEndMinutes: 10 * 60 + 45,
  retryCooldownMinutes: 30,
  maxDispatchesPerDay: 6,
  codes: ['002849', '005125', '007467', '003027', '002010', '009690']
});

/** 只需执行一次。重复执行会先删除旧的同名触发器，避免重复任务。 */
function installTrigger() {
  const handler = 'morningNavCheck';
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === handler) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger(handler).timeBased().everyMinutes(15).create();
  console.log('Installed 15-minute scheduler. Actual dispatch window: 08:00–10:45 Beijing.');
}

/** 入口。每 15 分钟唤醒，非早间窗口不做网络请求。 */
function morningNavCheck() {
  const now = new Date();
  const local = Utilities.formatDate(now, NAV_CONFIG.timezone, 'yyyy-MM-dd HH:mm');
  const today = local.slice(0, 10);
  const hh = Number(local.slice(11, 13));
  const mm = Number(local.slice(14, 16));
  const minutes = hh * 60 + mm;
  if (minutes < NAV_CONFIG.windowStartMinutes ||
      minutes > NAV_CONFIG.windowEndMinutes) return;

  const lock = LockService.getScriptLock();
  if (!lock.tryLock(5000)) {
    console.log('Skipped overlapping scheduler invocation');
    return;
  }
  try {
    const statusAndFunds = readPublishedState(now);
    if (isMorningComplete(statusAndFunds, today)) {
      console.log('Already up to date for the expected trading day: ' +
                  statusAndFunds.status.expectedDate);
      return;
    }

    const props = PropertiesService.getScriptProperties();
    const dayKey = 'NAV_DISPATCH_DAY';
    const countKey = 'NAV_DISPATCH_COUNT';
    const lastKey = 'NAV_LAST_DISPATCH_EPOCH_MS';
    const sameDay = props.getProperty(dayKey) === today;
    const count = sameDay ? Number(props.getProperty(countKey) || 0) : 0;
    const lastAt = sameDay ? Number(props.getProperty(lastKey) || 0) : 0;

    if (count >= NAV_CONFIG.maxDispatchesPerDay) {
      console.warn('Dispatch limit reached; waiting for independent alert monitor');
      return;
    }
    if (lastAt && now.getTime() - lastAt <
        NAV_CONFIG.retryCooldownMinutes * 60000) {
      console.log('Waiting for last GitHub refresh attempt');
      return;
    }
    if (isRecentGitHubRunActive(now)) {
      console.log('GitHub workflow already queued or running');
      return;
    }

    dispatchGitHubWorkflow();
    props.setProperties({
      NAV_DISPATCH_DAY: today,
      NAV_DISPATCH_COUNT: String(count + 1),
      NAV_LAST_DISPATCH_EPOCH_MS: String(now.getTime())
    });
    console.log('GitHub NAV update dispatched at ' + local +
                ' (attempt ' + (count + 1) + ')');
  } finally {
    lock.releaseLock();
  }
}

/** 完成条件是“六只基金均达到工作流核定的应有交易日”，并非仅检查成功。 */
function isMorningComplete(data, today) {
  const status = data.status;
  if (!status || status.success !== true ||
      !['current', 'updated'].includes(status.outcome)) return false;
  if (!Array.isArray(status.pendingFunds) || status.pendingFunds.length) return false;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(status.expectedDate || '')) return false;
  const checked = Date.parse(status.checkedAt || '');
  const morningCutoff = Date.parse(today + 'T08:00:00+08:00');
  if (!Number.isFinite(checked) || checked < morningCutoff) return false;
  return NAV_CONFIG.codes.every(code => {
    const fund = data.funds[code];
    return fund && typeof fund.latestDate === 'string' &&
           fund.latestDate >= status.expectedDate;
  });
}

/** 拉取 GitHub 正式分支最新的已发布数据，避免依赖本地浏览器缓存。 */
function readPublishedState(now) {
  const url = 'https://raw.githubusercontent.com/' +
    NAV_CONFIG.owner + '/' + NAV_CONFIG.repo + '/' +
    NAV_CONFIG.branch + '/site/index.html?t=' + now.getTime();
  const response = UrlFetchApp.fetch(url, {
    muteHttpExceptions: true,
    followRedirects: true,
    headers: {'Cache-Control': 'no-cache'}
  });
  if (response.getResponseCode() !== 200) {
    throw new Error('Unable to read source HTML: HTTP ' +
                    response.getResponseCode());
  }
  const html = response.getContentText('UTF-8');
  const statusMatch = html.match(
    /window\.MULTI_FUND_UPDATE_STATUS=(\{.*?\});window\.MULTI_FUND_DB=/s);
  const dbMatch = html.match(
    /window\.MULTI_FUND_DB=(\{.*?\});\(function appMain\(\)/s);
  if (!statusMatch || !dbMatch) {
    throw new Error('Fund-data markers not found; no dispatch performed');
  }
  return {
    status: JSON.parse(statusMatch[1]),
    funds: JSON.parse(dbMatch[1])
  };
}

/** 若最近一次 Actions 运行还没结束，不再重复触发。 */
function isRecentGitHubRunActive(now) {
  const url = 'https://api.github.com/repos/' +
    NAV_CONFIG.owner + '/' + NAV_CONFIG.repo +
    '/actions/runs?per_page=8&t=' + now.getTime();
  const response = UrlFetchApp.fetch(url, {
    muteHttpExceptions: true,
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'six-fund-morning-scheduler'
    }
  });
  if (response.getResponseCode() !== 200) {
    console.warn('Could not inspect GitHub running jobs; retaining cooldown guard');
    return false;
  }
  const runs = JSON.parse(response.getContentText('UTF-8')).workflow_runs || [];
  return runs.some(run =>
    run.path === '.github/workflows/' + NAV_CONFIG.workflow &&
    ['queued', 'in_progress', 'waiting', 'pending', 'requested'].includes(run.status) &&
    now.getTime() - Date.parse(run.created_at) < 40 * 60000
  );
}

/** 只需要仓库 zyl 的 Actions: Write 权限；不要把令牌写进源代码。 */
function dispatchGitHubWorkflow() {
  const token = PropertiesService.getScriptProperties()
    .getProperty('GITHUB_ACTIONS_TOKEN');
  if (!token) throw new Error(
    'Missing Script Property GITHUB_ACTIONS_TOKEN; follow README setup');
  const url = 'https://api.github.com/repos/' +
    NAV_CONFIG.owner + '/' + NAV_CONFIG.repo +
    '/actions/workflows/' + NAV_CONFIG.workflow + '/dispatches';
  const response = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    payload: JSON.stringify({ref: NAV_CONFIG.branch}),
    muteHttpExceptions: true,
    headers: {
      Authorization: 'Bearer ' + token,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'six-fund-morning-scheduler'
    }
  });
  if (response.getResponseCode() !== 204) {
    throw new Error('GitHub workflow dispatch failed: HTTP ' +
                    response.getResponseCode() + ' ' +
                    response.getContentText().slice(0, 350));
  }
}

/** 首次配置完成后手动执行一次，用于验证 Google → GitHub 调用链路。 */
function testDispatchNow() {
  dispatchGitHubWorkflow();
  console.log('Test dispatch accepted by GitHub (HTTP 204). Check Actions run.');
}
