#!/usr/bin/env python3
"""Separate controlled-DDQ security experiment.

This keeps the submitted RTL and attack scripts unchanged.  It compares:

1. The original interface, where a numerical DDQ code is directly exposed.
2. A controlled interface, where a stable hidden PUF measurement reconstructs
   a key and the external response is a nonce-bound HMAC tag.

The controlled design is a protocol proof of concept, not an RTL implementation
of a fuzzy extractor or a claim of measured FPGA entropy.
"""

from __future__ import annotations

import csv
import hashlib
import hmac
import json
from pathlib import Path

import numpy as np


OUT_DIR = Path(__file__).resolve().parent / "results"
OUT_DIR.mkdir(parents=True, exist_ok=True)

N = 32
DT_PS = 30.0
NOISE_PS = 8.5
SIGMA_DD_PS = 92.0
TAG_BITS = 64
TEST_SIZE = 20_000
TRAIN_SIZES = (100, 300, 1_000, 3_000, 10_000)


def phi(challenges: np.ndarray) -> np.ndarray:
    signs = 1 - 2 * challenges
    features = np.cumprod(signs[:, ::-1], axis=1)[:, ::-1]
    return np.hstack([features, np.ones((len(challenges), 1))])


def ddq_measure(challenges: np.ndarray, weights: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    delta = phi(challenges) @ weights + rng.normal(0, NOISE_PS, len(challenges))
    phases = np.arange(13)
    return (delta[:, None] + (phases - 6) * DT_PS > 0).sum(axis=1)


def pack_rows(bits: np.ndarray) -> list[bytes]:
    return [bytes(np.packbits(row, bitorder="big")) for row in bits.astype(np.uint8)]


def u64_bytes(values: np.ndarray) -> list[bytes]:
    return [int(value).to_bytes(8, "big", signed=False) for value in values]


def tags(key: bytes, challenges: np.ndarray, nonces: np.ndarray) -> np.ndarray:
    challenge_bytes = pack_rows(challenges)
    nonce_bytes = u64_bytes(nonces)
    tag_bytes = TAG_BITS // 8
    result = np.empty((len(challenges), TAG_BITS), dtype=np.uint8)
    for index, (challenge, nonce) in enumerate(zip(challenge_bytes, nonce_bytes)):
        digest = hmac.new(key, challenge + nonce, hashlib.sha256).digest()[:tag_bytes]
        result[index] = np.unpackbits(np.frombuffer(digest, dtype=np.uint8), bitorder="big")
    return result


def linear_features(challenges: np.ndarray, nonces: np.ndarray) -> np.ndarray:
    nonce_bits = np.unpackbits(nonces.astype(">u8").view(np.uint8), bitorder="big").reshape(-1, 64)
    raw = np.hstack([challenges, nonce_bits])
    return np.hstack([1 - 2 * raw, np.ones((len(raw), 1))])


def derive_root_key(
    weights: np.ndarray,
    hidden_challenges: np.ndarray,
    rng: np.random.Generator,
    sample_count: int,
) -> tuple[bytes, np.ndarray]:
    margins = phi(hidden_challenges) @ weights
    noisy = margins[None, :] + rng.normal(0, NOISE_PS, (sample_count, len(hidden_challenges)))
    bits = (np.sum(noisy > 0, axis=0) > sample_count // 2).astype(np.uint8)
    return hashlib.sha256(np.packbits(bits, bitorder="big").tobytes()).digest(), bits


def main() -> None:
    rng_chip = np.random.default_rng(20261015)
    weights = rng_chip.normal(0, SIGMA_DD_PS / np.sqrt(N + 1), N + 1)

    # ------------------------------------------------------------------
    # Baseline: raw numerical DDQ code exposed to least-squares attack.
    # ------------------------------------------------------------------
    rng_base = np.random.default_rng(1001)
    test_challenges = rng_base.integers(0, 2, (TEST_SIZE, N), dtype=np.int8)
    enrollment = ddq_measure(test_challenges, weights, rng_base)
    baseline_rows = []
    for training_size in TRAIN_SIZES:
        train_challenges = rng_base.integers(0, 2, (training_size, N), dtype=np.int8)
        train_codes = ddq_measure(train_challenges, weights, rng_base)
        learned, *_ = np.linalg.lstsq(phi(train_challenges), train_codes.astype(float), rcond=None)
        predicted = np.clip(np.rint(phi(test_challenges) @ learned), 0, 13)
        absolute_error = np.abs(predicted - enrollment)
        baseline_rows.append(
            {
                "training_crps": training_size,
                "accept_d0_pct": float(100 * np.mean(absolute_error <= 0)),
                "accept_d1_pct": float(100 * np.mean(absolute_error <= 1)),
                "accept_d2_pct": float(100 * np.mean(absolute_error <= 2)),
                "accept_d3_pct": float(100 * np.mean(absolute_error <= 3)),
                "mae": float(np.mean(absolute_error)),
                "rmse": float(np.sqrt(np.mean(absolute_error**2))),
            }
        )

    # ------------------------------------------------------------------
    # Controlled design: select stable, hidden root-PUF measurements.
    # In hardware this role requires a proper fuzzy extractor/ECC block.
    # ------------------------------------------------------------------
    rng_root = np.random.default_rng(2002)
    candidate_challenges = rng_root.integers(0, 2, (8192, N), dtype=np.int8)
    candidate_margins = phi(candidate_challenges) @ weights
    enrollment_samples = candidate_margins[None, :] + rng_root.normal(
        0, NOISE_PS, (31, len(candidate_challenges))
    )
    enrollment_votes = np.sum(enrollment_samples > 0, axis=0)
    stability_score = np.abs(enrollment_votes - 15.5)
    selected = np.argsort(stability_score)[-256:]
    hidden_challenges = candidate_challenges[selected]

    enrollment_key, enrollment_bits = derive_root_key(
        weights, hidden_challenges, rng_root, sample_count=31
    )

    boot_trials = 1_000
    successful_key_reconstructions = 0
    total_root_bit_errors = 0
    worst_root_bit_errors = 0
    for _ in range(boot_trials):
        boot_key, boot_bits = derive_root_key(weights, hidden_challenges, rng_root, sample_count=15)
        bit_errors = int(np.sum(boot_bits != enrollment_bits))
        total_root_bit_errors += bit_errors
        worst_root_bit_errors = max(worst_root_bit_errors, bit_errors)
        successful_key_reconstructions += int(boot_key == enrollment_key)

    root_ber = total_root_bit_errors / (boot_trials * len(enrollment_bits))
    key_reconstruction_pct = 100 * successful_key_reconstructions / boot_trials

    # Fixed test set for every attack training size.
    rng_secure = np.random.default_rng(3003)
    secure_test_challenges = rng_secure.integers(0, 2, (TEST_SIZE, N), dtype=np.int8)
    secure_test_nonces = rng_secure.integers(0, np.iinfo(np.uint64).max, TEST_SIZE, dtype=np.uint64)
    secure_test_tags = tags(enrollment_key, secure_test_challenges, secure_test_nonces)
    secure_test_features = linear_features(secure_test_challenges, secure_test_nonces)

    secure_rows = []
    for training_size in TRAIN_SIZES:
        train_challenges = rng_secure.integers(0, 2, (training_size, N), dtype=np.int8)
        train_nonces = rng_secure.integers(0, np.iinfo(np.uint64).max, training_size, dtype=np.uint64)
        train_tags = tags(enrollment_key, train_challenges, train_nonces)
        train_features = linear_features(train_challenges, train_nonces)

        # Same attack family as the raw-code script, now applied bitwise to
        # the actual externally visible authentication tag.
        learned, *_ = np.linalg.lstsq(train_features, train_tags.astype(float), rcond=None)
        predicted_bits = (secure_test_features @ learned >= 0.5).astype(np.uint8)
        bit_accuracy = 100 * np.mean(predicted_bits == secure_test_tags)
        exact_tags = np.all(predicted_bits == secure_test_tags, axis=1)
        secure_rows.append(
            {
                "training_crps": training_size,
                "attacker_bit_accuracy_pct": float(bit_accuracy),
                "attacker_exact_tag_success_pct": float(100 * np.mean(exact_tags)),
                "successful_full_tag_forgeries": int(np.sum(exact_tags)),
                "test_attempts": TEST_SIZE,
            }
        )

    # Replay a valid tag with a different nonce. A nonce-aware verifier must
    # recompute the tag for the new nonce and reject the old one.
    fresh_nonces = secure_test_nonces + np.uint64(1)
    expected_fresh_tags = tags(enrollment_key, secure_test_challenges, fresh_nonces)
    replay_success = np.all(secure_test_tags == expected_fresh_tags, axis=1)

    summary = {
        "configuration": {
            "stages": N,
            "test_crps": TEST_SIZE,
            "tag_bits": TAG_BITS,
            "noise_ps": NOISE_PS,
            "hidden_root_bits": len(enrollment_bits),
            "root_enrollment_samples": 31,
            "root_boot_samples": 15,
        },
        "legitimate": {
            "root_bit_error_rate_pct": float(100 * root_ber),
            "exact_key_reconstruction_pct": float(key_reconstruction_pct),
            "worst_root_bit_errors_in_one_boot": worst_root_bit_errors,
            "authentication_success_pct": float(key_reconstruction_pct),
        },
        "replay": {
            "successful_replays": int(np.sum(replay_success)),
            "attempts": TEST_SIZE,
            "success_pct": float(100 * np.mean(replay_success)),
        },
        "baseline_raw_ddq": baseline_rows,
        "controlled_hmac": secure_rows,
        "theoretical_random_full_tag_success": 2.0 ** (-TAG_BITS),
        "limitations": [
            "Simulation only; no FPGA placement, routing, voltage, temperature, aging, or side-channel effects.",
            "Stable-bit selection is a stand-in for a proper fuzzy extractor and error-correcting code.",
            "The entropy of the reconstructed root key is assumed, not measured on hardware.",
            "Only the supplied least-squares attack family is compared in this run.",
            "Security depends on blocking raw PUF/debug access and protecting the reconstructed key.",
        ],
    }

    with (OUT_DIR / "secure_ddq_results.json").open("w") as handle:
        json.dump(summary, handle, indent=2)

    with (OUT_DIR / "baseline_raw_ddq.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=baseline_rows[0].keys())
        writer.writeheader()
        writer.writerows(baseline_rows)

    with (OUT_DIR / "controlled_hmac_attack.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=secure_rows[0].keys())
        writer.writeheader()
        writer.writerows(secure_rows)

    report_lines = [
        "CONTROLLED DDQ SECURITY EXPERIMENT",
        "==================================",
        f"Root-bit BER: {100 * root_ber:.6f}%",
        f"Exact key reconstruction: {key_reconstruction_pct:.3f}% ({successful_key_reconstructions}/{boot_trials})",
        f"Replay success with a fresh nonce: {100 * np.mean(replay_success):.6f}% ({int(np.sum(replay_success))}/{TEST_SIZE})",
        "",
        "Raw numerical DDQ response exposed:",
        "CRPs     d=0       d=1       d=2       d=3       MAE      RMSE",
    ]
    for row in baseline_rows:
        report_lines.append(
            f"{row['training_crps']:5d}  {row['accept_d0_pct']:8.3f}  {row['accept_d1_pct']:8.3f}  "
            f"{row['accept_d2_pct']:8.3f}  {row['accept_d3_pct']:8.3f}  {row['mae']:7.3f}  {row['rmse']:7.3f}"
        )
    report_lines.extend(
        [
            "",
            f"Controlled interface, {TAG_BITS}-bit HMAC tag:",
            "CRPs     bit accuracy    exact-tag success    exact forgeries",
        ]
    )
    for row in secure_rows:
        report_lines.append(
            f"{row['training_crps']:5d}  {row['attacker_bit_accuracy_pct']:12.3f}%  "
            f"{row['attacker_exact_tag_success_pct']:16.6f}%  {row['successful_full_tag_forgeries']:15d}"
        )
    report_lines.extend(
        [
            "",
            f"Ideal random full-tag probability per attempt: 2^-{TAG_BITS} = {2.0 ** (-TAG_BITS):.3e}",
            "This result demonstrates the wrapper in this simulation; it is not a hardware security certification.",
        ]
    )
    report = "\n".join(report_lines) + "\n"
    (OUT_DIR / "secure_ddq_report.txt").write_text(report)
    print(report)


if __name__ == "__main__":
    main()
