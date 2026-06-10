import { createConsumer } from "@rails/actioncable"
import { Turbo } from "@hotwired/turbo-rails"

const SOURCE_ELEMENT = "upkeep-subscription-source"
const SOURCE_SELECTOR = `${SOURCE_ELEMENT}[data-upkeep-subscription]`

let consumer

function cableConsumer() {
  consumer ||= createConsumer()
  return consumer
}

function parsePayload(element) {
  return {
    channel: element.getAttribute("channel"),
    subscription_id: element.getAttribute("subscription-id"),
    activation_token: element.getAttribute("activation-token"),
    stream_name: element.getAttribute("stream-name")
  }
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
    this.unsubscribe()
    this.disconnectStreamSource()
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

    this.subscription = cableConsumer().subscriptions.create(
      {
        channel: payload.channel || "Upkeep::Rails::Cable::Channel",
        subscription_id: payload.subscription_id,
        activation_token: payload.activation_token
      },
      {
        received: (data) => this.receive(data),

        rejected: () => {
          console.error(
            "[upkeep] subscription rejected by the server; the rejection reason is in the server log",
            { subscription_id: payload.subscription_id, channel: payload.channel || "Upkeep::Rails::Cable::Channel" }
          )
        }
      }
    )
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

export function connectUpkeepSubscriptions() {
  document.querySelectorAll(SOURCE_SELECTOR).forEach((source) => source.subscribe?.())
}
