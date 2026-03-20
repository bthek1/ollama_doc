# Accessing the Ollama AI Model from a Django + DRF + React RAG Project

This guide explains how to wire a **Django / Django REST Framework (DRF)** backend and a **React** frontend to the Ollama instance already running in this stack.

---

## Stack overview

```
React (browser)
    │  fetch / axios  (port 3000 → 8000)
    ▼
Django + DRF  (port 8000)
    │  httpx / ollama-python  (port 8000 → 11434)
    ▼
Ollama container  (127.0.0.1:11434)
    │
    └─ llama3.2 (default model)
```

The Ollama container exposes its REST API on **`http://localhost:11434`** — bound to loopback only (`127.0.0.1`), so only the host machine (and other Docker containers on the same network) can reach it.

---

## 1. Django setup

### 1.1 Install dependencies

```bash
pip install httpx ollama openai   # openai SDK works against Ollama's /v1 endpoint
```

Or with `uv` (as used in this repo):

```bash
uv add httpx ollama openai
```

### 1.2 `settings.py`

```python
# ── Ollama ────────────────────────────────────────────────────────────────
OLLAMA_BASE_URL = "http://localhost:11434"   # same host, loopback
OLLAMA_MODEL    = "llama3.2"
OLLAMA_TIMEOUT  = 120   # seconds — increase for long RAG chains
```

---

## 2. Three ways to call Ollama from Django

### Option A — `ollama` Python SDK (recommended)

The `ollama` package mirrors the REST API and handles streaming natively.

```python
# apps/ai/client.py
import ollama
from django.conf import settings

_client = ollama.Client(host=settings.OLLAMA_BASE_URL)


def chat(messages: list[dict], model: str | None = None) -> str:
    """Send a list of chat messages and return the assistant reply."""
    response = _client.chat(
        model=model or settings.OLLAMA_MODEL,
        messages=messages,
    )
    return response["message"]["content"]


def chat_stream(messages: list[dict], model: str | None = None):
    """Yield text chunks for Server-Sent Events."""
    for chunk in _client.chat(
        model=model or settings.OLLAMA_MODEL,
        messages=messages,
        stream=True,
    ):
        yield chunk["message"]["content"]
```

### Option B — Raw `httpx` (fine-grained control)

```python
# apps/ai/client.py
import httpx
from django.conf import settings


def generate(prompt: str, system: str = "") -> str:
    payload = {
        "model": settings.OLLAMA_MODEL,
        "prompt": prompt,
        "system": system,
        "stream": False,
    }
    with httpx.Client(timeout=settings.OLLAMA_TIMEOUT) as client:
        r = client.post(f"{settings.OLLAMA_BASE_URL}/api/generate", json=payload)
        r.raise_for_status()
        return r.json()["response"]
```

### Option C — OpenAI-compatible endpoint

Ollama exposes a `/v1` endpoint that is fully compatible with the OpenAI Python SDK.

```python
from openai import OpenAI
from django.conf import settings

_openai_client = OpenAI(
    base_url=f"{settings.OLLAMA_BASE_URL}/v1",
    api_key="ollama",   # any non-empty string
)


def chat_openai(messages: list[dict]) -> str:
    response = _openai_client.chat.completions.create(
        model=settings.OLLAMA_MODEL,
        messages=messages,
    )
    return response.choices[0].message.content
```

---

## 3. DRF views

### 3.1 Standard (blocking) chat endpoint

```python
# apps/ai/views.py
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from .client import chat


class ChatView(APIView):
    """POST /api/chat/"""

    def post(self, request):
        messages = request.data.get("messages")
        if not messages or not isinstance(messages, list):
            return Response(
                {"detail": "messages must be a non-empty list."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        reply = chat(messages)
        return Response({"reply": reply})
```

### 3.2 Streaming chat with Server-Sent Events

```python
# apps/ai/views.py
import json
from django.http import StreamingHttpResponse
from rest_framework.decorators import api_view
from .client import chat_stream


@api_view(["POST"])
def chat_stream_view(request):
    """POST /api/chat/stream/  — streams tokens as SSE."""
    messages = request.data.get("messages", [])

    def event_stream():
        for token in chat_stream(messages):
            yield f"data: {json.dumps({'token': token})}\n\n"
        yield "data: [DONE]\n\n"

    response = StreamingHttpResponse(event_stream(), content_type="text/event-stream")
    response["Cache-Control"] = "no-cache"
    response["X-Accel-Buffering"] = "no"   # disable nginx buffering
    return response
```

### 3.3 RAG endpoint (retrieve → augment → generate)

```python
# apps/ai/views.py
from rest_framework.views import APIView
from rest_framework.response import Response
from .client import chat
from .retriever import retrieve_context   # your vector-store lookup


class RagView(APIView):
    """POST /api/rag/"""

    def post(self, request):
        query = request.data.get("query", "")
        if not query:
            return Response({"detail": "query is required."}, status=400)

        # 1. Retrieve relevant chunks from the vector store
        chunks = retrieve_context(query, top_k=5)
        context = "\n\n".join(chunks)

        # 2. Build augmented messages
        messages = [
            {
                "role": "system",
                "content": (
                    "You are a helpful assistant. Use ONLY the following context "
                    "to answer the user's question.\n\n"
                    f"Context:\n{context}"
                ),
            },
            {"role": "user", "content": query},
        ]

        # 3. Generate
        reply = chat(messages)
        return Response({"reply": reply, "sources": chunks})
```

