# Measurement image for django 5.2.0 (tag 5.2, 9e7cc2b628fe8fd3895986af9b7fc9525034c1b0).
# Mirrored cell: .github/workflows/python_matrix.yml, job `python`, Linux leg with
# Python 3.13 (the supported version closest to the 3.14t of the HEAD campaign).
# Stages: build + test. The build stage reinstalls from /wheelhouse into a fresh venv.

FROM debian:bookworm-20260803-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

ENV DEBIAN_FRONTEND=noninteractive

# libmemcached-dev mirrors the tag's "Install libmemcached-dev for pylibmc" step; the
# toolchain only builds the two sdists below at image build time. No gettext: the tag cell
# does not install it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
        build-essential \
        libmemcached-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Same uv release as the HEAD image (0.12.5); interpreter from python-build-standalone.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN curl -LsSf https://astral.sh/uv/0.12.5/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# GitHub-hosted runners execute as uid 1001; under root five permission tests fail.
RUN useradd -m -u 1001 -s /bin/bash runner

# Latest 3.13 patch released before the tag (2025-04-02); build 20250317.
# Stdlib venv, so pip starts at the version bundled with 3.13.2, as setup-python does.
RUN uv python install 3.13.2 \
    && "$(uv python find 3.13.2)" -m venv /venv
# uv is needed only above; /root/.local/bin is not searchable by uid 1001 and would turn a missing
# executable into EACCES (user_commands test_run_formatters_handles_oserror_for_black_path at this tag).
ENV PATH="/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" VIRTUAL_ENV=/venv

# Offline wheelhouse, resolved at the tag date (2025-04-02T12:56:34Z): py3.txt of the tag plus
# the packaging tools of the "Install and upgrade packaging tools" step.
RUN pip download --dest /wheelhouse --no-deps --only-binary=:all: \
        aiohappyeyeballs==2.6.1 aiohttp==3.11.16 aiosignal==1.3.2 aiosmtpd==1.4.6 \
        argon2-cffi==23.1.0 argon2-cffi-bindings==21.2.0 asgiref==3.8.1 atpublic==5.1 \
        attrs==25.3.0 bcrypt==4.3.0 black==25.1.0 certifi==2025.1.31 cffi==1.17.1 \
        charset-normalizer==3.4.1 click==8.1.8 docutils==0.21.2 frozenlist==1.5.0 \
        geoip2==5.0.1 h11==0.14.0 idna==3.10 jinja2==3.1.6 markupsafe==3.0.2 \
        maxminddb==2.6.3 multidict==6.2.0 mypy-extensions==1.0.0 numpy==2.2.4 \
        outcome==1.3.0.post0 packaging==24.2 pathspec==0.12.1 pillow==11.1.0 \
        platformdirs==4.3.7 propcache==0.3.1 pycparser==2.22 pymemcache==4.0.0 \
        pysocks==1.7.1 pyyaml==6.0.2 redis==5.2.1 requests==2.32.3 selenium==4.30.0 \
        sniffio==1.3.1 sortedcontainers==2.4.0 sqlparse==0.5.3 tblib==3.1.0 trio==0.29.0 \
        trio-websocket==0.12.2 typing-extensions==4.13.0 tzdata==2025.2 urllib3==2.3.0 \
        websocket-client==1.8.0 wsproto==1.2.0 yarl==1.18.3 \
        pip==25.0.1 setuptools==78.1.0 wheel==0.45.1

# Isolated build backend of `-e .` at this tag: setuptools>=61.0.0,<69.3.0.
RUN pip download --dest /wheelhouse --no-deps --only-binary=:all: setuptools==69.2.0

# pylibmc and pywatchman ship no Linux wheel for cp313; built once here, as the
# runner's pip cache does, so the measured build installs wheels only, as at HEAD.
RUN printf 'setuptools==78.1.0\nwheel==0.45.1\n' > /tmp/build-constraints.txt \
    && PIP_CONSTRAINT=/tmp/build-constraints.txt pip wheel --no-deps --wheel-dir /wheelhouse \
        pylibmc==1.6.3 pywatchman==2.0.0 \
    && rm /tmp/build-constraints.txt \
    && chmod -R a+rX /wheelhouse \
    && test "$(ls /wheelhouse | grep -vc '\.whl$')" -eq 0

# Source of the tag; everything below depends on it.
WORKDIR /project
COPY --chown=runner:runner . /project

ENV PIP_NO_INDEX=1 PIP_FIND_LINKS=/wheelhouse
RUN pip install --upgrade pip setuptools wheel \
    && pip install -r tests/requirements/py3.txt -e . \
    && chown -R runner:runner /venv /opt/uv-python /project

USER runner
ENV HOME=/home/runner

RUN cd /project/tests && DJANGO_SETTINGS_MODULE=test_sqlite \
    python -c "import django; django.setup(); from django.conf import settings; \
assert settings.DATABASES['default']['ENGINE'].endswith('sqlite3'); print(django.get_version())"

RUN python -c "import sys; assert sys._is_gil_enabled(); \
assert sys.version.split()[0] == '3.13.2', sys.version; print(sys.version)"

# Build context: a clone of branch release-5.2.0 (not a git worktree).
#   docker build -t django-measurement-5.2.0 -f energy-measurement/Dockerfile .
