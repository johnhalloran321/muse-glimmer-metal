#!/usr/bin/env bash
# Smoke tests against a running start-server.sh instance.
set -euo pipefail
HOST="${1:-http://127.0.0.1:8080}"

echo "==> Health check"
curl -sf -m 10 "$HOST/health"
echo

echo "==> Plain chat completion"
curl -s -m 60 "$HOST/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello in exactly 5 words."}], "max_tokens": 40}' \
  | python3 -m json.tool

echo "==> Tool-calling (confirms the model's native XML tool-call format is being"
echo "    parsed into structured OpenAI-style tool_calls via the embedded Jinja template)"
curl -s -m 60 "$HOST/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "What is the weather in Boston right now?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {"type": "object", "properties": {"location": {"type": "string"}}, "required": ["location"]}
      }
    }],
    "max_tokens": 150
  }' | python3 -m json.tool
