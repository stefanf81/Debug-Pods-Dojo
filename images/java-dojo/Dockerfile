FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /src
COPY src/ ./src/
RUN mkdir -p out  && javac --release 21 -d out src/dojo/DojoApp.java  && jar --create --file dojo.jar --main-class dojo.DojoApp -C out .

FROM gcr.io/distroless/java21-debian13:nonroot
WORKDIR /app
COPY --from=build --chown=65532:65532 /src/dojo.jar /app/dojo.jar
EXPOSE 8080
CMD ["/app/dojo.jar"]
