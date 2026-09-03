"""Credential redaction for the intent tier (FR-031, SC-016).

FR-031: credentials and secrets MUST be redacted from every prompt, log,
trace, and chat transcript. This module is the single source of the
credential pattern definitions (T106) and of the redaction applied to
prompts and model responses (T107). ``config/logging_config.py`` (T108)
imports the same patterns so the log path cannot drift from the prompt
path; ``common/audit.py`` redacts every audit record through
:func:`redact` before it leaves the process.

Pattern discipline (mirrors the subject's filter, corrected): each entry
is ``(pattern, replacement)`` where the pattern captures the *label* half
of a credential-shaped token in group 1 (and, where the secret is
separated from the label by ``@``, group 2 after the secret). The
replacement keeps the label so logs stay diagnosable and replaces only
the secret half with ``***REDACTED***``.
"""

from __future__ import annotations

import re

# ---------------------------------------------------------------------------
# T106 — credential pattern definitions.
#
# Every pattern is matched case-insensitively against the text to be
# redacted. Order matters only in that more specific patterns come first
# (e.g. URL-embedded credentials before the generic password forms).
#
# The label-preserving replacements (``password=***REDACTED***``) carry the
# label half, so the same pattern would re-match the redacted output and
# an SC-016 scanner re-checking redacted artifacts would never come back
# clean. Every value half therefore carries a negative lookahead for the
# marker: already-redacted values are left alone (idempotence) and
# :func:`contains_credential` returns False on redacted text.
# ---------------------------------------------------------------------------
_REDACTED_MARKER = "***REDACTED***"
_NOT_MARKER = r"(?!\*{3}REDACTED\*{3})"

CREDENTIAL_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # PEM private-key blocks, if one is ever pasted into a prompt or echoed
    # by a model. Replaced whole: there is no label half to keep.
    (
        re.compile(
            r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"
        ),
        "***REDACTED-PEM***",
    ),
    # URL-embedded credentials (scheme://user:pass@host) — the password
    # half is replaced, the user and host are kept.
    (
        re.compile(r"(://[^:/@\s]+:)" + _NOT_MARKER + r"[^@\s]+(@)"),
        r"\1***REDACTED***\2",
    ),
    # AWS access key ids (AKIA... / ASIA...) anywhere.
    (
        re.compile(r"\b((?:AKIA|ASIA)[0-9A-Z]{16})\b"),
        "***REDACTED***",
    ),
    # OpenAI-style / generic LLM provider API keys (sk-..., key-...).
    (
        re.compile(r"\b((?:sk|pk|pk_live|sk_live|key)-[A-Za-z0-9_\-]{16,})\b"),
        "***REDACTED***",
    ),
    # SLIM gateway password (Secret/slim-gateway key PASSWORD) and the
    # password=/password:/PASSWORD: literal forms (ClickHouse, gNMI, KUID).
    (
        re.compile(r"(?i)(\b(?:password|passwd|pwd)\s*[=:]\s*)" + _NOT_MARKER + r"\S+"),
        r"\1***REDACTED***",
    ),
    # LLM provider API key (Secret/llm-provider) and generic api_key forms.
    (
        re.compile(
            r"(?i)((?:api[_\-]?key|apikey)\s*[=:]\s*)" + _NOT_MARKER + r"\S+"
        ),
        r"\1***REDACTED***",
    ),
    # Bearer tokens anywhere (KUID API, model provider, SLIM, cluster SA).
    (
        re.compile(r"(?i)(\bbearer\s+)" + _NOT_MARKER + r"\S+"),
        r"\1***REDACTED***",
    ),
    # Authorization header values in any scheme.
    (
        re.compile(r"(?i)((?:authorization|proxy-authorization)\s*[=:]\s*)" + _NOT_MARKER + r"\S+"),
        r"\1***REDACTED***",
    ),
    # Token= literals (transport tokens, KUID tokens).
    (
        re.compile(r"(?i)(\btoken\s*[=:]\s*)" + _NOT_MARKER + r"\S+"),
        r"\1***REDACTED***",
    ),
    # JWS/JWT-shaped material (three base64url segments).
    (
        re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"),
        "***REDACTED***",
    ),
]


def redact(text: str) -> str:
    """T107 — apply every credential pattern to ``text``.

    Used for prompts (before they reach a model or are stored for
    SC-016 review) and for model responses (before they are logged,
    audited, or streamed to the operator). Idempotent: a second pass
    changes nothing.
    """
    if not text:
        return text
    redacted = text
    for pattern, replacement in CREDENTIAL_PATTERNS:
        redacted = pattern.sub(replacement, redacted)
    return redacted


def redact_prompt(text: str) -> str:
    """T107 — redaction applied to a prompt before model use / storage.

    Distinct name (not an alias) so call sites state which side of the
    model they are on; FR-031 covers both sides with the same rules.
    """
    return redact(text)


def redact_model_response(text: str) -> str:
    """T107 — redaction applied to a model response before any use.

    A model that echoes a credential back (repeating the operator's
    prompt) is scrubbed here, before the response is stored in state,
    logged, audited, or streamed.
    """
    return redact(text)


def contains_credential(text: str) -> bool:
    """True when any credential pattern still matches ``text``.

    The SC-016 / T134 scanners use this on every recovered artifact
    (trace attributes, log lines, transcripts) to prove zero credentials
    survived redaction.
    """
    if not text:
        return False
    return any(pattern.search(text) for pattern, _ in CREDENTIAL_PATTERNS)


def redaction_marker() -> str:
    """The literal marker a redacted secret is replaced with."""
    return _REDACTED_MARKER
