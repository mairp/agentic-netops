from __future__ import annotations

import pytest

from supervisors.provisioning.main import _responsible_stage_from_reason


@pytest.mark.parametrize(
    "reason, expected",
    [
        ("mapper payload out of contract: missing tenant", "mapper"),
        ("allocator payload out of contract: invalid rd/rt", "allocator"),
        ("deployer payload out of contract: dry-run failed", "deployer"),
    ],
)
def test_stage_failure_attribution(reason: str, expected: str):
    assert _responsible_stage_from_reason(reason) == expected
