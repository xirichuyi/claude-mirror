// Keep the unstable SDK usage API behind one validated boundary.
const LIMIT_PERCENT = 95;
function quotaReport(report) {
  const windows = [];
  for (const [id, title] of [['five_hour', '五小时'], ['seven_day', '本周 · 全部模型']]) {
    const value = report?.rate_limits?.[id];
    if (Number.isFinite(value?.utilization) && value.utilization >= 0 && value.utilization <= 100)
      windows.push({ id, title, used: value.utilization, resetsAt: value.resets_at || null });
  }
  const available = report?.rate_limits_available === true && windows.length === 2;
  return { available, windows, limitPercent: LIMIT_PERCENT, fetchedAt: Date.now(),
    blocked: !available || windows.some(row => row.used >= LIMIT_PERCENT) };
}

async function readAccountQuota(client) {
  const read = client.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET;
  if (typeof read !== 'function') throw new Error('远端 Claude 不支持额度查询，请升级后再试');
  let timer;
  try {
    const result = await Promise.race([read.call(client, { skipBehaviors: true }), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('读取账户额度超时')), 15000);
    })]);
    return quotaReport(result);
  } finally { clearTimeout(timer); }
}

function requireQuota(report) {
  if (!report.available) throw new Error('额度保护：无法确认订阅额度，已暂停请求；请检查远端登录、订阅及 Claude 版本');
  const exhausted = report.windows.find(row => row.used >= report.limitPercent);
  if (exhausted) throw new Error(`额度保护：${exhausted.title}已用 ${exhausted.used}%，保留 5% 额度，已暂停请求${exhausted.resetsAt ? '；重置时间 ' + exhausted.resetsAt : ''}`);
}

module.exports = { quotaReport, readAccountQuota, requireQuota };
