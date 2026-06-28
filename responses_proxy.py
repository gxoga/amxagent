#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
"""
Responses API → Chat Completions API proxy for CoAMX.

Translates Responses API (/v1/responses) to Chat Completions API
(/v1/chat/completions) with:
  - True streaming (text deltas emitted in real-time)
  - Text-based <tool_call> XML detection and parsing
  - Proper usage reporting (enables CoAMX auto-compact)
  - Standard error code mapping
  - Model name forwarding via headers

Usage:
    python responses_proxy.py [--port 8001] [--backend http://localhost:8000]
"""

import argparse
import asyncio
import os
import json
import logging
import re
import secrets
import time
import uuid

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
import uvicorn

logger = logging.getLogger("responses_proxy")

app = FastAPI()
BACKEND_URL = "http://localhost:8000"
PROXY_API_KEY = os.environ.get("PROXY_API_KEY", "")
LOG_MODEL_OUTPUT = os.environ.get("AMXAGENT_LOG_MODEL_OUTPUT", "").lower() in {"1", "true", "yes"}

# ---------------------------------------------------------------------------
# Tool call text formats
# ---------------------------------------------------------------------------
# Supported formats (per model family):
#   - Qwen3-Coder-Next:
#       <tool_call><function=NAME><parameter=KEY>VAL</parameter>...</function></tool_call>
#   - Gemma 4:
#       <|tool_call>call:NAME{KEY:<|"|>VAL<|"|>,...}<tool_call|>
#
# Each format is registered as (format_name, open_token, close_token).
# `HOLD_BACK_LEN` is the max open-token length so streaming detection
# never misses a token split across SSE chunks.

QWEN_OPEN = "<tool_call>"
QWEN_CLOSE = "</tool_call>"
GEMMA_OPEN = "<|tool_call>"
GEMMA_CLOSE = "<tool_call|>"

TOOL_CALL_FORMATS = (
    ("qwen", QWEN_OPEN, QWEN_CLOSE),
    ("gemma", GEMMA_OPEN, GEMMA_CLOSE),
)
HOLD_BACK_LEN = max(len(o) for _, o, _ in TOOL_CALL_FORMATS)

_QWEN_TC_RE = re.compile(r'<tool_call>\s*(.*?)\s*</tool_call>', re.DOTALL)
_QWEN_FUNC_RE = re.compile(r'<function=(\w+)>(.*?)</function>', re.DOTALL)
_QWEN_PARAM_RE = re.compile(r'<parameter=(\w+)>(.*?)</parameter>', re.DOTALL)

_GEMMA_TC_RE = re.compile(r'<\|tool_call>\s*(.*?)\s*<tool_call\|>', re.DOTALL)
_GEMMA_FUNC_RE = re.compile(r'call:(\w+)\{(.*)\}\s*$', re.DOTALL)
_GEMMA_PARAM_RE = re.compile(r'(\w+):<\|"\|>(.*?)<\|"\|>', re.DOTALL)

# Early-notification patterns: extract function name from a partial tool-call
# block before the closing token arrives (so CoAMX can show the spinner).
_QWEN_EARLY_FUNC_RE = re.compile(r'<function=(\w+)>')
_GEMMA_EARLY_FUNC_RE = re.compile(r'call:(\w+)\{')

# ---------------------------------------------------------------------------
# Gemma 4 channel ("harmony"-style) markup.
#
# Gemma multiplexes its output into named channels:
#     <|channel>thought<channel|> ... chain-of-thought ...
#     <|channel>final<channel|>   ... user-facing answer + tool calls ...
# The proxy previously knew nothing about channels, so when a reasoning-heavy
# task put content in the `thought` channel (or stopped right after opening it),
# the raw `<|channel>thought<channel|>` markers leaked to the client as the
# assistant message and the real action (the file edit) was lost — the cause of
# the wasted tuning iterations.
#
# We strip the channel delimiters, route REASONING channels to a reasoning buffer
# (logged for debug, NOT sent to the client), and let everything else (final /
# commentary / unnamed) flow to the answer path. Tool-call detection stays active
# in every channel so actions are never hidden.
CHANNEL_OPEN = "<|channel>"
CHANNEL_HDR_CLOSE = "<channel|>"
REASONING_CHANNELS = {"thought", "thinking", "analysis", "reflection", "reasoning"}
_CHANNEL_HDR_RE = re.compile(r'<\|channel>\s*(\w+)\s*<channel\|>')


