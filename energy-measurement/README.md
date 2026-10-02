# Energy measurement instrumentation (release 6.0.0)

## Purpose

This directory is not part of the upstream Django repository. It measures the energy of the CI commands of
release `6.0.0` on a controlled bench, using Intel RAPL counters. The measured construct is the energy of the
CI commands on that bench, not the energy of GitHub-hosted CI in production.

## Non-invasiveness

No original project file is created or modified. This branch is the upstream tag `6.0` (36b5f39d9372147f0e758f590e35ee2b2bc317dd) plus one
instrumentation commit that adds this directory and `.github/workflows/energy-measurement.yml`:

```bash
git diff --stat 6.0 release-6.0.0
```

## Measured cell

The job measured in the HEAD campaign of this fork does not exist at this tag. The measured cell is job
`python` of `.github/workflows/python_matrix.yml` at the tag, Linux, CPython 3.14 (the version of that matrix
closest to the HEAD campaign). Upstream runs it on labelled pull requests; here it is dispatched manually.

| stage | commands | upstream step |
|---|---|---|
| `build` | `python -m pip install --upgrade pip setuptools wheel`, then `python -m pip install -r tests/requirements/py3.txt -e .`, in a fresh virtualenv | "Install and upgrade packaging tools" and the unnamed step after it |
| `test` | `python -Wall tests/runtests.py -v2` | "Run tests" |

`setup-python` and the `libmemcached-dev` install happen at image build time. `--parallel` and `--settings`
stay at the upstream defaults (`cpu_count`, `test_sqlite`).

One test fails by design under this interpreter and is declared, so the expected exit of `test` is 1:

```
utils_tests.test_html.TestUtilsHtml.test_strip_tags
```

It depends on the `HTMLParser` of CPython 3.14.1, the 3.14 release that `setup-python` served on the tag
date; nothing is deselected.

## Deviations from the upstream job

- Offline dependencies: every requirement is resolved as of the tag date and pre-built into `/wheelhouse`;
  `pylibmc` and `pywatchman` publish only source distributions for this Python and are compiled into wheels at
  image build time, as the runner's `cache: pip` would hold them. The measured install uses `--no-index`.
- `--network none`: the measured containers have no network; the suite's own servers bind to loopback.
- The interpreter is CPython 3.14.1 from python-build-standalone, installed with `uv`, instead of the
  `actions/python-versions` build.
- uid 1001, as on the hosted runner: some tests assert on file permissions and behave differently as root.

## How to run

From the root of a clone of branch `release-6.0.0` (the Dockerfile copies the tree):

```bash
docker build -t django-measurement-6.0.0 -f energy-measurement/Dockerfile .
bash energy-measurement/run_pipeline.sh 1
gh workflow run energy-measurement.yml --ref release-6.0.0 -f campaign=validation
gh workflow run energy-measurement.yml --ref release-6.0.0 -f campaign=full
```

`validation` runs run 0 only; `full` runs a warm-up, runs 1 to 10 and the medians. A run whose stage exit is
outside the declared list is moved to `runs/discarded_exit_code/` and not counted.

## Output

One CSV per run with the 14 columns of the HEAD campaign: the nine official columns, the unclamped RAM
energy, the in-container wall time, host swap-in and swap-out pages during the stage, and
`cpu_time_cgroup_s`. The package temperature (hwmon `coretemp`, `Package id 0`) is read immediately before
and after each stage's RAPL window, never inside it, into `temp_run_NN_<stage>.txt`. Container flags:
`--rm --privileged --network none --memory=12g --memory-swap=12g`.
