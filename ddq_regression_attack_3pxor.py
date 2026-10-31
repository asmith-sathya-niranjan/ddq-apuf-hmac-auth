import numpy as np
rng = np.random.default_rng(7)
N, DT, NOISE, SIG_DD = 32, 30.0, 8.5, 92.0
def phi(C):
    s = 1 - 2*C; f = np.cumprod(s[:, ::-1], axis=1)[:, ::-1]
    return np.hstack([f, np.ones((len(C), 1))])
W = [rng.normal(0, SIG_DD/np.sqrt(N+1), N+1) for _ in range(3)]
def count(dD):  return ((dD[:, None] + (np.arange(13)-6)*DT) > 0).sum(1)
def measure3(C):                      # same challenge to 3 cores, average of the three counts (paper eq. 15-16)
    P = phi(C)
    return sum(count(P@w + rng.normal(0, NOISE, len(C))) for w in W) / 3.0
def chal(n): return rng.integers(0, 2, (n, N))
Ct = chal(20000); enrol = measure3(Ct); rem = measure3(Ct)
print("legit chip re-measure accepted, |diff|<=3: %.1f%%  (<=1: %.1f%%)" % (100*np.mean(abs(enrol-rem)<=3), 100*np.mean(abs(enrol-rem)<=1)))
print("\n3PXOR DDQ-APUF, attacker = plain linear regression on the averaged code")
print("    CRPs | accepted at tolerance d = 0 / 1 / 2 / 3")
for n in (100, 300, 1000, 3000, 10000):
    C = chal(n); y = measure3(C)
    wh, *_ = np.linalg.lstsq(phi(C), y, rcond=None)
    pred = np.clip(phi(Ct)@wh, 0, 13)
    print("%8d | %s" % (n, " / ".join("%5.1f%%" % (100*np.mean(abs(pred-enrol) <= d)) for d in (0,1,2,3))))
