#!/usr/bin/env bash
# Entrypoint của GitPTIT: sinh app.ini, migrate database, tạo tài khoản admin và
# nguồn đăng nhập Microsoft từ biến môi trường, rồi giao quyền lại cho entrypoint
# gốc của Gitea để s6 giữ PID 1 như image upstream.
set -Eeuo pipefail

readonly GITEA_ENTRYPOINT=/usr/bin/entrypoint
readonly GITEA_SETUP=/etc/s6/gitea/setup
readonly GITEA_USER="${USER:-git}"
readonly GITEA_HOME=/data/git
readonly GITEA_WORK_PATH=/data/gitea
readonly GITEA_CUSTOM_PATH="${GITEA_CUSTOM:-/app/gitea/custom}"
readonly GITEA_CONFIG="${GITEA_CUSTOM_PATH}/conf/app.ini"
# Tên nguồn đăng nhập không được chứa khoảng trắng vì được đối chiếu theo cột.
readonly AUTH_SOURCE_NAME="${SSO_AUTH_NAME:-Microsoft}"
readonly DB_WAIT_TIMEOUT="${GITPTIT_DB_WAIT_TIMEOUT:-300}"
readonly SSO_ATTEMPTS="${GITPTIT_SSO_ATTEMPTS:-3}"

# Kubernetes mounts secrets as files. Import *_FILE values before any config
# generation so the same image works in both Compose and Kubernetes.
load_secret_files() {
  local name file_var file
  for name in GITEA__database__PASSWD GITEA_ADMIN_PASSWORD SSO_SECRET; do
    file_var="${name}_FILE"
    file="${!file_var:-}"
    if [[ -z "${!name:-}" && -n "$file" ]]; then
      [[ -r "$file" ]] || fail "Không đọc được secret file cho ${name}: ${file}"
      printf -v "$name" '%s' "$(<"$file")"
      export "$name"
    fi
  done
}

log() {
  printf '[gitptit] %s\n' "$*"
}

fail() {
  printf '[gitptit] %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || fail "Thiếu biến môi trường bắt buộc: ${name}"
  done
}

run_gitea() {
  HOME="$GITEA_HOME" su-exec "$GITEA_USER" \
    gitea --config "$GITEA_CONFIG" \
    --work-path "$GITEA_WORK_PATH" \
    --custom-path "$GITEA_CUSTOM_PATH" "$@"
}

# Entrypoint gốc remap USER_UID/USER_GID rồi tạo các thư mục trong /data khi được
# gọi kèm lệnh; sau đó setup của s6 sinh app.ini và áp mọi biến GITEA__* vào file.
prepare_config() {
  "$GITEA_ENTRYPOINT" /bin/true
  bash "$GITEA_SETUP"
}

# `gitea admin` cần schema có sẵn, còn database có thể chưa kịp sẵn sàng nên thử
# lại tới khi hết DB_WAIT_TIMEOUT.
migrate_database() {
  local deadline=$((SECONDS + DB_WAIT_TIMEOUT))
  until run_gitea migrate; do
    ((SECONDS < deadline)) || fail "Database chưa sẵn sàng sau ${DB_WAIT_TIMEOUT}s."
    log 'Chưa kết nối được database, thử lại sau 5s...'
    sleep 5
  done
}

user_exists() {
  run_gitea admin user list \
    | awk -v username="$GITEA_ADMIN_USERNAME" 'NR > 1 && $2 == username { found = 1 } END { exit !found }'
}

auth_source_id() {
  run_gitea admin auth list \
    | awk -v name="$AUTH_SOURCE_NAME" 'NR > 1 && $2 == name { print $1; exit }'
}

ensure_admin() {
  require_env GITEA_ADMIN_USERNAME GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL

  if user_exists; then
    log "Tài khoản admin đã tồn tại: ${GITEA_ADMIN_USERNAME}"
    return 0
  fi

  run_gitea admin user create \
    --username "$GITEA_ADMIN_USERNAME" \
    --password "$GITEA_ADMIN_PASSWORD" \
    --email "$GITEA_ADMIN_EMAIL" \
    --admin \
    --must-change-password=false
  log "Đã tạo tài khoản admin: ${GITEA_ADMIN_USERNAME}"
}

# Đồng bộ lại nguồn đăng nhập ở mỗi lần khởi động để việc rotate client secret
# chỉ cần cập nhật biến môi trường. Gitea gọi tới discovery URL của Microsoft khi
# lưu nguồn đăng nhập, nên lỗi mạng chỉ được cảnh báo: Gitea vẫn phải khởi động
# được và admin vẫn đăng nhập bằng mật khẩu nội bộ.
ensure_sso() {
  if [[ -z "${SSO_CLIENT_ID:-}" && -z "${SSO_SECRET:-}" && -z "${SSO_DIRECTORY_ID:-}" ]]; then
    log 'Bỏ qua Microsoft SSO: chưa cung cấp biến SSO_*.'
    return 0
  fi

  require_env SSO_CLIENT_ID SSO_SECRET SSO_DIRECTORY_ID

  local discovery_url="https://login.microsoftonline.com/${SSO_DIRECTORY_ID}/v2.0/.well-known/openid-configuration"
  local attempt source_id

  for ((attempt = 1; attempt <= SSO_ATTEMPTS; attempt++)); do
    source_id="$(auth_source_id)"

    if [[ -n "$source_id" ]]; then
      if run_gitea admin auth update-oauth --id "$source_id" \
        --name "$AUTH_SOURCE_NAME" \
        --provider openidConnect \
        --key "$SSO_CLIENT_ID" \
        --secret "$SSO_SECRET" \
        --auto-discover-url "$discovery_url" \
        --scopes 'openid profile email'; then
        log "Đã cập nhật nguồn đăng nhập ${AUTH_SOURCE_NAME} (id ${source_id})."
        return 0
      fi
    elif run_gitea admin auth add-oauth \
      --name "$AUTH_SOURCE_NAME" \
      --provider openidConnect \
      --key "$SSO_CLIENT_ID" \
      --secret "$SSO_SECRET" \
      --auto-discover-url "$discovery_url" \
      --scopes 'openid profile email'; then
      log "Đã tạo nguồn đăng nhập ${AUTH_SOURCE_NAME}."
      return 0
    fi

    log "Cấu hình ${AUTH_SOURCE_NAME} thất bại (lần ${attempt}/${SSO_ATTEMPTS})."
    if ((attempt < SSO_ATTEMPTS)); then
      sleep 5
    fi
  done

  log "CẢNH BÁO: không cấu hình được ${AUTH_SOURCE_NAME}. Kiểm tra SSO_DIRECTORY_ID," \
    'SSO_CLIENT_ID, SSO_SECRET và kết nối tới login.microsoftonline.com. Gitea vẫn khởi động.'
}

# Chart triển khai một replica với strategy Recreate nên bootstrap luôn chạy đơn lẻ.
bootstrap() {
  load_secret_files
  prepare_config
  migrate_database
  ensure_admin
  ensure_sso
}

case "${1:-}" in
  --bootstrap-only)
    bootstrap
    ;;
  '')
    bootstrap
    log 'Bootstrap hoàn tất, chuyển quyền cho entrypoint của Gitea.'
    exec "$GITEA_ENTRYPOINT"
    ;;
  *)
    exec "$GITEA_ENTRYPOINT" "$@"
    ;;
esac
