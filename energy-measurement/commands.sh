#!/usr/bin/env bash
# Measured commands for django 5.2.0 (tag 5.2, 9e7cc2b628fe8fd3895986af9b7fc9525034c1b0), run inside the container.
# Usage: bash /medicao/commands.sh <build|test>
#
# Literal transcription of job `python` of .github/workflows/python_matrix.yml at the tag,
# Linux leg with Python 3.13. Cut at step boundaries:
#   Set up Python 3.13                                      -> image build time
#   Install libmemcached-dev for pylibmc                     -> image build time
#   python -m pip install --upgrade pip setuptools wheel     -> build
#   python -m pip install -r tests/requirements/py3.txt -e . -> build
#   python -Wall tests/runtests.py -v2                       -> test
# --parallel and --settings are left at the upstream defaults (cpu_count, test_sqlite).

set -uo pipefail
STAGE="${1:?Stage required: build | test}"

cd /project
export PIP_NO_INDEX=1 PIP_FIND_LINKS=/wheelhouse

case "$STAGE" in

  build)
    # Fresh venv so the stage performs a real installation, as a clean runner does.
    python -m venv /tmp/venv_build || exit $?
    /tmp/venv_build/bin/python -m pip install --upgrade pip setuptools wheel || exit $?
    /tmp/venv_build/bin/python -m pip install -r tests/requirements/py3.txt -e .
    exit $?
    ;;

  test)
    python -Wall tests/runtests.py -v2
    exit $?
    ;;

  *)
    echo "Unknown stage: $STAGE" >&2
    exit 1
    ;;
esac
