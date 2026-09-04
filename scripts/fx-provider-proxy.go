// ffx-provider-proxy: a minimal adapter that lets ffx talk to any
// OpenAI-compatible chat-completions endpoint without the Vercel AI Gateway.
//
// Place it between ffx and the provider:
//
//   FFX_PROVIDER_UPSTREAM=https://api.minimax.io
//   FFX_PROVIDER_UPSTREAM_KEY=***:9999
//   FFX_PROVIDER_BASE_URL=http://127.0.0.1:9999
//   FFX_PROVIDER_API_KEY=anything
//   FFX_GATEWAY_CHAT_URL=http://127.0.0.1:9999/v3/ai/language-model
//   FFX_GATEWAY_BASE_URL=http://127.0.0.1:9999
//   FFX_GATEWAY_ALLOW_EXTERNAL=1
//
// ffx speaks the AI Gateway v3 dialect to this proxy. The proxy rewrites the
// request body to OpenAI chat-completions, forwards it, and emits SSE events
// in the same AI Gateway v3 dialect ffx expects back. This is the *minimum*
// needed to prove the no-login path works end-to-end. Tool calls, vision,
// and structured outputs are not supported by this proxy; they require a
// real ffx-side adapter.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

// ffx sends this shape (mirrors gateway_json.zig).
type agRequest struct {
	Model     string                   `json:"model"`
	Prompt    []map[string]interface{} `json:"prompt"`
	MaxTokens *int                     `json:"maxOutputTokens,omitempty"`
	Stream    bool                     `json:"stream,omitempty"`
}

// OpenAI chat-completions request shape.
type oaiRequest struct {
	Model     string                   `json:"model"`
	Messages  []map[string]interface{} `json:"messages"`
	MaxTokens *int                     `json:"max_tokens,omitempty"`
	Stream    bool                     `json:"stream"`
}

// OpenAI chat-completions non-streamed response.
type oaiResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

func main() {
	addr := os.Getenv("FFX_PROVIDER_PROXY_ADDR")
	if addr == "" {
		addr = ":9999"
	}
	upstream := os.Getenv("FFX_PROVIDER_UPSTREAM")
	if upstream == "" {
		log.Fatal("FFX_PROVIDER_UPSTREAM is required (e.g. https://api.minimax.io)")
	}
	upstreamKey := os.Getenv("FFX_PROVIDER_UPSTREAM_KEY")
	if upstreamKey == "" {
		log.Fatal("FFX_PROVIDER_UPSTREAM_KEY is required")
	}
	upstreamModel := os.Getenv("FFX_PROVIDER_UPSTREAM_MODEL")
	if upstreamModel == "" {
		log.Fatal("FFX_PROVIDER_UPSTREAM_MODEL is required (e.g. minimax/MiniMax-M2)")
	}

	http.HandleFunc("/v3/ai/language-model", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		log.Printf("proxy incoming body (%d bytes): %s", len(body), string(body[:min(512, len(body))]))

		var ag agRequest
		if err := json.Unmarshal(body, &ag); err != nil {
			http.Error(w, "bad AG body: "+err.Error(), 400)
			return
		}

		// Honour the model id that ffx asked for: empty strings fall through
		// to the proxy default (FFX_PROVIDER_UPSTREAM_MODEL). Real provider
		// ids like "minimax/M2" or "openai/gpt-4o" pass through unchanged.
		requestedModel := ag.Model
		if requestedModel == "" {
			requestedModel = upstreamModel
		}
		oai := oaiRequest{
			Model:     requestedModel,
			Messages:  ag.Prompt,
			Stream:    false,
			MaxTokens: ag.MaxTokens,
		}
		out, err := json.Marshal(oai)
		if err != nil {
			http.Error(w, "failed to marshal OAI request: "+err.Error(), 500)
			return
		}
		log.Printf("body for upstream (%d bytes): %s", len(out), string(out))

		req, err := http.NewRequest("POST", strings.TrimRight(upstream, "/")+"/v1/chat/completions", bytes.NewReader(out))
		if err != nil {
			http.Error(w, "failed to create request: "+err.Error(), 500)
			return
		}
		req.Header.Set("Authorization", "Bearer "+upstreamKey)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			b, err := io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("failed to read error response: %v", err)
				w.WriteHeader(502)
				fmt.Fprintf(w, "upstream returned %d and body read failed", resp.StatusCode)
				return
			}
			log.Printf("upstream %s: %s", resp.Status, string(b))
			w.WriteHeader(resp.StatusCode)
			w.Write(b)
			return
		}

		var oaiResp oaiResponse
		if err := json.NewDecoder(resp.Body).Decode(&oaiResp); err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		text := ""
		if len(oaiResp.Choices) > 0 {
			text = oaiResp.Choices[0].Message.Content
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		flusher, _ := w.(http.Flusher)
		// SSE event types must match what client.zig parses:
		//   text-delta with {type, id, delta} for content
		//   finish with {type, finishReason: {unified: "stop"}} for completion
		fmt.Fprintf(w, "data: %s\n\n", mustJSON(map[string]interface{}{
			"type":  "text-delta",
			"id":    "text",
			"delta": text,
		}))
		fmt.Fprintf(w, "data: %s\n\n", mustJSON(map[string]interface{}{
			"type": "finish",
			"finishReason": map[string]interface{}{
				"unified": "stop",
			},
		}))
		if flusher != nil {
			flusher.Flush()
		}
	})

	log.Printf("ffx-provider-proxy listening on %s → %s (model=%s)", addr, upstream, upstreamModel)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}

func mustJSON(v interface{}) string {
	b, err := json.Marshal(v)
	if err != nil {
		log.Fatalf("failed to marshal JSON: %v", err)
	}
	return string(b)
}
