#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/ailock-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    extensions/AuditPipeline.swift AppSupport.swift AppSettings.swift ClipboardHistory.swift ClipboardRepository.swift Localization.swift DockController.swift MaintenanceTools.swift FileModels.swift FileScanService.swift DirectoryIndex.swift FileActivityService.swift DirectoryActivityMonitor.swift FileOperationPlan.swift ApplicationCatalog.swift \
    MonitoringService.swift NetworkHistory.swift NetworkInspector.swift NetworkObservationService.swift ProcessMonitor.swift \
    ProcessNetworkMonitor.swift ResourceAlerts.swift SystemMonitor.swift tests/main.swift \
    -o "$TEST_DIR/regression"
"$TEST_DIR/regression"
