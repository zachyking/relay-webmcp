import {OTLPTraceExporter} from "@opentelemetry/exporter-trace-otlp-http"
import {ExpressInstrumentation} from "@opentelemetry/instrumentation-express"
import {HttpInstrumentation} from "@opentelemetry/instrumentation-http"
import {resourceFromAttributes} from "@opentelemetry/resources"
import {NodeSDK} from "@opentelemetry/sdk-node"
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from "@opentelemetry/semantic-conventions"

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT

function tracesUrl(base: string): string {
  const url = new URL(base)
  if (!url.pathname.endsWith("/v1/traces")) {
    url.pathname = `${url.pathname.replace(/\/$/, "")}/v1/traces`
  }
  return url.toString()
}

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: "relay-mcp-edge",
    [ATTR_SERVICE_VERSION]: process.env.npm_package_version ?? "0.1.0",
    "deployment.environment.name": process.env.DEPLOYMENT_ENVIRONMENT ?? "development",
  }),
  instrumentations: [
    new HttpInstrumentation({
      ignoreIncomingRequestHook: request => request.url === "/healthz",
    }),
    new ExpressInstrumentation(),
  ],
  ...(endpoint
    ? {traceExporter: new OTLPTraceExporter({url: tracesUrl(endpoint)})}
    : {spanProcessors: []}),
})

sdk.start()

process.once("SIGTERM", () => {
  void sdk.shutdown()
})