def split_channels(text: str) -> tuple[str, str]:
    """Split Gemma channel markup into (answer_text, reasoning_text).

    Reasoning-channel content goes to reasoning; final/commentary/unnamed content
    goes to answer. All `<|channel>NAME<channel|>` delimiters are stripped. If the
    text has no channel markup it is returned unchanged as the answer.
    """
    if CHANNEL_OPEN not in text:
        return text, ""
    answer: list[str] = []
    reasoning: list[str] = []
    pos = 0
    current: str | None = None  # None == default/unnamed channel -> answer
    while pos < len(text):
        nxt = text.find(CHANNEL_OPEN, pos)
        seg_end = nxt if nxt >= 0 else len(text)
        seg = text[pos:seg_end]
        (reasoning if current in REASONING_CHANNELS else answer).append(seg)
        if nxt < 0:
            break
        m = _CHANNEL_HDR_RE.match(text, nxt)
        if m:
            current = m.group(1).lower()
            pos = m.end()
        else:
            # malformed/partial header — drop the open token, keep going
            pos = nxt + len(CHANNEL_OPEN)
            current = None
    return "".join(answer).strip(), "".join(reasoning).strip()

# ---------------------------------------------------------------------------
# Gemma 4 tool-call value grammar (recursive).
#
# The flat `KEY:<|"|>VAL<|"|>` regex only handles scalar string params; it
# silently mangles nested args such as update_plan's
#   plan:[{status:<|"|>...<|"|>,step:<|"|>...<|"|>}, ...]
# collapsing the array into the last {status,step} pair. That made codex reject
# the call and the model re-emit update_plan in an endless loop. This parser
# handles strings, arrays, objects, and bare scalars (bool/int/float/null).
#
#   value  := string | array | object | bare
#   string := '<|"|>' ... '<|"|>'   (same token both sides)
#   array  := '[' value (',' value)* ']'
#   object := '{' KEY ':' value (',' KEY ':' value)* '}'
#   bare   := token up to , } ]
# ---------------------------------------------------------------------------
_GEMMA_Q = '<|"|>'
_GEMMA_KEY_RE = re.compile(r'(\w+)\s*:')


def _gemma_skip_ws(s: str, i: int) -> int:
    while i < len(s) and s[i] in ' \n\t':
        i += 1
    return i


def _gemma_parse_value(s: str, i: int):
    i = _gemma_skip_ws(s, i)
    if s.startswith(_GEMMA_Q, i):
        j = s.find(_GEMMA_Q, i + len(_GEMMA_Q))
        if j < 0:
            return s[i + len(_GEMMA_Q):], len(s)
        return s[i + len(_GEMMA_Q):j], j + len(_GEMMA_Q)
    if i < len(s) and s[i] == '[':
        arr = []
        i += 1
        while i < len(s):
            i = _gemma_skip_ws(s, i)
            if i < len(s) and s[i] == ',':
                i += 1
                continue
            if i < len(s) and s[i] == ']':
                return arr, i + 1
            v, i = _gemma_parse_value(s, i)
            arr.append(v)
        return arr, i
    if i < len(s) and s[i] == '{':
        return _gemma_parse_object(s, i + 1, closing='}')
    j = i
    while j < len(s) and s[j] not in ',}]':
        j += 1
    tok = s[i:j].strip()
    if tok == 'true':
        return True, j
    if tok == 'false':
        return False, j
    if tok == 'null':
        return None, j
    try:
        return int(tok), j
    except ValueError:
        pass
    try:
        return float(tok), j
    except ValueError:
        pass
    return tok, j


def _gemma_parse_object(s: str, i: int, closing=None):
    obj = {}
    while i < len(s):
        i = _gemma_skip_ws(s, i)
        if i < len(s) and s[i] == ',':
            i += 1
            continue
        if closing and i < len(s) and s[i] == closing:
            return obj, i + 1
        if i >= len(s):
            break
        m = _GEMMA_KEY_RE.match(s, i)
        if not m:
            break
        key = m.group(1)
        i = m.end()
        v, i = _gemma_parse_value(s, i)
        obj[key] = v
    return obj, i


def parse_gemma_args(objbody: str) -> dict:
    """Parse a brace-less Gemma object body (the args) into a dict."""
    obj, _ = _gemma_parse_object(objbody, 0, closing=None)
    return obj


# ---------------------------------------------------------------------------
# Input conversion: Responses API → Chat Completions API
# ---------------------------------------------------------------------------

