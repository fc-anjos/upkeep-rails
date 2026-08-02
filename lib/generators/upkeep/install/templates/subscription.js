import { createConsumer } from "@rails/actioncable"
import { Turbo } from "@hotwired/turbo-rails"

const SOURCE_ELEMENT = "upkeep-subscription-source"
const SOURCE_SELECTOR = `${SOURCE_ELEMENT}[data-upkeep-subscription]`
const ID_HEADER = "X-Upkeep-Subscription-Id"
const TOKEN_HEADER = "X-Upkeep-Subscription-Token"
const CHANNEL_HEADER = "X-Upkeep-Subscription-Channel"
const STREAM_HEADER = "X-Upkeep-Subscription-Stream"
const ACTION_HEADER = "X-Upkeep-Subscription-Action"

let consumer
let activeFrame
const queuedFrames = []

function cableConsumer() {
  consumer ||= createConsumer()
  return consumer
}

function sourceElement() {
  return document.querySelector(SOURCE_SELECTOR)
}

function ensureSourceElement() {
  const existing = sourceElement()
  if (existing) return existing
  if (!document.body) return

  const source = document.createElement(SOURCE_ELEMENT)
  source.id = "upkeep-subscription-source"
  source.hidden = true
  source.style.display = "none"
  source.setAttribute("data-upkeep-subscription", "")
  document.body.append(source)
  return source
}

function parsePayload(element) {
  return {
    channel: element.getAttribute("channel"),
    subscription_id: element.getAttribute("subscription-id"),
    activation_token: element.getAttribute("activation-token"),
    stream_name: element.getAttribute("stream-name")
  }
}

function responsePayload(fetchResponse) {
  const headers = fetchResponse?.response?.headers
  const subscriptionId = headers?.get(ID_HEADER)
  if (!subscriptionId) return

  return {
    channel: headers.get(CHANNEL_HEADER),
    subscription_id: subscriptionId,
    activation_token: headers.get(TOKEN_HEADER),
    stream_name: headers.get(STREAM_HEADER)
  }
}

function setHeader(headers, name, value) {
  if (headers?.set) {
    headers.set(name, value)
  } else {
    headers[name] = value
  }
}

function addSubscriptionHeaders(fetchOptions) {
  const source = sourceElement()
  if (!source) return

  const payload = parsePayload(source)
  if (!payload.subscription_id || !payload.activation_token) return

  setHeader(fetchOptions.headers, ID_HEADER, payload.subscription_id)
  setHeader(fetchOptions.headers, TOKEN_HEADER, payload.activation_token)
}

function beginFrameFetch(event) {
  const frame = event.target
  if (frame?.tagName !== "TURBO-FRAME") return

  const start = () => {
    activeFrame = frame
    addSubscriptionHeaders(event.detail.fetchOptions)
    event.detail.resume?.()
  }

  if (activeFrame && activeFrame !== frame) {
    event.preventDefault()
    queuedFrames.push(start)
  } else {
    activeFrame = frame
    addSubscriptionHeaders(event.detail.fetchOptions)
  }
}

function finishFrameFetch(frame) {
  if (activeFrame !== frame) return

  activeFrame = null
  queuedFrames.shift()?.()
}

function reloadFrom(fetchResponse) {
  const location = fetchResponse?.response?.url || window.location.href
  Turbo.visit(location, { action: "replace" })
}

function renderStreamMessage(data) {
  if (Turbo?.renderStreamMessage) {
    Turbo.renderStreamMessage(String(data))
  }
}

class UpkeepSubscriptionSourceElement extends HTMLElement {
  connectedCallback() {
    this.connectStreamSource()
    this.subscribe()
  }

  disconnectedCallback() {
    this.transitionGeneration = (this.transitionGeneration || 0) + 1
    this.candidateSubscription?.unsubscribe()
    this.candidateSubscription = null
    this.unsubscribe()
    this.disconnectStreamSource()
    this.removeAttribute("connected")
  }

