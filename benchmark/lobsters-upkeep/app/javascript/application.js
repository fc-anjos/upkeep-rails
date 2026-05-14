// Benchmark JavaScript entrypoint.
import "@hotwired/turbo-rails"
import "upkeep/subscription"

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content
}

document.addEventListener("click", (event) => {
  const link = event.target.closest("a.saver")
  if (!link) return

  event.preventDefault()

  fetch(link.href, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Accept": "text/plain",
      "X-CSRF-Token": csrfToken() || ""
    }
  })
})
