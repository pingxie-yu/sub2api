#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/sub2api}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
HOTFIX_BRANCH="${HOTFIX_BRANCH:-hotfix/concurrency-update-safe-20260423}"
IMAGE_TAG="${IMAGE_TAG:-sub2api:fix-concurrency-overflow-20260423}"
COMPOSE_FILE_REL="${COMPOSE_FILE_REL:-deploy/docker-compose.local.yml}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"
SKIP_BUILD=0
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--skip-build] [--dry-run] [--image-tag TAG]

Options:
  --skip-build      Skip docker build and only redeploy current image tag
  --dry-run         Print commands without executing
  --image-tag TAG   Override image tag (default: ${IMAGE_TAG})
  -h, --help        Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --image-tag)
      [[ $# -ge 2 ]] || { echo "missing value for --image-tag" >&2; exit 1; }
      IMAGE_TAG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "repo not found: $REPO_DIR" >&2
  exit 1
fi

cd "$REPO_DIR"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "tracked changes detected. commit/stash first:" >&2
  git status --short >&2
  exit 1
fi

echo "==> Step 1/6: fetch upstream"
run git fetch origin

echo "==> Step 2/6: fast-forward $MAIN_BRANCH"
run git switch "$MAIN_BRANCH"
run git pull --ff-only origin "$MAIN_BRANCH"

echo "==> Step 3/6: rebase $HOTFIX_BRANCH onto $MAIN_BRANCH"
run git switch "$HOTFIX_BRANCH"
if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! git rebase "$MAIN_BRANCH"; then
    echo "rebase failed. resolve conflicts, then run: git rebase --continue" >&2
    exit 1
  fi
else
  run git rebase "$MAIN_BRANCH"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> Step 4/6: build image $IMAGE_TAG"
  run docker build \
    -t "$IMAGE_TAG" \
    --build-arg GOPROXY=https://goproxy.cn,direct \
    --build-arg GOSUMDB=sum.golang.google.cn \
    -f Dockerfile \
    .
else
  echo "==> Step 4/6: skipped docker build"
fi

echo "==> Step 5/6: deploy container"
run docker compose -f "$COMPOSE_FILE_REL" up -d sub2api

echo "==> Step 6/6: health check"
if [[ "$DRY_RUN" -eq 0 ]]; then
  ok=0
  for _ in $(seq 1 30); do
    if docker exec sub2api wget -q -T 5 -O - "$HEALTH_URL" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "health check failed: $HEALTH_URL" >&2
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "^sub2api\\b|^NAMES" || true
    exit 1
  fi
fi

echo "done"
if [[ "$DRY_RUN" -eq 0 ]]; then
  git --no-pager log --oneline -n 3
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "^sub2api\\b|^NAMES" || true
fi
