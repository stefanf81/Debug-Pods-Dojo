# Keep the debugger JVM on the same Java major as the dojo application.
# Arthas itself is copied from the official project image.
FROM hengyunabc/arthas@sha256:b707315267e2f015fcf8c086ab50579bdeffdb3d94a949371c0e542c6b53910b AS arthas

FROM eclipse-temurin:21-jdk-jammy

RUN apt-get update \
    && apt-get install -y --no-install-recommends procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=arthas /opt/arthas /opt/arthas

ENV PATH="/opt/java/openjdk/bin:${PATH}"

CMD ["bash"]
