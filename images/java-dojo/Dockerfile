FROM eclipse-temurin:21.0.12.1_1-jdk-jammy@sha256:742daacb9316be4b6fc60258f6e4ac2a11882f6c597373c92290a57bfad0d2e0 AS build
WORKDIR /src
COPY src/ ./src/
RUN mkdir -p out  && javac --release 21 -d out src/dojo/DojoApp.java  && jar --create --file dojo.jar --main-class dojo.DojoApp -C out .

FROM gcr.io/distroless/java21-debian13:nonroot@sha256:51c242e7ddaba3666d47115a76a19cfa5076b2ad3ed6077b30d7bac689d98fa1
WORKDIR /app
COPY --from=build --chown=65532:65532 /src/dojo.jar /app/dojo.jar
EXPOSE 8080
CMD ["/app/dojo.jar"]