### 3.4 URL wiring

```python
# urls.py
from django.urls import path
from apps.ai.views import ChatView, RagView, chat_stream_view

urlpatterns = [
    path("api/chat/",        ChatView.as_view()),
    path("api/chat/stream/", chat_stream_view),
    path("api/rag/",         RagView.as_view()),
]
```

---

## 4. React frontend

### 4.1 Standard fetch (blocking)

```tsx
// src/hooks/useChat.ts
export async function sendMessage(messages: {role: string; content: string}[]) {
  const res = await fetch("/api/chat/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ messages }),
  });
  if (!res.ok) throw new Error(await res.text());
  const data = await res.json();
  return data.reply as string;
}
```

### 4.2 Streaming with EventSource / ReadableStream

```tsx
// src/hooks/useChatStream.ts
import { useState } from "react";

export function useChatStream() {
  const [reply, setReply] = useState("");
  const [loading, setLoading] = useState(false);

  async function streamChat(messages: {role: string; content: string}[]) {
    setReply("");
    setLoading(true);

    const res = await fetch("/api/chat/stream/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages }),
    });

    const reader = res.body!.getReader();
    const decoder = new TextDecoder();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      const lines = decoder.decode(value).split("\n");
      for (const line of lines) {
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") break;
        try {
          const { token } = JSON.parse(payload);
          setReply(prev => prev + token);
        } catch {
          // ignore malformed chunks
        }
      }
    }
    setLoading(false);
  }

  return { reply, loading, streamChat };
}
```

### 4.3 RAG query component

```tsx
// src/components/RagSearch.tsx
import { useState } from "react";

export function RagSearch() {
  const [query, setQuery]   = useState("");
  const [answer, setAnswer] = useState("");

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const res = await fetch("/api/rag/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const data = await res.json();
    setAnswer(data.reply);
  }

  return (
    <form onSubmit={handleSubmit}>
      <input value={query} onChange={e => setQuery(e.target.value)} />
      <button type="submit">Ask</button>
      {answer && <p>{answer}</p>}
    </form>
  );
}
```

### 4.4 Vite proxy (development)

In `vite.config.ts`, proxy `/api` calls to the Django dev server so you avoid CORS issues:

```ts
// vite.config.ts
export default {
  server: {
    proxy: {
      "/api": {
        target: "http://localhost:8000",
        changeOrigin: true,
      },
    },
  },
};
```

---

## 5. CORS configuration (Django)

```bash
pip install django-cors-headers
```

```python
# settings.py
INSTALLED_APPS = [
    ...
    "corsheaders",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",   # must be first
    ...
]

# Development — allow the Vite dev server
CORS_ALLOWED_ORIGINS = [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
]

# Production — replace with your real domain
# CORS_ALLOWED_ORIGINS = ["https://your-app.example.com"]
```

---

## 6. Environment variables

Store the Ollama URL in `.env` (already loaded by `just` via `set dotenv-load`):

```dotenv
# .env
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.2
DJANGO_SECRET_KEY=change-me-in-production
```

Read them in `settings.py`:

```python
import os

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL    = os.getenv("OLLAMA_MODEL", "llama3.2")
```

---

## 7. Docker networking note

When Django itself runs inside Docker (e.g. a `web` service in the same Compose file), use the **service name** as the hostname instead of `localhost`:

```dotenv
# .env  (Docker variant)
OLLAMA_BASE_URL=http://ollama:11434
```

Because `127.0.0.1:11434` is bound on the *host*, a containerised Django service must reach Ollama via the Docker internal network using the service name `ollama`.

---

## 8. Quick-reference: Ollama REST endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/api/version` | Server health + version |
| `GET`  | `/api/tags` | List downloaded models |
| `POST` | `/api/generate` | Single-turn completion |
| `POST` | `/api/chat` | Multi-turn chat |
| `POST` | `/api/embeddings` | Generate embeddings (RAG indexing) |
| `POST` | `/v1/chat/completions` | OpenAI-compatible chat |
| `POST` | `/v1/embeddings` | OpenAI-compatible embeddings |

---

## 9. Generating embeddings for the vector store

For the retrieval step of RAG, generate embeddings with Ollama and store them in a vector DB (e.g. pgvector, Chroma, Qdrant):

```python
# apps/ai/embeddings.py
import ollama
from django.conf import settings

_client = ollama.Client(host=settings.OLLAMA_BASE_URL)
EMBED_MODEL = "nomic-embed-text"   # pull with: just pull MODEL=nomic-embed-text


def embed(text: str) -> list[float]:
    response = _client.embeddings(model=EMBED_MODEL, prompt=text)
    return response["embedding"]


def embed_batch(texts: list[str]) -> list[list[float]]:
    return [embed(t) for t in texts]
```

Pull the embedding model once:

```bash
just pull MODEL=nomic-embed-text
```

---

## 10. Checklist

- [ ] Ollama container is running: `just status`
- [ ] Model is downloaded: `just models`
- [ ] `OLLAMA_BASE_URL` is set correctly in `.env`
- [ ] Django can reach `http://localhost:11434/api/version` (or `http://ollama:11434` if containerised)
- [ ] `corsheaders` is configured for the React dev origin
- [ ] Vite proxy is set up for `/api` in development
- [ ] Embedding model is pulled if using RAG retrieval
