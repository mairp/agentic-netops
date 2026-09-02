"""LLM provider selection — ported from the subject's ``common/llm.py``.

Provider selection is by the ``LLM_MODEL`` prefix alone (research.md Decision
1, NFR-003 / SC-015): switching providers is a Secret/env change
(``LLM_MODEL=openai/...`` | ``anthropic/...`` | ``azure/...`` ...), not a code
change. The special ``oauth2/`` prefix routes through the OAuth2
client-credentials shim instead of a static API key.
"""

from __future__ import annotations

import logging

from langchain_litellm import ChatLiteLLM
from common.metrics import get_metrics
from common.redaction import redact_prompt, redact_model_response
from opentelemetry import trace

import common.chat_lite_llm_shim as chat_lite_llm_shim  # our drop-in client
from config.config import LLM_MODEL

logger = logging.getLogger(__name__)


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
            # Model usage and cost metrics (T328)
            model_name = getattr(llm, "model", "unknown")
            usage = getattr(res, "usage", None) or {}
            tokens_in = int(usage.get("prompt_tokens", 0) or 0)
            tokens_out = int(usage.get("completion_tokens", 0) or 0)
            cost = float(getattr(res, "cost", 0.0) or 0.0)
            metrics.model_call(model=model_name, tokens_in=tokens_in, tokens_out=tokens_out, cost_usd=cost)
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

    if callable(orig_ainvoke):
        llm.ainvoke = _wrapped_ainvoke  # type: ignore[assignment]
    if callable(orig_invoke):
        llm.invoke = _wrapped_invoke  # type: ignore[assignment]
    return llm
