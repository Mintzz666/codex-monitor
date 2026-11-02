function formatResetTime(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  const date = new Date(seconds * 1000);
  if (!Number.isFinite(date.getTime())) return null;
  return `${new Intl.DateTimeFormat('zh-CN', {timeZone:'Asia/Singapore', month:'numeric', day:'numeric', hour:'2-digit', minute:'2-digit', hour12:false}).format(date)} SIN`;
}
