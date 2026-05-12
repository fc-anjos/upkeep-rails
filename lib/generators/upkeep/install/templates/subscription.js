import { createConsumer } from "@rails/actioncable"

const MARKER_SELECTOR = "script[data-upkeep-subscription]"

let consumer
const subscriptions = new Map()

function cableConsumer() {
  consumer ||= createConsumer()
  return consumer
}

function markerPayloads() {
  return Array.from(document.querySelectorAll(MARKER_SELECTOR)).map((marker) =>
    JSON.parse(marker.textContent || "{}")
  )
}

function currentSubscriptionIds() {
  return new Set(markerPayloads().map((payload) => payload.subscription_id).filter(Boolean))
}

function applyTurboStreams(html) {
  const template = document.createElement("template")
  template.innerHTML = String(html)

  template.content.querySelectorAll("turbo-stream").forEach((stream) => {
    document.documentElement.appendChild(stream)
  })
}

function subscribe(payload) {
  if (!payload.subscription_id || subscriptions.has(payload.subscription_id)) return

  const subscription = cableConsumer().subscriptions.create(
    {
      channel: payload.channel || "Upkeep::Rails::Cable::Channel",
      subscription_id: payload.subscription_id
    },
    {
      received(data) {
        applyTurboStreams(data)
      }
    }
  )

  subscriptions.set(payload.subscription_id, subscription)
}

function unsubscribeMissing() {
  const liveIds = currentSubscriptionIds()

  subscriptions.forEach((subscription, subscriptionId) => {
    if (liveIds.has(subscriptionId)) return

    subscription.unsubscribe()
    subscriptions.delete(subscriptionId)
  })
}

export function connectUpkeepSubscriptions() {
  markerPayloads().forEach(subscribe)
  unsubscribeMissing()
}

document.addEventListener("DOMContentLoaded", connectUpkeepSubscriptions)
document.addEventListener("turbo:load", connectUpkeepSubscriptions)
document.addEventListener("turbo:render", connectUpkeepSubscriptions)

connectUpkeepSubscriptions()
