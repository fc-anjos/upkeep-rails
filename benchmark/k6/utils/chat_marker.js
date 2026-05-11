const CHAT_MARKER_PREFIX = "bench-msg:";

export function buildChatBenchmarkBody(sendTs, vu, iteration) {
  return `${CHAT_MARKER_PREFIX}${sendTs}:${vu}:${iteration}`;
}

export function extractChatBenchmarkMarkers(serializedPayload) {
  if (typeof serializedPayload !== "string" || serializedPayload.length === 0) return [];

  const markers = [];
  let cursor = 0;

  while (cursor < serializedPayload.length) {
    const prefixAt = serializedPayload.indexOf(CHAT_MARKER_PREFIX, cursor);
    if (prefixAt === -1) break;

    let markerEnd = prefixAt + CHAT_MARKER_PREFIX.length;
    while (markerEnd < serializedPayload.length) {
      const code = serializedPayload.charCodeAt(markerEnd);
      const isDigit = code >= 48 && code <= 57;
      if (!isDigit && code !== 58) break;
      markerEnd += 1;
    }

    cursor = markerEnd;

    const marker = serializedPayload.slice(prefixAt + CHAT_MARKER_PREFIX.length, markerEnd);
    const parts = marker.split(":");
    if (parts.length !== 3) continue;

    const parsedTs = Number.parseInt(parts[0], 10);
    if (Number.isNaN(parsedTs)) continue;

    markers.push({ marker, sendTs: parsedTs });
  }

  return markers;
}
