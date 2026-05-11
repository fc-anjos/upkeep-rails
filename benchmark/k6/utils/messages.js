function parseJson(value) {
  if (typeof value !== "string") return value;

  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

export function extractCableApplicationMessage(raw) {
  const message = parseJson(raw);

  if (!message) return null;
  if (typeof message === "string") return message;

  if (typeof message !== "object") return null;
  if (typeof message.type === "string") return null;
  if (Object.prototype.hasOwnProperty.call(message, "message")) {
    return extractCableApplicationMessage(message.message);
  }

  return message;
}

export function serializeCableApplicationMessage(raw) {
  const payload = extractCableApplicationMessage(raw);
  if (payload === null) return "";
  return typeof payload === "string" ? payload : JSON.stringify(payload);
}

export function isApplicationMessage(raw) {
  return extractCableApplicationMessage(raw) !== null;
}