def convert_input_to_messages(instructions: str, input_items: list) -> list[dict]:
    """Convert Responses API input items to Chat Completions messages."""
    messages = []
    if instructions:
        messages.append({"role": "system", "content": instructions})

    for item in input_items:
        item_type = item.get("type", "")

        if item_type == "message":
            role = item.get("role", "user")
            content_items = item.get("content", [])
            text_parts = []
            for c in content_items:
                ct = c.get("type", "")
                if ct in ("input_text", "output_text"):
                    text_parts.append(c.get("text", ""))
                elif ct == "input_image":
                    pass  # skip images for now
            if text_parts:
                messages.append({"role": role, "content": "\n".join(text_parts)})

        elif item_type == "function_call":
            messages.append({
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": item.get("call_id", f"call_{uuid.uuid4().hex[:8]}"),
                    "type": "function",
                    "function": {
                        "name": item.get("name", ""),
                        "arguments": item.get("arguments", "{}"),
                    }
                }]
            })

        elif item_type == "function_call_output":
            messages.append({
                "role": "tool",
                "tool_call_id": item.get("call_id", ""),
                "content": _extract_output(item.get("output", "")),
            })

        elif item_type == "custom_tool_call":
            messages.append({
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": item.get("call_id", f"call_{uuid.uuid4().hex[:8]}"),
                    "type": "function",
                    "function": {
                        "name": item.get("name", ""),
                        "arguments": item.get("input", "{}"),
                    }
                }]
            })

        elif item_type == "custom_tool_call_output":
            messages.append({
                "role": "tool",
                "tool_call_id": item.get("call_id", ""),
                "content": _extract_output(item.get("output", "")),
            })

    return messages


def _extract_output(output) -> str:
    """Extract text from function call output payload."""
    if isinstance(output, str):
        return output
    if isinstance(output, dict):
        if "content" in output:
            return str(output["content"])
        if "content_items" in output:
            parts = []
            for ci in output["content_items"]:
                if isinstance(ci, dict) and "text" in ci:
                    parts.append(ci["text"])
            return "\n".join(parts)
    return str(output)


def convert_tools(tools: list) -> list[dict]:
    """Convert Responses API tools to Chat Completions tools format."""
    cc_tools = []
    for tool in tools:
        tool_type = tool.get("type", "")
        if tool_type == "function":
            cc_tools.append({
                "type": "function",
                "function": {
                    "name": tool.get("name", ""),
                    "description": tool.get("description", ""),
                    "parameters": tool.get("parameters", {}),
                }
            })
    return cc_tools


# ---------------------------------------------------------------------------
# Text-based tool call parsing (Qwen XML + Gemma 4 templated)
# ---------------------------------------------------------------------------

def _parse_qwen_block(body: str) -> dict | None:
    """Parse the content inside <tool_call>...</tool_call> into a call dict."""
    func_match = _QWEN_FUNC_RE.search(body)
    if not func_match:
        return None
    params = {}
    for pm in _QWEN_PARAM_RE.finditer(func_match.group(2)):
        params[pm.group(1)] = pm.group(2).strip()
    return {
        "id": f"call_{uuid.uuid4().hex[:8]}",
        "name": func_match.group(1),
        "arguments": json.dumps(params, ensure_ascii=False),
    }


def _parse_gemma_block(body: str) -> dict | None:
    """Parse the content inside <|tool_call>...<tool_call|> into a call dict."""
    func_match = _GEMMA_FUNC_RE.search(body)
    if not func_match:
        return None
    params = parse_gemma_args(func_match.group(2))
    return {
        "id": f"call_{uuid.uuid4().hex[:8]}",
        "name": func_match.group(1),
        "arguments": json.dumps(params, ensure_ascii=False),
    }


def _parse_block(fmt: str, body: str) -> dict | None:
    """Dispatch a tool-call block to the right parser."""
    if fmt == "qwen":
        return _parse_qwen_block(body)
    if fmt == "gemma":
        return _parse_gemma_block(body)
    return None


def parse_text_tool_calls(text: str) -> tuple[str, list[dict]]:
    """Parse Qwen or Gemma 4 tool-call markup from model text into structured calls.

    Returns (remaining_text, list_of_tool_calls).  Both formats are stripped
    from the remaining text.
    """
    tool_calls = []
    remaining = text

    for tc_match in _QWEN_TC_RE.finditer(text):
        call = _parse_qwen_block(tc_match.group(1))
        if call:
            tool_calls.append(call)
    for tc_match in _GEMMA_TC_RE.finditer(text):
        call = _parse_gemma_block(tc_match.group(1))
        if call:
            tool_calls.append(call)

    if tool_calls:
        remaining = _QWEN_TC_RE.sub('', remaining)
        remaining = _GEMMA_TC_RE.sub('', remaining)
        remaining = remaining.strip()

    return remaining, tool_calls


