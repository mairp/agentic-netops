"""LLM provider selection — ported from the subject's ``common/llm.py``.

Provider selection is by the ``LLM_MODEL`` prefix alone (research.md Decision
1, NFR-003 / SC-015): switching providers is a Secret/env change
("LLM_MODEL=openai/..." | "anthropic/..." | "azure/..." ...), not a code
change. The special ``oauth2/`` prefix routes through the OAuth2
client-credentials shim instead of a static API key.

Phase 10 (T414/T415): Per-conversation token budget enforced by conversation
thread id (LangGraph ``configurable.thread_id``), NOT by the Python OS thread.
The current conversation thread id is carried via a ContextVar and must be set
by the caller (the supervisor graph) before invoking the model. When the
configured budget (``AINETOPS_LLM_TOKENS_PER_THREAD``) is exceeded for the
active thread id, subsequent calls raise ``RuntimeError('token-budget-exceeded: bounded exit')``.
"""

from __future__ import annotations

import logging
import os
import contextvars
from typing import Optional

from langchain_litellm import ChatLiteLLM
from common.metrics import get_metrics
from common.redaction import redact_prompt, redact_model_response
from opentelemetry import trace

import common.chat_lite_llm_shim as chat_lite_llm_shim  # our drop-in client
from config.config import LLM_MODEL

logger = logging.getLogger(__name__)


# Positive integer → enforce per-thread (conversation) budget; 0 disables (no-op)
_TOK_BUDGET = int(os.getenv("AINETOPS_LLM_TOKENS_PER_THREAD", "0") or 0)

# ContextVar carrying the LangGraph conversation thread id (configurable.thread_id)
_THREAD_CTX: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "ainetops_conversation_thread_id", default=None
)

# Per-thread-id token usage ledger (prompt + completion tokens)
# This is a simple in-process counter keyed by conversation thread id.
_token_usage: dict[str, int] = {}


def set_current_thread_id(thread_id: Optional[str]) -> None:
    """Set the current conversation thread id for token accounting (T414).

    The supervisor graph must call this with the active ``thread_id`` from
    its ``RunnableConfig.configurable.thread_id`` before any model call.
    """
    try:
        _THREAD_CTX.set(thread_id)
    except Exception:  # defensive: a bad context should not crash callers
        pass


def _current_thread_id() -> Optional[str]:
    try:
        return _THREAD_CTX.get()
    except Exception:
        return None


def _get_token_count() -> int:
    tid = _current_thread_id()
    if not tid:
        return 0
    return int(_token_usage.get(tid, 0))


def _add_tokens(n: int) -> None:
    if _TOK_BUDGET <= 0:
        return
    tid = _current_thread_id()
    if not tid:
        return
    _token_usage[tid] = int(_token_usage.get(tid, 0)) + max(0, int(n))


def reset_token_budget(thread_id: Optional[str] = None) -> None:
    """Reset the counted tokens for the given (or current) conversation thread id."""
    tid = thread_id if thread_id is not None else _current_thread_id()
    if not tid:
        return
    _token_usage[tid] = 0


