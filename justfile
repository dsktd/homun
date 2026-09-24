build:
    podman build . -t claude --pull=always

update:
    podman build . -t claude --pull=always --build-arg="CACHEBUST=$(date +%s)"
