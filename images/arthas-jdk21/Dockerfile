# Keep the debugger JVM on the same Java major as the dojo application.
# Arthas itself is copied from the official project image.
FROM hengyunabc/arthas@sha256:b707315267e2f015fcf8c086ab50579bdeffdb3d94a949371c0e542c6b53910b AS arthas

FROM eclipse-temurin:21.0.12.1_1-jdk-jammy@sha256:742daacb9316be4b6fc60258f6e4ac2a11882f6c597373c92290a57bfad0d2e0

RUN apt-get update \
    && apt-get install -y --no-install-recommends procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=arthas /opt/arthas /opt/arthas

ENV PATH="/opt/java/openjdk/bin:${PATH}"

CMD ["bash"]