  connectStreamSource() {
    if (this.streamSourceConnected) return
    if (!Turbo?.session?.connectStreamSource) return

    Turbo.session.connectStreamSource(this)
    this.streamSourceConnected = true
  }

  disconnectStreamSource() {
    if (!this.streamSourceConnected) return

    Turbo.session.disconnectStreamSource(this)
    this.streamSourceConnected = false
  }

  subscribe() {
    const payload = parsePayload(this)
    if (!payload.subscription_id || this.subscription) return

    this.subscription = this.createSubscription(payload, {
      connected: () => this.setAttribute("connected", ""),
      disconnected: () => this.removeAttribute("connected")
    })
  }

  replaceSubscription(payload, { connected, rejected } = {}) {
    if (!payload?.subscription_id) return
    if (payload.subscription_id === parsePayload(this).subscription_id) {
      connected?.()
      return
    }

    const generation = (this.transitionGeneration || 0) + 1
    this.transitionGeneration = generation
    this.candidateSubscription?.unsubscribe()

    let candidate
    candidate = this.createSubscription(payload, {
      connected: () => {
        if (this.transitionGeneration !== generation || !this.isConnected) {
          candidate.unsubscribe()
          return
        }

        const previous = this.subscription
        this.subscription = candidate
        this.candidateSubscription = null
        this.applyPayload(payload)
        this.setAttribute("connected", "")
        previous?.unsubscribe()
        connected?.()
      },
      rejected: () => {
        if (this.transitionGeneration !== generation) return

        this.candidateSubscription = null
        rejected?.()
      }
    })
    this.candidateSubscription = candidate
  }

  createSubscription(payload, callbacks = {}) {
    const channel = payload.channel || "Upkeep::Rails::Cable::Channel"

    return cableConsumer().subscriptions.create(
      {
        channel,
        subscription_id: payload.subscription_id,
        activation_token: payload.activation_token
      },
      {
        connected: callbacks.connected,
        disconnected: callbacks.disconnected,
        received: (data) => this.receive(data),

        rejected: () => {
          console.error(
            "[upkeep] subscription rejected by the server; the rejection reason is in the server log",
            { subscription_id: payload.subscription_id, channel }
          )
          callbacks.rejected?.()
        }
      }
    )
  }

  applyPayload(payload) {
    this.setAttribute("channel", payload.channel || "Upkeep::Rails::Cable::Channel")
    this.setAttribute("subscription-id", payload.subscription_id)
    this.setAttribute("activation-token", payload.activation_token)
    this.setAttribute("stream-name", payload.stream_name || "")
  }

  unsubscribe() {
    if (!this.subscription) return

    this.subscription.unsubscribe()
    this.subscription = null
  }

  receive(data) {
    if (this.streamSourceConnected) {
      this.dispatchEvent(new MessageEvent("message", { data: String(data) }))
    } else {
      renderStreamMessage(data)
    }
  }
}

if (!customElements.get(SOURCE_ELEMENT)) {
  customElements.define(SOURCE_ELEMENT, UpkeepSubscriptionSourceElement)
}

ensureSourceElement()
document.addEventListener("turbo:before-fetch-request", beginFrameFetch)
document.addEventListener("turbo:frame-render", (event) => {
  const source = ensureSourceElement()
  const fetchResponse = event.detail.fetchResponse
  const action = fetchResponse?.response?.headers?.get(ACTION_HEADER)
  const payload = responsePayload(fetchResponse)

  if (action === "reload") {
    reloadFrom(fetchResponse)
  } else if (source && payload) {
    source.replaceSubscription(payload, {
      connected: () => finishFrameFetch(event.target),
      rejected: () => reloadFrom(fetchResponse)
    })
  } else {
    finishFrameFetch(event.target)
  }
})
document.addEventListener("turbo:fetch-request-error", (event) => finishFrameFetch(event.target))
document.addEventListener("turbo:frame-missing", (event) => finishFrameFetch(event.target))
document.addEventListener("turbo:load", ensureSourceElement)

export function connectUpkeepSubscriptions() {
  document.querySelectorAll(SOURCE_SELECTOR).forEach((source) => source.subscribe?.())
}
