#!/bin/bash
# ─── Incident Simulation Scripts ──────────────────────────────────────────────
# Run these intentionally to practice incident response.
# After triggering each one, practice diagnosing it WITHOUT looking at the cause.
# Then document the debugging steps as a post-mortem.

# Usage: ./incident.sh <incident_name>
# Examples:
#   ./incident.sh oom          - simulate OOM kill
#   ./incident.sh disk         - fill disk
#   ./incident.sh errors       - high error rate
#   ./incident.sh slow         - high latency
#   ./incident.sh recover      - recover all incidents

case "$1" in

  # ─── OOM Kill Simulation ──────────────────────────────────────────────────
  # Sets memory limit to 50MB, then sends requests to spike memory
  # Expected: container dies, restarts, you see OOMKilled in docker inspect
  "oom")
    echo "🔴 Triggering OOM kill simulation..."
    echo "Expected: SecureShip container will be OOM killed and restart"
    echo "Debug: docker inspect secureship | grep -i oom"
    
    # Update memory limit (requires docker-compose change or docker update)
    docker update --memory 50m --memory-swap 50m secureship
    
    # Send concurrent requests to spike memory
    for i in {1..50}; do
      curl -s http://localhost:8001/api/ships &
    done
    wait
    
    echo "Check: docker stats secureship"
    echo "Check: docker inspect secureship | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d[0]['State'])\""
    ;;

  # ─── Disk Fill Simulation ─────────────────────────────────────────────────
  # Fills disk to test disk space alerts
  # Expected: DiskSpaceLow alert fires in Prometheus/AlertManager
  "disk")
    echo "🔴 Filling disk..."
    echo "Expected: Prometheus DiskSpaceLow alert fires when >75% full"
    echo "Watch: watch -n 5 'df -h /'"
    
    # Fill ~4GB - adjust if your disk is small
    dd if=/dev/zero of=/tmp/disk_fill bs=1M count=4000 status=progress
    
    echo ""
    echo "Disk is now $(df -h / | tail -1 | awk '{print $5}') full"
    echo "To recover: rm /tmp/disk_fill"
    ;;

  # ─── High Error Rate ──────────────────────────────────────────────────────
  # Configures StatusService to return 50% errors
  # Expected: HighErrorRate alert fires after 2 minutes
  "errors")
    echo "🔴 Triggering high error rate..."
    echo "Expected: HighErrorRate alert fires in ~2 minutes"
    echo "Watch: Grafana error rate panel"
    
    # Stop and restart with failure rate
    docker stop statusservice
    docker run -d \
      --name statusservice \
      --network observeops_observeops \
      -p 8002:8002 \
      -e FAILURE_RATE=0.5 \
      statusservice
    
    # Generate traffic to trigger the errors
    echo "Generating traffic..."
    for i in {1..100}; do
      curl -s http://localhost:8002/fail > /dev/null &
    done
    wait
    
    echo "Check Grafana: http://localhost:3000"
    echo "Check Prometheus: http://localhost:9090/alerts"
    echo "To recover: ./incident.sh recover"
    ;;

  # ─── Slow Response Simulation ─────────────────────────────────────────────
  # Generates CPU load to slow down responses
  # Expected: HighLatency and HighCPU alerts fire
  "slow")
    echo "🔴 Generating load to cause high latency..."
    echo "Expected: HighCPU and HighLatency alerts fire"
    
    # Run CPU load in background
    curl -s -X POST "http://localhost:8002/load?duration=120" &
    
    echo "CPU load started for 120 seconds"
    echo "Watch: htop"
    echo "Watch: Grafana CPU panel"
    ;;

  # ─── Container Kill ───────────────────────────────────────────────────────
  # Stops SecureShip without docker-compose
  # Expected: ALB health check fails, ServiceDown alert fires
  "kill")
    echo "🔴 Killing SecureShip container..."
    echo "Expected: ServiceDown alert fires in ~1 minute"
    echo "If behind ALB: users see 502 errors"
    
    docker stop secureship
    
    echo "Container stopped. Check:"
    echo "  curl http://localhost:8001/health  (should fail)"
    echo "  docker ps (secureship not running)"
    echo "  Prometheus: up{job='secureship'} = 0"
    echo "To recover: ./incident.sh recover"
    ;;

  # ─── Recovery ─────────────────────────────────────────────────────────────
  "recover")
    echo "🟢 Recovering all services..."
    
    # Remove disk fill
    rm -f /tmp/disk_fill
    echo "✓ Disk cleaned"
    
    # Reset memory limits
    docker update --memory 0 --memory-swap 0 secureship 2>/dev/null || true
    echo "✓ Memory limits reset"
    
    # Restart all services normally
    docker compose up -d
    echo "✓ All services restarted"
    
    # Wait and check health
    sleep 10
    curl -s http://localhost:8001/health && echo "✓ SecureShip healthy"
    curl -s http://localhost:8002/health && echo "✓ StatusService healthy"
    ;;

  *)
    echo "Usage: ./incident.sh <incident>"
    echo ""
    echo "Available incidents:"
    echo "  oom     - OOM kill (memory limit breach)"
    echo "  disk    - Disk fill"
    echo "  errors  - High error rate"
    echo "  slow    - High latency (CPU load)"
    echo "  kill    - Kill container (ServiceDown)"
    echo "  recover - Recover all"
    ;;
esac
