#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Zachary Jenkins
#
# Regression test harness for the physics engine. Runnable under conda env
# 'devenv' (pure stdlib — no third-party imports, so it also runs bare).
#
#   ./run_tests            # convenience wrapper (activates devenv, calls this)
#   python3 regression.py  # direct
#
# What it does:
#   1. builds the engine (make -C ../src) and the three pure-Fortran asserts
#   2. runs each Fortran assert (nonzero exit == FAIL)
#   3. runs 'flightsim F16regression.json' (short trim + linearization + 2-step sim)
#   4. diffs the exported A/B CSVs against tests/golden/ at rel 1e-8
#   5. checks the trim residual converged and matches golden
#
# Regenerate goldens (only from trusted output) with:  python3 regression.py --bless

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "src"))
OBJ = os.path.join(SRC, "obj")
BIN = os.path.join(SRC, "bin", "flightsim")
GOLDEN = os.path.join(HERE, "golden")
WORK = os.path.join(HERE, "_work")

CONFIG = "F16regression.json"
PREFIX = "F16reg"           # output_prefix in the config
CSV_RTOL = 1.0e-8           # relative tolerance for A/B matrix entries
CSV_ATOL = 1.0e-10          # absolute floor so exact-zero entries compare cleanly
RESID_RTOL = 1.0e-3         # residual sits near the solver tolerance floor (1e-14),
RESID_ATOL = 1.0e-12        # so compare with a generous band; the hard gate is
                            # "converged below solver tolerance" (checked separately)
SOLVER_TOL = 1.0e-14        # matches the config's trim solver tolerance

FASSERTS = ["test_inertia_rotate", "test_quat_euler", "test_atmosphere"]

# Fortran flags mirror the engine build (all reals double via -fdefault-real-8).
FFLAGS = ["-fdefault-real-8", "-ffree-line-length-512", "-I", OBJ]
# objects the asserts link against (already built by the engine build)
ASSERT_OBJS = [os.path.join(OBJ, o) for o in
               ("constants_m.o", "math_m.o", "atmosphere_m.o")]

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def fc():
    return os.environ.get("GFORTRAN", "gfortran")


def build_engine():
    r = run(["make", "-C", SRC])
    if r.returncode != 0:
        print(r.stdout)
        fail("engine build (make -C src) failed")
    ok("engine build")


def build_and_run_asserts():
    for t in FASSERTS:
        exe = os.path.join(WORK, t)
        src = os.path.join(HERE, t + ".f90")
        r = run([fc(), *FFLAGS, "-o", exe, src, *ASSERT_OBJS])
        if r.returncode != 0:
            print(r.stdout)
            fail(f"compile {t}")
            continue
        r = run([exe])
        print("  " + r.stdout.strip())
        if r.returncode != 0:
            fail(f"{t} asserted")
        ok(t)


def parse_matrix_csv(path):
    """Parse a labeled matrix CSV -> (row_labels, col_labels, list-of-rows-of-floats)."""
    with open(path) as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip() != ""]
    col_labels = [c.strip() for c in lines[0].split(",")][1:]
    row_labels, rows = [], []
    for ln in lines[1:]:
        cells = ln.split(",")
        row_labels.append(cells[0].strip())
        rows.append([float(c) for c in cells[1:]])
    return row_labels, col_labels, rows


def diff_matrix(name, got_path, gold_path):
    gr, gc, gv = parse_matrix_csv(got_path)
    rr, rc, rv = parse_matrix_csv(gold_path)
    if gr != rr or gc != rc:
        fail(f"{name}: labels differ from golden")
    worst = 0.0
    for i in range(len(gv)):
        for j in range(len(gv[i])):
            a, b = gv[i][j], rv[i][j]
            denom = max(abs(b), CSV_ATOL)
            rel = abs(a - b) / denom
            if rel > worst:
                worst = rel
            if abs(a - b) > CSV_ATOL and rel > CSV_RTOL:
                fail(f"{name}: [{gr[i]},{gc[j]}] got {a:.12e} golden {b:.12e} "
                     f"(rel {rel:.2e} > {CSV_RTOL:.0e})")
    ok(f"{name} matches golden (worst rel {worst:.2e})")


def extract_trim_residual(stdout):
    """The trim solver prints 'iter  eps_max' lines; the last one is the
    converged residual."""
    resid = None
    for m in re.finditer(r"^\s*(\d+)\s+([0-9.]+E[+-]?\d+)\s*$", stdout, re.M):
        resid = float(m.group(2))
    if "Trim converged successfully" not in stdout:
        fail("trim did not report convergence")
    if resid is None:
        fail("could not parse trim residual from output")
    return resid


def run_regression():
    # clean stale outputs
    for suffix in ("_A.csv", "_B.csv"):
        p = os.path.join(WORK, PREFIX + suffix)
        if os.path.exists(p):
            os.remove(p)
    r = run([BIN, os.path.join(HERE, CONFIG)], cwd=WORK)
    if r.returncode != 0:
        print(r.stdout)
        fail("flightsim run failed")
    return r.stdout


def bless(stdout):
    """Regenerate golden files from the current (trusted) run."""
    os.makedirs(GOLDEN, exist_ok=True)
    for suffix in ("_A.csv", "_B.csv"):
        shutil.copy(os.path.join(WORK, PREFIX + suffix),
                    os.path.join(GOLDEN, PREFIX + suffix))
    resid = extract_trim_residual(stdout)
    with open(os.path.join(GOLDEN, "trim_residual.txt"), "w") as f:
        f.write(f"{resid:.10E}\n")
    print(f"{GREEN}blessed{RESET} goldens (residual {resid:.4e})")


N_FAIL = 0


def ok(msg):
    print(f"  {GREEN}PASS{RESET} {msg}")


def fail(msg):
    global N_FAIL
    N_FAIL += 1
    print(f"  {RED}FAIL{RESET} {msg}")


def main():
    do_bless = "--bless" in sys.argv

    os.makedirs(WORK, exist_ok=True)

    print("== building engine ==")
    build_engine()

    print("== pure-Fortran asserts ==")
    build_and_run_asserts()

    print("== regression run (trim + linearization) ==")
    stdout = run_regression()

    if do_bless:
        bless(stdout)
        return 0

    resid = extract_trim_residual(stdout)
    if resid > SOLVER_TOL * 10:
        fail(f"trim residual {resid:.3e} above solver tolerance floor")
    else:
        ok(f"trim converged (residual {resid:.3e} <= solver tol band)")

    gold_resid_path = os.path.join(GOLDEN, "trim_residual.txt")
    if os.path.exists(gold_resid_path):
        with open(gold_resid_path) as f:
            gold_resid = float(f.read().strip())
        if abs(resid - gold_resid) <= RESID_ATOL + RESID_RTOL * abs(gold_resid):
            ok(f"trim residual matches golden ({resid:.3e} vs {gold_resid:.3e})")
        else:
            fail(f"trim residual {resid:.3e} drifted from golden {gold_resid:.3e}")

    diff_matrix("A matrix", os.path.join(WORK, PREFIX + "_A.csv"),
                os.path.join(GOLDEN, PREFIX + "_A.csv"))
    diff_matrix("B matrix", os.path.join(WORK, PREFIX + "_B.csv"),
                os.path.join(GOLDEN, PREFIX + "_B.csv"))

    print()
    if N_FAIL == 0:
        print(f"{GREEN}ALL TESTS PASSED{RESET}")
        return 0
    print(f"{RED}{N_FAIL} TEST(S) FAILED{RESET}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