def _find_next_open(text: str, start: int) -> tuple[int, str | None, str | None]:
    """Find the earliest tool-call open token (any format) at/after `start`.

    Returns (position, format_name, close_token) or (-1, None, None) if none.
    """
    best_pos = -1
    best_fmt = None
    best_close = None
    for fmt, open_tok, close_tok in TOOL_CALL_FORMATS:
        p = text.find(open_tok, start)
        if p >= 0 and (best_pos < 0 or p < best_pos):
            best_pos = p
            best_fmt = fmt
            best_close = close_tok
    return best_pos, best_fmt, best_close


def _early_function_name(fmt: str, partial: str) -> str | None:
    """Try to extract the function name from a partial (still-open) tool-call block."""
    if fmt == "qwen":
        m = _QWEN_EARLY_FUNC_RE.search(partial)
    elif fmt == "gemma":
        m = _GEMMA_EARLY_FUNC_RE.search(partial)
    else:
        return None
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# SSE helpers
# ---------------------------------------------------------------------------

def _sse(event_type: str, data: dict) -> str:
    """Format a Server-Sent Event."""
    return f"event: {event_type}\ndata: {json.dumps(data)}\n\n"


def _make_usage(input_tokens: int, output_tokens: int) -> dict:
    """Build a Responses API usage object."""
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens_details": {"reasoning_tokens": 0},
        "total_tokens": input_tokens + output_tokens,
    }


def _map_error_code(status_code: int, error_body: str) -> str:
    """Map backend HTTP status/body to standard OpenAI error code."""
    body_lower = error_body.lower()
    if status_code == 429:
        return "rate_limit_exceeded"
    if status_code == 503:
        return "server_is_overloaded"
    if "context length" in body_lower or "too long" in body_lower:
        return "context_length_exceeded"
    if "invalid" in body_lower and "prompt" in body_lower:
        return "invalid_prompt"
    return "server_error"


def _auth_required() -> bool:
    return bool(PROXY_API_KEY)


