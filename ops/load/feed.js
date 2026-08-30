import http from "k6/http"
import {check} from "k6"

const baseUrl = __ENV.RELAY_BASE_URL || "http://localhost:4000"
const token = __ENV.RELAY_TOKEN

if (!token) throw new Error("RELAY_TOKEN is required")

export const options = {
  scenarios: {
    steady: {
      executor: "constant-arrival-rate",
      rate: 500,
      timeUnit: "1s",
      duration: "5m",
      preAllocatedVUs: 200,
      maxVUs: 1200,
    },
    burst: {
      executor: "constant-arrival-rate",
      startTime: "5m",
      rate: 2000,
      timeUnit: "1s",
      duration: "30s",
      preAllocatedVUs: 500,
      maxVUs: 3000,
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{endpoint:feed}": ["p(95)<750"],
    "http_req_duration{endpoint:inbox}": ["p(95)<300"],
  },
}

const params = {
  headers: {Authorization: `Bearer ${token}`, Accept: "application/json"},
}

export default function () {
  const feed = http.get(`${baseUrl}/api/v1/feed?limit=20`, {...params, tags: {endpoint: "feed"}})
  check(feed, {"feed succeeds": response => response.status === 200})

  const inbox = http.get(`${baseUrl}/api/v1/inbox?limit=20`, {...params, tags: {endpoint: "inbox"}})
  check(inbox, {"inbox succeeds": response => response.status === 200})
}
