# logging_config.py — ported from the subject's ``config/logging_config.py``,
# extended with the credential-redaction wiring (T064 / FR-031 / SC-016).

from __future__ import annotations

import logging
import re

from config.config import LOGGING_LEVEL

# ---------------------------------------------------------------------------
# Credential redaction (FR-031: no credential appears in logs or traces;
# SC-016 reconciles that). The subject's setup_logging() is kept intact
# (same level, format, noisy-library dampening); on top of it a
# RedactingFilter is wired onto the root handlers so every formatted record
# is scrubbed before it leaves the process.
# ---------------------------------------------------------------------------

# Patterns matched against the formatted log line; the secret half is
# replaced, the label half is kept so logs stay diagnosable.
_REDACTION_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # SLIM gateway password (Secret/slim-gateway key PASSWORD)
    (re.compile(r"(?i)(PASSWORD\s*[=:]\s*)\S+"), r"\1***REDACTED***"),
    # LLM provider API key (Secret/llm-provider) and generic api_key forms
    (re.compile(r"(?i)((?:api[_-]?key|apikey|authorization)\s*[=:]\s*(?:Bearer\s+)?)\S+"), r"\1***REDACTED***"),
    # Bearer tokens anywhere (KUID API, model provider, SLIM)
    (re.compile(r"(?i)(Bearer\s+)\S+"), r"\1***REDACTED***"),
    # URL-embedded credentials (scheme://user:pass@host)
    (re.compile(r"(://[^:/@\s]+:)[^@\s]+(@)"), r"\1***REDACTED***\2"),
    # PEM blocks, if one is ever logged by accident
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"), "***REDACTED-PEM***"),
    # ClickHouse / gNMI style password= literals
    (re.compile(r"(?i)(password=)\S+"), r"\1***REDACTED***"),
]


class RedactingFilter(logging.Filter):
    """Scrub credential-shaped values from every formatted record.

    Applied at the handler level via :func:`setup_logging`, so it covers the
    tier's own loggers and the noisy third-party ones alike (a third-party
    library logging an Authorization header cannot leak it).
    """

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - a broken record must not break logging
            return True
        redacted = message
        for pattern, replacement in _REDACTION_PATTERNS:
            redacted = pattern.sub(replacement, redacted)
        if redacted != message:
            record.msg = redacted
            record.args = ()
        return True


def setup_logging() -> None:
    logging.basicConfig(
        level=LOGGING_LEVEL,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        force=True,
    )

    # Wire the redaction filter onto every existing and future root handler
    # (T064): FR-031/SC-016 hold for whatever a dependency logs.
    for handler in logging.getLogger().handlers:
        if not any(isinstance(f, RedactingFilter) for f in handler.filters):
            handler.addFilter(RedactingFilter())

    # Set specific logging levels for noisy libraries
    logging.basicConfig(level=logging.INFO)  # default
    logging.getLogger("openai").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)
