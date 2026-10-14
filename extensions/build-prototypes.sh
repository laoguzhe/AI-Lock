#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROTOTYPE_DIR="build/prototypes"
mkdir -p "$PROTOTYPE_DIR"
for arch in arm64; do
    swiftc -swift-version 5 -target "$arch-apple-macos14.0" FileModels.swift extensions/AuditPipeline.swift extensions/AuditEventBuffer.swift extensions/AuditIPC.swift extensions/EndpointSecurity/AuditIPCService.swift extensions/EndpointSecurity/main.swift -lEndpointSecurity -o "$PROTOTYPE_DIR/AILockAuditPrototype-$arch"
    swiftc -swift-version 5 -target "$arch-apple-macos14.0" FilterConfigurationTransaction.swift NetworkFilterPolicy.swift SignedApplicationResolver.swift extensions/AuditIPC.swift extensions/FilterHealthIPC.swift extensions/ContentFilter/FilterHealthService.swift extensions/ContentFilter/main.swift -o "$PROTOTYPE_DIR/AILockFilterPrototype-$arch"
done
mv "$PROTOTYPE_DIR/AILockAuditPrototype-arm64" "$PROTOTYPE_DIR/AILockAuditPrototype"
mv "$PROTOTYPE_DIR/AILockFilterPrototype-arm64" "$PROTOTYPE_DIR/AILockFilterPrototype"
echo 'Compiled development prototypes only; no packaging, privileged launch, installation or activation.'
