#!/usr/bin/env bash
# Resume the Codex conversation that created the sql2sql utilities.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec codex resume --cd "$project_dir" '01a0d388-8ae8-7573-902f-36f481a0df3d' "$@"