def _extract_bearer_token(request: Request) -> str:
    auth = request.headers.get("Authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return auth


def _is_authorized(request: Request) -> bool:
    if not _auth_required():
        return True
    token = _extract_bearer_token(request)
    return bool(token) and secrets.compare_digest(token, PROXY_API_KEY)


def _auth_error_response(response_id: str) -> JSONResponse:
    return JSONResponse(status_code=401, content={
        "id": response_id,
        "status": "failed",
        "error": {
            "code": "invalid_api_key",
            "message": "Missing or invalid local proxy API key.",
        },
    })


# ---------------------------------------------------------------------------
# Streaming: Chat Completions SSE → Responses API SSE (true streaming)
# ---------------------------------------------------------------------------

async def stream_chat_as_responses(response_id: str, model: str, backend_response, t_start=None):
    """Convert Chat Completions SSE stream to Responses API SSE.

    Text deltas are emitted in real-time with an 11-char hold-back buffer
    for <tool_call> XML detection.  Structured tool_calls from the API are
    accumulated and emitted after the text stream completes.
    """
    # --- response.created (with model in headers) ---
    yield _sse("response.created", {
        "type": "response.created",
        "response": {
            "id": response_id,
            "status": "in_progress",
            "headers": {"openai-model": model},
        }
    })

    # Inference-timing instrumentation (TTFT + total + decode tok/s)
    # t_start is passed in from before the backend request is dispatched so that
    # TTFT captures prefill: SGLang only sends HTTP 200 headers once the first
    # token is ready, so timing from inside this generator would miss prefill.
    if t_start is None:
        t_start = time.monotonic()
    t_first_token = None

    # Text streaming state
    text_buffer = ""          # All text received so far
    emitted_up_to = 0        # Index into text_buffer up to which we've emitted
    emitted_clean_text = ""   # Accumulated clean text sent as deltas
    in_tool_call = False      # Currently inside a tool_call block
    tc_start_pos = -1         # Start of current tool_call in buffer
    tc_format = None          # "qwen" or "gemma" — set when open token detected
    tc_close_token = None     # Close token for the active format
    message_item_started = False

    # Channel state (Gemma harmony markup). current_channel == None -> answer path.
    current_channel = None
    reasoning_text = ""       # accumulated reasoning-channel content (logged, not sent)

    # Structured API tool calls (accumulated)
    api_tool_calls = {}       # index → {id, name, arguments}

    # Text-based tool calls (parsed from XML)
    text_tool_calls = []

    # Early notification: track whether we've sent output_item.added for current tool call
    tc_early_notified = False
    tc_early_id = None
    early_notified_ids = set()  # IDs already sent as output_item.added
    message_done_emitted = False  # True after output_item.done sent for message

    # Usage
    input_tokens = 0
    output_tokens = 0
    finish_reason = None

    # Heartbeat: track last time we sent data to CoAMX
    last_emit_time = time.monotonic()

    def _emit_seg(seg):
        """Route a plain-text segment by current_channel: answer channels stream to
        the client as output_text; reasoning channels are buffered + logged (not
        sent), with a periodic heartbeat so the connection stays alive while the
        model thinks silently."""
        nonlocal message_item_started, emitted_clean_text, reasoning_text, last_emit_time
        if not seg:
            return
        if current_channel in REASONING_CHANNELS:
            reasoning_text += seg
            now = time.monotonic()
            if now - last_emit_time >= 2.0:
                yield ": heartbeat\n\n"
                last_emit_time = now
            return
        if not message_item_started:
            yield _sse("response.output_item.added", {
                "type": "response.output_item.added",
                "item": {"type": "message", "role": "assistant", "content": []}
            })
            message_item_started = True
        yield _sse("response.output_text.delta", {
            "type": "response.output_text.delta",
            "delta": seg,
        })
        emitted_clean_text += seg
        last_emit_time = time.monotonic()

    # --- Process backend SSE chunks ---
    async for line in backend_response.aiter_lines():
        line = line.strip()
        if not line:
            continue
        if not line.startswith("data: "):
            continue
        data_str = line[6:]
        if data_str == "[DONE]":
            break

        try:
            chunk = json.loads(data_str)
        except json.JSONDecodeError:
            continue

        # Extract usage from final chunk (stream_options.include_usage)
        if "usage" in chunk and chunk["usage"]:
            usage = chunk["usage"]
            input_tokens = usage.get("prompt_tokens", 0)
            output_tokens = usage.get("completion_tokens", 0)

        choices = chunk.get("choices", [])
        if not choices:
            continue

        choice = choices[0]
        delta = choice.get("delta", {})
        finish_reason = choice.get("finish_reason") or finish_reason

        # ---- Text content with real-time streaming + tool call detection ----
        content = delta.get("content")
        if content:
            if t_first_token is None:
                t_first_token = time.monotonic()
            text_buffer += content

            # Process buffer (loop handles multiple tool calls in one chunk
            # and text appearing after a closed tool call)
            processing = True
            while processing:
                processing = False

                if not in_tool_call:
                    # Earliest control token: a channel header or a tool-call open.
                    ch_pos = text_buffer.find(CHANNEL_OPEN, emitted_up_to)
                    tc_pos, fmt, close_tok = _find_next_open(text_buffer, emitted_up_to)
                    use_channel = ch_pos >= 0 and (tc_pos < 0 or ch_pos <= tc_pos)

                    if use_channel:
                        # emit text before the header (routed by current channel),
                        # then consume the <|channel>NAME<channel|> marker itself
                        for s in _emit_seg(text_buffer[emitted_up_to:ch_pos]):
                            yield s
                        emitted_up_to = ch_pos
                        m = _CHANNEL_HDR_RE.match(text_buffer, ch_pos)
                        if m:
                            current_channel = m.group(1).lower()
                            emitted_up_to = m.end()
                            processing = True
                        elif text_buffer.find(CHANNEL_HDR_CLOSE, ch_pos) >= 0:
                            # close token present but header malformed — drop open token
                            emitted_up_to = ch_pos + len(CHANNEL_OPEN)
                            processing = True
                        # else: header split across chunks — wait for the next chunk
                    elif tc_pos >= 0:
                        # tool-call open token found — emit text before it, enter buffer mode
                        for s in _emit_seg(text_buffer[emitted_up_to:tc_pos]):
                            yield s
                        emitted_up_to = tc_pos
                        in_tool_call = True
                        tc_start_pos = tc_pos
                        tc_format = fmt
                        tc_close_token = close_tok
                        # Immediately close the message with phase=commentary
                        # so CoAMX restores the spinner right away
                        if message_item_started:
                            msg_item = {
                                "type": "message",
                                "role": "assistant",
                                "content": [{"type": "output_text", "text": emitted_clean_text}]
                                           if emitted_clean_text.strip() else [],
                                "phase": "commentary",
                            }
                            yield _sse("response.output_item.done", {
                                "type": "response.output_item.done",
                                "item": msg_item,
                            })
                            message_done_emitted = True
                        processing = True
                    else:
                        # No control token — stream safe text (hold back last N chars)
                        safe_end = max(emitted_up_to, len(text_buffer) - HOLD_BACK_LEN)
                        for s in _emit_seg(text_buffer[emitted_up_to:safe_end]):
                            yield s
                        emitted_up_to = safe_end

                if in_tool_call:
                    end_pos = text_buffer.find(tc_close_token, tc_start_pos)
                    if end_pos >= 0:
                        end_pos += len(tc_close_token)
                        tc_block = text_buffer[tc_start_pos:end_pos]
                        _, parsed = parse_text_tool_calls(tc_block)
                        # Use the early-notified ID if we sent one
                        if tc_early_notified and parsed and tc_early_id:
                            parsed[0]["id"] = tc_early_id
                        text_tool_calls.extend(parsed)
                        emitted_up_to = end_pos
                        in_tool_call = False
                        tc_start_pos = -1
                        tc_format = None
                        tc_close_token = None
                        if tc_early_id:
                            early_notified_ids.add(tc_early_id)
                        tc_early_notified = False
                        tc_early_id = None
                        processing = True  # continue to process text after tool call
                    else:
                        # Detect function name early and notify CoAMX immediately
                        if not tc_early_notified:
                            partial = text_buffer[tc_start_pos:]
                            func_name = _early_function_name(tc_format, partial)
                            if func_name:
                                tc_early_id = f"call_{uuid.uuid4().hex[:8]}"
                                logger.info(f"Early notify function_call: {func_name}")
                                yield _sse("response.output_item.added", {
                                    "type": "response.output_item.added",
                                    "item": {
                                        "type": "function_call",
                                        "name": func_name,
                                        "call_id": tc_early_id,
                                        "arguments": "",
                                    }
                                })
                                last_emit_time = time.monotonic()
                                tc_early_notified = True
                        # Send heartbeat every 2s to keep connection alive
                        now = time.monotonic()
                        if now - last_emit_time >= 2.0:
                            yield ": heartbeat\n\n"
                            last_emit_time = now

        # ---- Structured tool calls from API ----
        tc_list = delta.get("tool_calls") or []
        for tc in tc_list:
            idx = tc.get("index", 0)
            if idx not in api_tool_calls:
                api_tool_calls[idx] = {
                    "id": tc.get("id", f"call_{uuid.uuid4().hex[:8]}"),
                    "name": "",
                    "arguments": "",
                }
            if "function" in tc:
                fn = tc["function"]
                if "name" in fn and fn["name"]:
                    api_tool_calls[idx]["name"] = fn["name"]
                if "arguments" in fn:
                    api_tool_calls[idx]["arguments"] += fn["arguments"]

    # --- Stream ended: flush remaining buffer ---
    if in_tool_call:
        # Unclosed <tool_call> — treat as plain text
        in_tool_call = False
        tc_start_pos = -1

    remaining = text_buffer[emitted_up_to:]
    if remaining:
        # Attribute the tail to the right channel(s). Anything before the first
        # channel marker belongs to the channel we were in; the rest is split.
        if CHANNEL_OPEN in remaining:
            cut = remaining.find(CHANNEL_OPEN)
            lead, rest = remaining[:cut], remaining[cut:]
            tail_ans, tail_rea = split_channels(rest)
            reasoning_text += tail_rea
            if current_channel in REASONING_CHANNELS:
                reasoning_text += lead
                ans = tail_ans
            else:
                ans = lead + tail_ans
        elif current_channel in REASONING_CHANNELS:
            reasoning_text += remaining
            ans = ""
        else:
            ans = remaining

        if ans.strip():
            clean_remaining, extra_tcs = parse_text_tool_calls(ans)
            text_tool_calls.extend(extra_tcs)
            # defensive: never let a stray channel marker reach the client
            clean_remaining = _CHANNEL_HDR_RE.sub("", clean_remaining)
            clean_remaining = clean_remaining.replace(CHANNEL_OPEN, "").replace(CHANNEL_HDR_CLOSE, "").strip()
            if clean_remaining:
                if not message_item_started:
                    yield _sse("response.output_item.added", {
                        "type": "response.output_item.added",
                        "item": {"type": "message", "role": "assistant", "content": []}
                    })
                    message_item_started = True
                yield _sse("response.output_text.delta", {
                    "type": "response.output_text.delta",
                    "delta": clean_remaining,
                })
                emitted_clean_text += clean_remaining

    if reasoning_text.strip():
        if LOG_MODEL_OUTPUT:
            logger.info("[gemma-reasoning %s] %d chars\n%s",
                        response_id, len(reasoning_text), reasoning_text)
        else:
            logger.info("[gemma-reasoning %s] %d chars suppressed",
                        response_id, len(reasoning_text))

    # --- Emit output_item.done for message ---
    # Combine all tool calls for phase decision
    all_tool_calls = text_tool_calls[:]
    for idx in sorted(api_tool_calls.keys()):
        all_tool_calls.append(api_tool_calls[idx])

    if message_item_started and not message_done_emitted:
        msg_item = {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": emitted_clean_text}]
                       if emitted_clean_text.strip() else [],
        }
        # If tool calls follow, mark text as "commentary" so CoAMX restores
        # the spinner between the text output and tool execution.
        if all_tool_calls:
            msg_item["phase"] = "commentary"
        yield _sse("response.output_item.done", {
            "type": "response.output_item.done",
            "item": msg_item,
        })

    # --- Emit function_call items ---
    for tc in all_tool_calls:
        tc_id = tc["id"]
        logger.info(f"Emitting function_call: {tc['name']}")
        # Skip .added if we already sent it as early notification
        if tc_id not in early_notified_ids:
            yield _sse("response.output_item.added", {
                "type": "response.output_item.added",
                "item": {
                    "type": "function_call",
                    "name": tc["name"],
                    "call_id": tc_id,
                    "arguments": tc["arguments"],
                }
            })
        yield _sse("response.output_item.done", {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call",
                "call_id": tc_id,
                "name": tc["name"],
                "arguments": tc["arguments"],
            }
        })

    # --- response.completed with usage ---
    yield _sse("response.completed", {
        "type": "response.completed",
        "response": {
            "id": response_id,
            "status": "completed",
            "output": [],
            "usage": _make_usage(input_tokens, output_tokens),
        }
    })

    # --- inference performance summary (one line per LLM call) ---
    t_end = time.monotonic()
    total = t_end - t_start
    ttft = (t_first_token - t_start) if t_first_token else total
    gen = (t_end - t_first_token) if t_first_token else 0.0
    decode_tps = (output_tokens / gen) if gen > 0 and output_tokens else 0.0
    prefill_tps = (input_tokens / ttft) if ttft > 0 and input_tokens else 0.0
    itl_ms = (gen / output_tokens * 1000) if output_tokens else 0.0
    logger.info(
        "[perf %s] ttft=%.2fs gen=%.2fs total=%.2fs prompt=%d completion=%d "
        "decode=%.1f tok/s prefill=%.0f tok/s itl=%.1f ms tools=%d",
        response_id, ttft, gen, total, input_tokens, output_tokens,
        decode_tps, prefill_tps, itl_ms, len(all_tool_calls),
    )


