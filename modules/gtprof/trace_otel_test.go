// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package gtprof

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func TestOtelTracer(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
	defer func(old []traceStarter, oldEnabled bool) { globalTraceStarters, otelEnabled = old, oldEnabled }(globalTraceStarters, otelEnabled)
	globalTraceStarters = []traceStarter{&traceOtelStarter{tracer: provider.Tracer("test")}}
	otelEnabled = true

	// background work without an HTTP root is not traced
	_, bg := GetTracer().Start(t.Context(), TraceSpanDatabase)
	bg.End()
	assert.Empty(t, recorder.Ended())

	header := http.Header{}
	header.Set("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
	ctx := ExtractHTTPContext(t.Context(), header)
	ctx, root := GetTracer().Start(ctx, TraceSpanHTTP)
	_, db := GetTracer().Start(ctx, TraceSpanDatabase)
	db.SetAttributeString(TraceAttrDbSQL, "SELECT * FROM `user` WHERE id=?")
	db.End()
	root.SetAttributeString(TraceAttrHTTPRoute, "/api/v1/repos/{owner}/{repo}")
	root.SetAttributeString(TraceAttrHTTPMethod, "GET")
	root.SetAttributeInt64(TraceAttrHTTPStatus, 500)
	root.SetStatus(1, "Internal Server Error")
	root.End()

	spans := recorder.Ended()
	require.Len(t, spans, 2)
	dbSpan, httpSpan := spans[0], spans[1]
	assert.Equal(t, "db SELECT", dbSpan.Name())
	assert.Equal(t, "GET /api/v1/repos/{owner}/{repo}", httpSpan.Name())
	assert.Equal(t, "4bf92f3577b34da6a3ce929d0e0e4736", httpSpan.SpanContext().TraceID().String())
	assert.Equal(t, "00f067aa0ba902b7", httpSpan.Parent().SpanID().String())
	assert.Equal(t, httpSpan.SpanContext().SpanID(), dbSpan.Parent().SpanID())
	assert.Equal(t, codes.Error, httpSpan.Status().Code)
}
