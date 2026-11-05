FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git cmake build-essential libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init && git remote add origin https://github.com/ggml-org/llama.cpp.git && git fetch --depth 1 origin 2ada83079afc79295b3c07bae8a74457c61cba92 && git checkout --detach FETCH_HEAD
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_CUDA=OFF -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF && cmake --build build --target llama-server -j 4
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libgomp1 libssl3t64 curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=build /src/LICENSE /usr/share/licenses/llama.cpp/LICENSE
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD ["curl", "-fsS", "http://127.0.0.1:8080/health"]
ENTRYPOINT ["llama-server"]
CMD ["--host", "0.0.0.0", "--port", "8080", "--model", "/models/qwen2.5-0.5b-instruct-q4_k_m.gguf", "--alias", "qwen-local", "--ctx-size", "2048", "--threads", "2", "--parallel", "1", "--n-gpu-layers", "0", "--metrics"]

