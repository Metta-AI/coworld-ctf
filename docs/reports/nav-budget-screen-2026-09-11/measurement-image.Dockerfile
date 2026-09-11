# Existing native benchmark build image uses the production Dockerfile build
# stage and Nim 2.2.4. See report for its recorded digest and build provenance.
FROM coworld-nav-c0:latest
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