def get_llm(streaming: bool = True):

    """Get the LLM provider based on the configuration using ChatLiteLLM.

    Args:
        streaming: Whether to enable streaming mode. Set to False for
            structured outputs.
    """
    llm = ChatLiteLLM(model=LLM_MODEL, streaming=streaming)
    # Record prompt text and model identity on the active span (T333, T334)
    try:
        span = trace.get_current_span()
        if span is not None and hasattr(span, "set_attribute"):
            span.set_attribute("ainetops.prompt.redacted", redact_prompt(""))
            span.set_attribute("ainetops.model.id", LLM_MODEL)
    except Exception:
        pass
    if LLM_MODEL.startswith("oauth2/"):
        llm.client = chat_lite_llm_shim

    # Attach a simple post-call hook to record model identity, token usage, and cost metrics.
    metrics = get_metrics()

    orig_ainvoke = getattr(llm, "ainvoke", None)
    orig_invoke = getattr(llm, "invoke", None)

    async def _wrapped_ainvoke(*args, **kwargs):  # type: ignore[override]
        # Record prompt and model identity on the current span (T333, T334)
        try:
            span = trace.get_current_span()
            if span is not None and hasattr(span, "set_attribute"):
                prompt_text = ""
                if args:
                    try:
                        prompt_text = str(args[0])[:2000]
                    except Exception:
                        prompt_text = ""
                span.set_attribute("ainetops.prompt.redacted", redact_prompt(prompt_text))
                span.set_attribute("ainetops.model.id", LLM_MODEL)
        except Exception:
            pass
        res = await orig_ainvoke(*args, **kwargs)
        try:
            # Model usage and cost metrics (T328) + token budget accounting (T414)
            model_name = getattr(llm, "model", "unknown")
            usage = getattr(res, "usage", None) or {}
            tokens_in = int(usage.get("prompt_tokens", 0) or 0)
            tokens_out = int(usage.get("completion_tokens", 0) or 0)
            cost = float(getattr(res, "cost", 0.0) or 0.0)
            metrics.model_call(model=model_name, tokens_in=tokens_in, tokens_out=tokens_out, cost_usd=cost)
            # Update per-thread token budget
            if _TOK_BUDGET > 0:
                _add_tokens(tokens_in + tokens_out)
            # Record redacted response on the span (T335)
            span = trace.get_current_span()
            if span is not None and hasattr(span, "set_attribute"):
                try:
                    text_out = getattr(res, "content", None)
                    if text_out is None:
                        text_out = str(res)
                    text_out = str(text_out)[:2000]
                except Exception:
                    text_out = ""
                span.set_attribute("ainetops.response.redacted", redact_model_response(text_out))
        except Exception:
            pass
        return res

    def _wrapped_invoke(*args, **kwargs):  # type: ignore[override]
        # Record prompt and model identity on the current span (T333, T334)
        try:
            span = trace.get_current_span()
            if span is not None and hasattr(span, "set_attribute"):
                prompt_text = ""
                if args:
                    try:
                        prompt_text = str(args[0])[:2000]
                    except Exception:
                        prompt_text = ""
                span.set_attribute("ainetops.prompt.redacted", redact_prompt(prompt_text))
                span.set_attribute("ainetops.model.id", LLM_MODEL)
        except Exception:
            pass
        res = orig_invoke(*args, **kwargs)
        try:
            model_name = getattr(llm, "model", "unknown")
            usage = getattr(res, "usage", None) or {}
            tokens_in = int(usage.get("prompt_tokens", 0) or 0)
            tokens_out = int(usage.get("completion_tokens", 0) or 0)
            cost = float(getattr(res, "cost", 0.0) or 0.0)
            metrics.model_call(model=model_name, tokens_in=tokens_in, tokens_out=tokens_out, cost_usd=cost)
            if _TOK_BUDGET > 0:
                _add_tokens(tokens_in + tokens_out)
            # Record redacted response on the span (T335)
            span = trace.get_current_span()
            if span is not None and hasattr(span, "set_attribute"):
                try:
                    text_out = getattr(res, "content", None)
                    if text_out is None:
                        text_out = str(res)
                    text_out = str(text_out)[:2000]
                except Exception:
                    text_out = ""
                span.set_attribute("ainetops.response.redacted", redact_model_response(text_out))
        except Exception:
            pass
        return res

    # Bounded exit behavior when token budget is exceeded (T415)
    def _maybe_refuse_on_budget():
        if _TOK_BUDGET <= 0:
            return
        used = _get_token_count()
        if used > _TOK_BUDGET:
            # Reset this conversation's counter to avoid repeated triggers for the same thread id
            reset_token_budget()
            raise RuntimeError("token-budget-exceeded: bounded exit")

    if callable(orig_ainvoke):
        async def _ainvoke_guard(*args, **kwargs):
            _maybe_refuse_on_budget()
            return await _wrapped_ainvoke(*args, **kwargs)
        llm.ainvoke = _ainvoke_guard  # type: ignore[assignment]
    if callable(orig_invoke):
        def _invoke_guard(*args, **kwargs):
            _maybe_refuse_on_budget()
            return _wrapped_invoke(*args, **kwargs)
        llm.invoke = _invoke_guard  # type: ignore[assignment]
    return llm
