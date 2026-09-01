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
    if LLM_MODEL.startswith("oauth2/"):
        llm.client = chat_lite_llm_shim
    return llm
