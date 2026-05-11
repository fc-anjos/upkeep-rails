import { isApplicationMessage } from "./messages.js";

export function awaitSubscriptionAck(sub) {
  if (!sub || typeof sub.ackDuration !== "function") return null;

  return sub.ackDuration();
}

export function receiveApplicationMessages(sub, _channel, timeoutSeconds = 0) {
  if (!sub) return [];
  const incoming = sub.receiveAll(timeoutSeconds);
  return incoming.filter((message) => isApplicationMessage(message));
}

export function drainPendingDeliveries(sub, channel, timeoutSeconds = 0) {
  return receiveApplicationMessages(sub, channel, timeoutSeconds);
}