# ---------------------------------------------------------------------------
# Endpoint: /v1/responses
# ---------------------------------------------------------------------------

@app.post("/v1/responses")
async def responses_endpoint(request: Request):
    response_id = f"resp_{uuid.uuid4().hex[:24]}"
    if not _is_authorized(request):
        return _auth_error_response(response_id)

    body = await request.json()

    instructions = body.get("instructions", "")
    raw_input = body.get("input", [])
    model = body.get("model", "")
    tools = body.get("tools", [])
    stream = body.get("stream", True)

    # Responses API accepts string or list for input
    if isinstance(raw_input, str):
        input_items = [{"type": "message", "role": "user",
                        "content": [{"type": "input_text", "text": raw_input}]}]
    else:
        input_items = raw_input

    messages = convert_input_to_messages(instructions, input_items)
    cc_tools = convert_tools(tools)

    cc_request = {
        "model": model,
        "messages": messages,
        "stream": stream,
    }

    # [Fix #1] Request usage in streaming responses (needed for auto-compact)
    if stream:
        cc_request["stream_options"] = {"include_usage": True}

    # Forward optional parameters with safe defaults for CPU inference
    cc_request["max_tokens"] = body.get("max_output_tokens") or 4096
    cc_request["temperature"] = body.get("temperature") or 0.6
    if "top_p" in body and body["top_p"] is not None:
        cc_request["top_p"] = body["top_p"]

    # Forward tools if present
    if cc_tools:
        cc_request["tools"] = cc_tools
        cc_request["tool_choice"] = body.get("tool_choice", "auto")

    logger.info(f"Request: model={model}, msgs={len(messages)}, tools={len(cc_tools)}, stream={stream}")

    # ---- Non-streaming path ----
    if not stream:
        async with httpx.AsyncClient(timeout=300.0) as client:
            resp = await client.post(
                f"{BACKEND_URL}/v1/chat/completions",
                json=cc_request,
            )
            if resp.status_code != 200:
                error_body = resp.text[:500]
                error_code = _map_error_code(resp.status_code, error_body)
                return {
                    "id": response_id,
                    "status": "failed",
                    "error": {"code": error_code, "message": error_body},
                }

            data = resp.json()
            message = data.get("choices", [{}])[0].get("message", {})
            content = message.get("content", "")
            raw_tool_calls = message.get("tool_calls") or []

            output_items = []

            # Strip Gemma channel markup: keep only the answer channel, log reasoning.
            content, _reasoning = split_channels(content)
            if _reasoning.strip():
                if LOG_MODEL_OUTPUT:
                    logger.info("[gemma-reasoning %s] %d chars\n%s",
                                response_id, len(_reasoning), _reasoning)
                else:
                    logger.info("[gemma-reasoning %s] %d chars suppressed",
                                response_id, len(_reasoning))

            # Parse text-based tool calls
            remaining_text, text_tool_calls = parse_text_tool_calls(content)
            if remaining_text:
                output_items.append({
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": remaining_text}],
                })

            # Structured API tool calls
            for tc in raw_tool_calls:
                fn = tc.get("function", {})
                output_items.append({
                    "type": "function_call",
                    "call_id": tc.get("id", f"call_{uuid.uuid4().hex[:8]}"),
                    "name": fn.get("name", ""),
                    "arguments": fn.get("arguments", "{}"),
                })

            # Text-parsed tool calls
            for tc in text_tool_calls:
                output_items.append({
                    "type": "function_call",
                    "call_id": tc["id"],
                    "name": tc["name"],
                    "arguments": tc["arguments"],
                })

            # [Fix #2] Include usage in non-streaming response
            backend_usage = data.get("usage", {})
            return {
                "id": response_id,
                "output": output_items,
                "usage": _make_usage(
                    backend_usage.get("prompt_tokens", 0),
                    backend_usage.get("completion_tokens", 0),
                ),
            }

    # ---- Streaming path ----
    async def generate():
        async with httpx.AsyncClient(timeout=300.0) as client:
            # Start the inference clock before dispatch so TTFT includes prefill.
            t_req_start = time.monotonic()
            async with client.stream(
                "POST",
                f"{BACKEND_URL}/v1/chat/completions",
                json=cc_request,
            ) as resp:
                if resp.status_code != 200:
                    error_body = await resp.aread()
                    error_text = error_body.decode()[:500]
                    error_code = _map_error_code(resp.status_code, error_text)
                    logger.error(f"Backend returned {resp.status_code}: {error_text}")
                    yield _sse("response.failed", {
                        "type": "response.failed",
                        "response": {
                            "id": response_id,
                            "error": {"code": error_code, "message": error_text}
                        }
                    })
                    return
                async for chunk in stream_chat_as_responses(response_id, model, resp, t_start=t_req_start):
                    yield chunk

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
            # [Fix #7] Forward model name in HTTP headers
            "openai-model": model,
        },
    )


