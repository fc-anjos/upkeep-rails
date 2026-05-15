import http from "k6/http";
import { check, sleep } from "k6";

// Login and return the session cookie jar.
// Login is the only endpoint that uses JSON + skip_csrf — there's no
// page to extract a CSRF token from before authenticating.
//
// Retries on transient failures (non-200 status, including 401/5xx that
// appear under saturation bursts). Backoff is short + jittered so a
// ramp cohort doesn't re-collide on retry.
export function login(baseUrl, email, password, { maxAttempts = 4, startedAtMs = Date.now() } = {}) {
  const jar = http.cookieJar();
  let res;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    res = http.post(
      `${baseUrl}/sessions`,
      JSON.stringify({ email, password }),
      {
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-Bench-Client-Started-At-Ms": `${startedAtMs}`,
        },
        jar,
      }
    );
    if (res.status === 200) break;
    if (attempt < maxAttempts) sleep(0.1 * attempt + Math.random() * 0.2);
  }

  check(res, {
    "login successful": (r) => r.status === 200,
  });

  return jar;
}

// Convert a k6 cookie jar to a "name=value; ..." string for xk6-cable
export function cookieString(jar, url) {
  const cookies = jar.cookiesForURL(url);
  return Object.entries(cookies)
    .map(([name, values]) => `${name}=${values[0]}`)
    .join("; ");
}

// Extract the Rails CSRF token from a page's <meta name="csrf-token"> tag
export function extractCsrfToken(body) {
  const start = body.indexOf('name="csrf-token" content="');
  if (start === -1) return "";
  const offset = start + 'name="csrf-token" content="'.length;
  const end = body.indexOf('"', offset);
  if (end === -1) return "";
  return body.substring(offset, end);
}
