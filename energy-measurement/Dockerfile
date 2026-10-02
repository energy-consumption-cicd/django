# Measurement image for django 6.0.0 (tag 6.0, 36b5f39d9372147f0e758f590e35ee2b2bc317dd).
# Mirrored cell: .github/workflows/python_matrix.yml, job `python`, Linux leg with
# Python 3.14 (the supported version closest to the 3.14t of the HEAD campaign).
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

# Latest 3.14 patch released before the tag (2025-12-03); build 20251202.
# Stdlib venv, so pip starts at the version bundled with 3.14.1, as setup-python does.
RUN uv python install 3.14.1 \
    && "$(uv python find 3.14.1)" -m venv /venv
ENV PATH="/venv/bin:${PATH}" VIRTUAL_ENV=/venv

# Offline wheelhouse, resolved at the tag date (2025-12-03T16:20:45Z): py3.txt of the tag plus
# the packaging tools of the "Install and upgrade packaging tools" step.
RUN pip download --dest /wheelhouse --no-deps --only-binary=:all: \
        aiohappyeyeballs==2.6.1 aiohttp==3.13.2 aiosignal==1.4.0 aiosmtpd==1.4.6 \
        argon2-cffi==25.1.0 argon2-cffi-bindings==25.1.0 asgiref==3.11.0 atpublic==7.0.0 \
        attrs==25.4.0 bcrypt==5.0.0 black==25.11.0 certifi==2025.11.12 cffi==2.0.0 \
        charset-normalizer==3.4.4 click==8.3.1 docutils==0.22.3 frozenlist==1.8.0 \
        geoip2==5.2.0 h11==0.16.0 idna==3.11 jinja2==3.1.6 markupsafe==3.0.3 \
        maxminddb==3.0.0 multidict==6.7.0 mypy-extensions==1.1.0 numpy==2.3.5 \
        outcome==1.3.0.post0 packaging==25.0 pathspec==0.12.1 pillow==12.0.0 \
        platformdirs==4.5.0 propcache==0.4.1 pycparser==2.23 pymemcache==4.0.0 \
        pysocks==1.7.1 pytokens==0.3.0 pyyaml==6.0.3 redis==7.1.0 requests==2.32.5 \
        selenium==4.38.0 sniffio==1.3.1 sortedcontainers==2.4.0 sqlparse==0.5.4 \
        tblib==3.2.2 trio==0.32.0 trio-websocket==0.12.2 typing-extensions==4.15.0 \
        tzdata==2025.2 urllib3==2.5.0 websocket-client==1.9.0 wsproto==1.3.2 \
        yarl==1.22.0 \
        pip==25.3 setuptools==80.9.0 wheel==0.46.1

# pylibmc and pywatchman ship no Linux wheel for cp314; built once here, as the
# runner's pip cache does, so the measured build installs wheels only, as at HEAD.
RUN printf 'setuptools==80.9.0\nwheel==0.46.1\n' > /tmp/build-constraints.txt \
    && PIP_CONSTRAINT=/tmp/build-constraints.txt pip wheel --no-deps --wheel-dir /wheelhouse \
        pylibmc==1.6.3 pywatchman==3.0.0 \
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
assert sys.version.split()[0] == '3.14.1', sys.version; print(sys.version)"

# Build context: a clone of branch release-6.0.0 (not a git worktree).
#   docker build -t django-measurement-6.0.0 -f energy-measurement/Dockerfile .
