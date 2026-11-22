// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package gtprof

import (
	"context"
	"net/http"
	"os"
	"strings"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// OpenTelemetry tracer: mirrors every gtprof span into an OTel span exported over OTLP/HTTP.
// Configured only by the standard OTEL_* env vars (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_HEADERS,
// OTEL_SERVICE_NAME, ...); nothing happens unless OTEL_EXPORTER_OTLP_ENDPOINT is set.

var otelPropagator = propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{})

type traceOtelStarter struct {
	tracer trace.Tracer
}

type traceOtelSpan struct {
	ts   *TraceSpan
	span trace.Span
}

func (t *traceOtelStarter) start(ctx context.Context, traceSpan *TraceSpan, _ int) (context.Context, traceSpanInternal) {
	// Only HTTP requests start a trace. Background work (cron, queues) would otherwise turn every
	// SQL query or git command into its own single-span trace.
	if !trace.SpanContextFromContext(ctx).IsValid() && traceSpan.name != TraceSpanHTTP {
		return ctx, &traceOtelSpan{ts: traceSpan, span: trace.SpanFromContext(ctx)}
	}
	kind := trace.SpanKindInternal
	if traceSpan.name == TraceSpanHTTP {
		kind = trace.SpanKindServer
	}
	ctx, span := t.tracer.Start(ctx, traceSpan.name, trace.WithTimestamp(traceSpan.startTime), trace.WithSpanKind(kind))
	return ctx, &traceOtelSpan{ts: traceSpan, span: span}
}

func otelAttributes(attrs []*TraceAttribute) []attribute.KeyValue {
	kvs := make([]attribute.KeyValue, 0, len(attrs))
	for _, a := range attrs {
		switch v := a.Value.v.(type) {
		case int64:
			kvs = append(kvs, attribute.Int64(a.Key, v))
		case float64:
			kvs = append(kvs, attribute.Float64(a.Key, v))
		default:
			kvs = append(kvs, attribute.String(a.Key, a.Value.AsString()))
		}
	}
	return kvs
}

func (t *traceOtelSpan) addEvent(name string, cfg *EventConfig) {
	t.span.AddEvent(name, trace.WithAttributes(otelAttributes(cfg.attributes)...))
}

func (t *traceOtelSpan) recordError(err error, cfg *EventConfig) {
	t.span.RecordError(err, trace.WithAttributes(otelAttributes(cfg.attributes)...))
}

func (t *traceOtelSpan) end() {
	if !t.span.IsRecording() {
		return
	}
	t.ts.mu.RLock()
	name, attrs := t.ts.name, otelAttributes(t.ts.attributes)
	statusCode, statusDesc, endTime := t.ts.statusCode, t.ts.statusDesc, t.ts.endTime
	t.ts.mu.RUnlock()

	switch name {
	case TraceSpanHTTP:
		// "GET /{username}/{reponame}" instead of the generic "http"
		var method, route string
		for _, kv := range attrs {
			switch kv.Key {
			case TraceAttrHTTPMethod:
				method = kv.Value.AsString()
			case TraceAttrHTTPRoute:
				route = kv.Value.AsString()
			}
		}
		if route != "" {
			name = strings.TrimSpace(method + " " + route)
		}
	case TraceSpanDatabase:
		for _, kv := range attrs {
			if kv.Key == TraceAttrDbSQL {
				if verb, _, _ := strings.Cut(strings.TrimSpace(kv.Value.AsString()), " "); verb != "" {
					name = "db " + strings.ToUpper(verb)
				}
			}
		}
	}
	t.span.SetName(name)
	t.span.SetAttributes(attrs...)
	if statusCode != 0 {
		t.span.SetStatus(codes.Code(statusCode), statusDesc)
	}
	t.span.End(trace.WithTimestamp(endTime))
}

// ExtractHTTPContext continues a trace started by the caller (W3C traceparent header).
// It is a no-op unless the OTel tracer is enabled.
func ExtractHTTPContext(ctx context.Context, header http.Header) context.Context {
	if !otelEnabled {
		return ctx
	}
	return otelPropagator.Extract(ctx, propagation.HeaderCarrier(header))
}

var otelEnabled bool

// EnableOtelTracer registers the OTel tracer when OTEL_EXPORTER_OTLP_ENDPOINT is set.
// It must be called once at startup, before serving requests. The returned func flushes pending spans.
func EnableOtelTracer(ctx context.Context) (shutdown func(context.Context) error, err error) {
	shutdown = func(context.Context) error { return nil }
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		return shutdown, nil
	}
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return shutdown, err
	}
	res, err := resource.Merge(resource.Default(), resource.Environment())
	if err != nil {
		return shutdown, err
	}
	provider := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exporter), sdktrace.WithResource(res))
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(otelPropagator)
	globalTraceStarters = append(globalTraceStarters, &traceOtelStarter{tracer: provider.Tracer("gitea.dev/modules/gtprof")})
	otelEnabled = true
	return provider.Shutdown, nil
}