# ---------------------------------------------------------------------------
# Pass-through for other /v1/* endpoints (e.g. /v1/models)
# ---------------------------------------------------------------------------

@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def proxy_passthrough(request: Request, path: str):
    if not _is_authorized(request):
        return _auth_error_response(f"resp_{uuid.uuid4().hex[:24]}")

    async with httpx.AsyncClient(timeout=300.0) as client:
        resp = await client.request(
            method=request.method,
            url=f"{BACKEND_URL}/v1/{path}",
            headers={k: v for k, v in request.headers.items() if k.lower() not in {"host", "authorization"}},
            content=await request.body(),
        )
        return StreamingResponse(
            content=iter([resp.content]),
            status_code=resp.status_code,
            headers=dict(resp.headers),
        )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Responses API proxy for CoAMX")
    parser.add_argument("--port", type=int, default=8001)
    parser.add_argument("--host", type=str, default="127.0.0.1",
                        help="bind address (default 127.0.0.1; same-node only)")
    parser.add_argument("--backend", type=str, default="http://localhost:8000")
    args = parser.parse_args()

    BACKEND_URL = args.backend

    logging.basicConfig(level=logging.INFO)
    if _auth_required():
        logger.info("Proxy auth enabled.")
    else:
        logger.warning("Proxy auth disabled. This is only safe on a fully isolated host.")
    logger.info(f"Starting proxy on {args.host}:{args.port}, backend: {BACKEND_URL}")
    logger.info(f"CoAMX → {args.host}:{args.port}/v1/responses → {BACKEND_URL}/v1/chat/completions")

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
