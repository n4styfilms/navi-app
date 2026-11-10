"""Validate the result written by the synthetic iOS friends fixture."""

import json

MAX_RESULT_BYTES = 65_536


def validate_result(payload, nonce, source, specification):
    if len(payload) > MAX_RESULT_BYTES:
        raise ValueError('Native proof result exceeds the size limit')
    result = json.loads(payload)
    if not isinstance(result, dict) or result.get('nonce') != nonce or result.get('source') != source:
        raise ValueError('Native proof result does not match this launch and source')
    if result.get('status') != 'passed':
        raise ValueError('Native proof fixture reported failure')
    expected = specification['cases'] + specification['extra']
    observed = result.get('proofs')
    if (not isinstance(observed, list) or any(not isinstance(flag, str) for flag in observed)
            or len(observed) != len(expected) or set(observed) != set(expected)):
        raise ValueError('Native proof result is missing, duplicating or adding cases')
    return expected
