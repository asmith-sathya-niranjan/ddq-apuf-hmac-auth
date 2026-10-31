#!/usr/bin/env python3
"""Regression attack on the exposed DDQ-APUF numerical response (single core).

Insecure baseline: the 13-phase DDQ code (0..13) is visible to the attacker.
The attacker fits a plain linear model to the additive-delay (parity-feature)
representation using least squares, then predicts the response to unseen
challenges.  A prediction is accepted if it is within the tolerance d of the
enrolled response, mirroring the verifier's tolerance in the DDQ-APUF scheme.

Model parameters match ddq_regression_attack_3pxor.py and
secure_ddq_experiment.py (N=32 stages, 30 ps phase step, 8.5 ps noise,
92 ps delay-difference sigma).  Run from the repository root.
"""
import numpy as np

rng = np.random.default_rng(7)
N, DT, NOISE, SIG_DD = 32, 30.0, 8.5, 92.0


def phi(C):
    s = 1 - 2 * C
    f = np.cumprod(s[:, ::-1], axis=1)[:, ::-1]
    return np.hstack([f, np.ones((len(C), 1))])


w = rng.normal(0, SIG_DD / np.sqrt(N + 1), N + 1)


def count(dD):
    return ((dD[:, None] + (np.arange(13) - 6) * DT) > 0).sum(1)


def measure(C):
    return count(phi(C) @ w + rng.normal(0, NOISE, len(C)))


def chal(n):
    return rng.integers(0, 2, (n, N))


Ct = chal(20000)
enrol = measure(Ct)
rem = measure(Ct)
print("legit chip re-measure accepted, |diff|<=3: %.1f%%  (<=1: %.1f%%)"
      % (100 * np.mean(abs(enrol - rem) <= 3), 100 * np.mean(abs(enrol - rem) <= 1)))
print("\nSingle-core DDQ-APUF, attacker = plain linear regression on the exposed code")
print("    CRPs | accepted at tolerance d = 0 / 1 / 2 / 3")
for n in (100, 300, 1000, 3000, 10000):
    C = chal(n)
    y = measure(C)
    wh, *_ = np.linalg.lstsq(phi(C), y.astype(float), rcond=None)
    pred = np.clip(np.rint(phi(Ct) @ wh), 0, 13)
    print("%8d | %s" % (n, " / ".join(
        "%5.1f%%" % (100 * np.mean(abs(pred - enrol) <= d)) for d in (0, 1, 2, 3))))
