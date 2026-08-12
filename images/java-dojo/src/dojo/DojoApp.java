package dojo;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

public final class DojoApp {
    private static final List<byte[]> LEAK = new ArrayList<>();
    private static final Object LOCK_A = new Object();
    private static final Object LOCK_B = new Object();
    private static final AtomicLong CPU_COUNTER = new AtomicLong();
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(2))
            .build();

    public static void main(String[] args) throws Exception {
        String pod = env("HOSTNAME", "unknown");
        String mode = env("DOJO_MODE", "normal").toLowerCase(Locale.ROOT);
        int port = Integer.parseInt(env("PORT", "8080"));

        if (Boolean.parseBoolean(env("REQUIRE_STARTUP_CONFIG", "false"))
                && !"present".equals(env("STARTUP_REQUIRED", ""))) {
            System.err.println("FATAL: STARTUP_REQUIRED is missing or incorrect; expected value 'present'");
            System.exit(42);
        }

        System.out.printf("[%s] debug-dojo starting pod=%s mode=%s port=%d pid=%d%n",
                Instant.now(), pod, mode, port, ProcessHandle.current().pid());

        long startupDelayMs = Long.parseLong(env("STARTUP_DELAY_MS", "0"));
        if (startupDelayMs > 0) {
            System.out.printf("Delaying HTTP startup for %d ms%n", startupDelayMs);
            sleep(startupDelayMs);
        }

        if (mode.contains("cpu")) startCpuBurner();
        if (mode.contains("deadlock")) startDeadlock();
        if (mode.contains("leak")) startMemoryLeak();
        if (mode.contains("writer")) startWriter();

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/health", ex -> text(ex, 200, "UP\n"));
        server.createContext("/ready", ex -> text(ex, 200, "READY\n"));
        server.createContext("/slow", DojoApp::slowHandler);
        server.createContext("/dependency", DojoApp::dependencyHandler);
        server.createContext("/write", DojoApp::writeHandler);
        server.createContext("/stats", ex -> text(ex, 200,
                "pid=" + ProcessHandle.current().pid() + "\n" +
                "mode=" + mode + "\n" +
                "leakChunks=" + LEAK.size() + "\n" +
                "cpuCounter=" + CPU_COUNTER.get() + "\n"));
        server.createContext("/dojo", ex -> text(ex, 200,
                "Kubernetes Debug Dojo via Ingress\n" +
                "pod=" + pod + "\n" +
                "mode=" + mode + "\n"));
        server.createContext("/", ex -> {
            if (!"/".equals(ex.getRequestURI().getPath())) {
                text(ex, 404, "NOT FOUND\n");
                return;
            }
            text(ex, 200,
                    "Kubernetes Debug Dojo\n" +
                    "pod=" + pod + "\n" +
                    "mode=" + mode + "\n" +
                    "paths=/health /ready /slow /dependency /write /stats /dojo\n");
        });
        server.start();
        System.out.println("HTTP server started");
    }

    private static void startCpuBurner() {
        Thread t = new Thread(() -> {
            double x = 1.000001;
            while (true) {
                for (int i = 0; i < 1_000_000; i++) {
                    x = Math.sqrt(x + i) + Math.sin(x);
                }
                CPU_COUNTER.incrementAndGet();
                if (x == 42) System.out.println("impossible");
            }
        }, "dojo-cpu-burner");
        t.setDaemon(true);
        t.start();
    }

    private static void startDeadlock() {
        Thread first = new Thread(() -> {
            synchronized (LOCK_A) {
                sleep(500);
                synchronized (LOCK_B) {
                    System.out.println("unreachable A->B");
                }
            }
        }, "dojo-deadlock-A");
        Thread second = new Thread(() -> {
            synchronized (LOCK_B) {
                sleep(500);
                synchronized (LOCK_A) {
                    System.out.println("unreachable B->A");
                }
            }
        }, "dojo-deadlock-B");
        first.setDaemon(true);
        second.setDaemon(true);
        first.start();
        second.start();
    }

    private static void startMemoryLeak() {
        Thread t = new Thread(() -> {
            long mib = Long.parseLong(env("LEAK_CHUNK_MIB", "8"));
            long delay = Long.parseLong(env("LEAK_DELAY_MS", "500"));
            while (true) {
                LEAK.add(new byte[(int)(mib * 1024 * 1024)]);
                System.out.printf("leak: retained %d chunks (~%d MiB)%n", LEAK.size(), LEAK.size() * mib);
                sleep(delay);
            }
        }, "dojo-memory-leak");
        t.setDaemon(true);
        t.start();
    }

    private static void startWriter() {
        Thread t = new Thread(() -> {
            while (true) {
                try {
                    writeProbe();
                } catch (Exception e) {
                    System.err.println("writer failed: " + e);
                }
                sleep(5000);
            }
        }, "dojo-pvc-writer");
        t.setDaemon(true);
        t.start();
    }

    public static String slowWork() {
        long delay = Long.parseLong(env("SLOW_MS", "2500"));
        sleep(delay);
        return "slowWork completed in about " + delay + " ms\n";
    }

    private static void slowHandler(HttpExchange ex) throws IOException {
        text(ex, 200, slowWork());
    }

    private static void dependencyHandler(HttpExchange ex) throws IOException {
        String target = env("DEPENDENCY_URL", "http://backend:8080/health");
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(target))
                    .timeout(Duration.ofSeconds(3)).GET().build();
            HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
            text(ex, response.statusCode(), "dependency=" + target + "\n" + response.body());
        } catch (Exception e) {
            System.err.println("dependency call failed target=" + target + " error=" + e);
            text(ex, 502, "dependency failure: " + e + "\n");
        }
    }

    private static void writeHandler(HttpExchange ex) throws IOException {
        try {
            String result = writeProbe();
            text(ex, 200, result);
        } catch (Exception e) {
            text(ex, 500, "write failed: " + e + "\n");
        }
    }

    private static String writeProbe() throws IOException {
        Path path = Path.of(env("WRITE_PATH", "/data/dojo.txt"));
        Files.writeString(path, Instant.now() + " write from pid=" + ProcessHandle.current().pid() + "\n",
                StandardCharsets.UTF_8,
                java.nio.file.StandardOpenOption.CREATE,
                java.nio.file.StandardOpenOption.APPEND);
        return "wrote " + path + "\n";
    }

    private static void text(HttpExchange ex, int code, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
        ex.sendResponseHeaders(code, bytes.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(bytes);
        }
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }

    private static void sleep(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
