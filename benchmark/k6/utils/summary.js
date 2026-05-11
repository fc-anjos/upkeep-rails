function metricValue(metric, key) {
  if (!metric || !metric.values) return null;
  const value = metric.values[key];
  return typeof value === "number" ? value : null;
}

function formatNumber(value) {
  if (value === null || value === undefined) return "-";
  if (!Number.isFinite(value)) return String(value);
  if (Math.abs(value) >= 1000) return value.toFixed(0);
  if (Math.abs(value) >= 100) return value.toFixed(1);
  return value.toFixed(2);
}

function formatMetric(name, metric) {
  if (!metric || !metric.type) return `${name}: -`;

  if (metric.type === "counter" || metric.type === "gauge") {
    return `${name}: ${formatNumber(metricValue(metric, "count") ?? metricValue(metric, "value"))}`;
  }

  const parts = [];
  const avg = metricValue(metric, "avg");
  const med = metricValue(metric, "med");
  const p95 = metricValue(metric, "p(95)");
  const max = metricValue(metric, "max");

  if (avg !== null) parts.push(`avg=${formatNumber(avg)}`);
  if (med !== null) parts.push(`med=${formatNumber(med)}`);
  if (p95 !== null) parts.push(`p(95)=${formatNumber(p95)}`);
  if (max !== null) parts.push(`max=${formatNumber(max)}`);

  return `${name}: ${parts.join("  ") || "-"}`;
}

export function textSummary(data, { indent = "", enableColors = false } = {}) {
  const lines = [];
  const metrics = data?.metrics || {};

  lines.push("");
  lines.push(`${indent}k6 summary`);
  lines.push(`${indent}${"=".repeat(10)}`);

  Object.keys(metrics).sort().forEach((name) => {
    lines.push(`${indent}${formatMetric(name, metrics[name])}`);
  });

  if (enableColors) {
    return `${lines.join("\n")}\n`;
  }

  return `${lines.join("\n")}\n`;
}

