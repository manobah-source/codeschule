#!/usr/bin/env bash
# Vollständiges Setup für:
# - lokales Astro-Projekt (Node.js >= 20)
# - Git/GitHub-Repository
# - öffentlichen S3-Website-Bucket
# - GitHub Actions OIDC in AWS
# - auf <owner>/<repo> und main beschränkte IAM-Rolle
# - S3-Rechte über eine kundenverwaltete IAM-Policy (kein PutRolePolicy)
# - Build und Deployment bei Push nach main
# - optionalen, abgesicherten OIDC-Branch-Sicherheitstest

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly OIDC_HOST="token.actions.githubusercontent.com"
readonly OIDC_URL="https://${OIDC_HOST}"
readonly OIDC_AUDIENCE="sts.amazonaws.com"
readonly OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
readonly DEFAULT_REGION="us-east-1"
readonly DEFAULT_ROLE_NAME="github-actions-deploy-role"
readonly DEFAULT_POLICY_NAME="github-actions-s3-deploy-policy"
readonly DEFAULT_PROJECT_DIR="./my-astro-project"
readonly SECURITY_TEST_BRANCH="feature/oidc-security-test"

REGION=""
ROLE_NAME=""
MANAGED_POLICY_NAME=""
PROJECT_DIR=""
PROJECT_DIR_ABS=""
GITHUB_USERNAME=""
REPO_NAME=""
REPO_SLUG=""
BUCKET_NAME=""
REPO_VISIBILITY="private"

ACCOUNT_ID=""
CALLER_ARN=""
OIDC_PROVIDER_ARN=""
ROLE_ARN=""
MANAGED_POLICY_ARN=""
WEBSITE_URL=""
TEMP_DIR=""
SERVER_PID=""
TRUST_POLICY_WIDENED=0
MAIN_TRUST_POLICY_FILE=""

AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_SESSION_TOKEN=""

info()    { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
success() { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }
warning() { printf '\033[1;33mWARNUNG:\033[0m %s\n' "$*" >&2; }
fail()    { printf '\n\033[1;31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

prompt_required() {
    local variable_name="$1" prompt_text="$2" value=""
    while [[ -z "${value}" ]]; do
        read -r -p "${prompt_text}: " value
    done
    printf -v "${variable_name}" '%s' "${value}"
}

prompt_default() {
    local variable_name="$1" prompt_text="$2" default_value="$3" value=""
    read -r -p "${prompt_text} [${default_value}]: " value
    printf -v "${variable_name}" '%s' "${value:-${default_value}}"
}

confirm() {
    local prompt_text="$1" default_answer="${2:-no}" answer=""
    if [[ "${default_answer}" == "yes" ]]; then
        read -r -p "${prompt_text} [Y/n]: " answer
        [[ -z "${answer}" || "${answer}" =~ ^([Yy]|[Yy][Ee][Ss]|[Jj]|[Jj][Aa])$ ]]
    else
        read -r -p "${prompt_text} [y/N]: " answer
        [[ "${answer}" =~ ^([Yy]|[Yy][Ee][Ss]|[Jj]|[Jj][Aa])$ ]]
    fi
}

run_aws() {
    local output exit_code
    set +e
    output="$(aws --no-cli-pager "$@" 2>&1)"
    exit_code=$?
    set -e
    if (( exit_code != 0 )); then
        printf '%s\n' "${output}" >&2
        return "${exit_code}"
    fi
    printf '%s\n' "${output}"
}

restore_main_trust_best_effort() {
    if (( TRUST_POLICY_WIDENED == 1 )) && \
       [[ -n "${MAIN_TRUST_POLICY_FILE:-}" && -f "${MAIN_TRUST_POLICY_FILE}" ]] && \
       [[ -n "${ROLE_NAME:-}" ]] && command_exists aws; then
        warning "Sicherheitsschutz: Strikte main-Trust-Policy wird wiederhergestellt ..."
        if aws --no-cli-pager iam update-assume-role-policy \
            --role-name "${ROLE_NAME}" \
            --policy-document "file://${MAIN_TRUST_POLICY_FILE}" >/dev/null 2>&1; then
            TRUST_POLICY_WIDENED=0
            success "Strikte main-Trust-Policy wurde wiederhergestellt"
        else
            warning "Automatische Wiederherstellung ist fehlgeschlagen. Stelle die Trust Policy SOFORT manuell auf repo:${REPO_SLUG}:ref:refs/heads/main zurück."
        fi
    fi
}

cleanup() {
    local exit_code=$?
    set +e
    restore_main_trust_best_effort
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "${SERVER_PID}" >/dev/null 2>&1 || true
        wait "${SERVER_PID}" >/dev/null 2>&1 || true
    fi
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_DEFAULT_REGION AWS_REGION AWS_PAGER
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
    if (( exit_code != 0 )); then
        printf '\nDas Skript wurde mit einem Fehler beendet. Bereits erstellte Ressourcen bleiben bestehen; ein erneuter Start ist vorgesehen.\n' >&2
    fi
    exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

validate_github_value() {
    local value="$1" label="$2"
    [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "${label} enthält ungültige Zeichen: ${value}"
}

validate_iam_name() {
    local value="$1" label="$2"
    [[ "${value}" =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] || fail "Ungültiger ${label}: ${value}"
}

validate_bucket_name() {
    local bucket="$1"
    [[ "${bucket}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || \
        fail "Ungültiger S3-Bucket-Name '${bucket}'. Er muss 3–63 Zeichen lang sein und darf nur Kleinbuchstaben, Ziffern, Punkte und Bindestriche enthalten."
    [[ "${bucket}" != *".."* ]] || fail "Der Bucket-Name darf keine zwei aufeinanderfolgenden Punkte enthalten."
    [[ ! "${bucket}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Der Bucket-Name darf nicht wie eine IPv4-Adresse aussehen."
}

slugify_bucket_part() {
    printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9.-]+/-/g; s/^[^a-z0-9]+//; s/[^a-z0-9]+$//; s/-+/-/g'
}

check_prerequisites() {
    info "Erforderliche Tools prüfen"
    local missing=0 cmd
    for cmd in aws git gh node npm jq python3 curl mktemp realpath; do
        if ! command_exists "${cmd}"; then
            printf '  - fehlt: %s\n' "${cmd}" >&2
            missing=1
        fi
    done
    (( missing == 0 )) || fail "Installiere die fehlenden Tools und starte das Skript erneut. Benötigt werden AWS CLI v2, Git, GitHub CLI, Node.js >= 20, npm, jq, Python 3 und curl."

    local node_version node_major
    node_version="$(node --version)"
    node_major="${node_version#v}"
    node_major="${node_major%%.*}"
    [[ "${node_major}" =~ ^[0-9]+$ ]] || fail "Node.js-Version konnte nicht erkannt werden: ${node_version}"
    (( node_major >= 20 )) || fail "Node.js 20 oder neuer ist erforderlich; gefunden wurde ${node_version}."

    aws --version
    git --version
    gh --version | head -n 1
    success "Voraussetzungen erfüllt (Node.js ${node_version}, npm $(npm --version))"
}

check_github_auth() {
    info "GitHub-CLI-Anmeldung prüfen"
    if ! gh auth status >/dev/null 2>&1; then
        warning "Die GitHub CLI ist noch nicht angemeldet. Der interaktive Login wird gestartet."
        gh auth login
    fi
    GITHUB_USERNAME="$(gh api user --jq .login)"
    [[ -n "${GITHUB_USERNAME}" ]] || fail "GitHub-Benutzername konnte nicht automatisch ermittelt werden."
    success "GitHub CLI ist als ${GITHUB_USERNAME} angemeldet"
}

collect_project_inputs() {
    info "Projektwerte erfassen"
    local detected_owner="${GITHUB_USERNAME}"
    prompt_default GITHUB_USERNAME "GitHub-Benutzername oder Organisation" "${detected_owner}"
    prompt_default PROJECT_NAME "Projekt-/Repository-Name" "my-astro-project"
    REPO_NAME="${PROJECT_NAME}"
    PROJECT_DIR="./${PROJECT_NAME}"
    prompt_default REGION "AWS-Region" "${DEFAULT_REGION}"
    prompt_default ROLE_NAME "IAM-Rollenname" "${DEFAULT_ROLE_NAME}"
    prompt_default MANAGED_POLICY_NAME "Name der kundenverwalteten IAM-Policy" "${DEFAULT_POLICY_NAME}"

    validate_github_value "${GITHUB_USERNAME}" "GitHub-Benutzername/Organisation"
    validate_github_value "${REPO_NAME}" "Repository-Name"
    validate_iam_name "${ROLE_NAME}" "IAM-Rollenname"
    validate_iam_name "${MANAGED_POLICY_NAME}" "IAM-Policy-Name"
    [[ "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || fail "Ungültig wirkende AWS-Region: ${REGION}"
    [[ -n "${PROJECT_DIR}" && "${PROJECT_DIR}" != "/" ]] || fail "Ungültiges Projektverzeichnis."

    REPO_SLUG="${GITHUB_USERNAME}/${REPO_NAME}"
    PROJECT_DIR_ABS="$(realpath -m "${PROJECT_DIR}")"

    if [[ -d "${PROJECT_DIR_ABS}/.git" ]]; then
        CURRENT_ORIGIN="$(git -C "${PROJECT_DIR_ABS}" remote get-url origin 2>/dev/null || true)"
        if [[ -n "${CURRENT_ORIGIN}" && "${CURRENT_ORIGIN}" != *"${GITHUB_USERNAME}/${REPO_NAME}"* ]]; then
            fail "Das lokale Projekt ist bereits mit einem anderen GitHub-Repository verbunden.

Aktuell:
  ${CURRENT_ORIGIN}

Erwartet:
  ${GITHUB_USERNAME}/${REPO_NAME}

Aus Sicherheitsgründen wird origin nicht automatisch verändert."
        fi
    fi

    if ! gh repo view "${REPO_SLUG}" >/dev/null 2>&1; then
        local visibility=""
        read -r -p "Neues GitHub-Repository privat oder öffentlich? [private/public, Standard: private]: " visibility
        case "${visibility:-private}" in
            private|public) REPO_VISIBILITY="${visibility:-private}" ;;
            *) fail "Bitte 'private' oder 'public' wählen." ;;
        esac
    fi
}

ensure_local_project() {
    info "Astro-Projekt vorbereiten"
    if [[ -f "${PROJECT_DIR_ABS}/package.json" ]]; then
        jq -e '.scripts.build and .scripts.dev and .scripts.preview' "${PROJECT_DIR_ABS}/package.json" >/dev/null || \
            fail "Im vorhandenen Verzeichnis fehlt ein geeignetes Astro-package.json: ${PROJECT_DIR_ABS}"
        success "Vorhandenes Node/Astro-Projekt wird verwendet: ${PROJECT_DIR_ABS}"
    else
        [[ ! -e "${PROJECT_DIR_ABS}" || -z "$(find "${PROJECT_DIR_ABS}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || \
            fail "Das Zielverzeichnis ist nicht leer und enthält kein package.json: ${PROJECT_DIR_ABS}"
        mkdir -p "$(dirname "${PROJECT_DIR_ABS}")"
        npm create astro@latest -- "${PROJECT_DIR_ABS}" \
            --template minimal \
            --install \
            --no-git \
            --yes
        success "Astro-Projekt erstellt"
    fi

    [[ -f "${PROJECT_DIR_ABS}/package-lock.json" ]] || (cd "${PROJECT_DIR_ABS}" && npm install)
    (cd "${PROJECT_DIR_ABS}" && npm ci)
    success "Abhängigkeiten reproduzierbar mit npm ci installiert"

    printf '22\n' > "${PROJECT_DIR_ABS}/.nvmrc"
    success ".nvmrc mit Node 22 erzeugt"

    cat > "${PROJECT_DIR_ABS}/src/pages/index.astro" <<'ASTRO'
---
---
<html lang="de">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Astro + AWS S3 + GitHub OIDC</title>
    <style>
      :root { --bg:#0b1020; --fg:#e6edf3; --muted:#94a3b8; --accent:#38bdf8; --card:#111827; --border:#1f2937; }
      *{box-sizing:border-box} body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg);line-height:1.6}
      .wrap{max-width:1100px;margin:0 auto;padding:48px 24px}
      .hero{display:grid;grid-template-columns:1fr 1fr;gap:32px;align-items:center}
      @media(max-width:768px){.hero{grid-template-columns:1fr}}
      h1{font-size:2.4rem;margin:0 0 12px} .lead{color:var(--muted);font-size:1.1rem}
      .badge{display:inline-block;background:#0ea5e9;color:#001018;padding:4px 12px;border-radius:999px;font-weight:600;font-size:.85rem;margin-bottom:16px}
      .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:24px}
      .step{display:flex;gap:16px;margin-bottom:20px} .num{width:36px;height:36px;border-radius:50%;background:var(--accent);color:#001018;display:flex;align-items:center;justify-content:center;font-weight:700;flex-shrink:0}
      .step h3{margin:0 0 4px;font-size:1.05rem} .step p{margin:0;color:var(--muted);font-size:.95rem}
      pre{background:#020617;border:1px solid var(--border);border-radius:10px;padding:16px;overflow-x:auto;font-size:.85rem;color:#a5f3fc;margin:12px 0}
      code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
      .foot{margin-top:40px;color:var(--muted);font-size:.85rem;text-align:center}
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="hero">
        <div>
          <span class="badge">Deployment erfolgreich</span>
          <h1>Astro auf Amazon S3 via GitHub OIDC</h1>
          <p class="lead">Diese Seite wurde automatisch gebaut, über GitHub Actions mit temporären AWS-Credentials aus OIDC deployed und von S3 als statische Website ausgeliefert.</p>
        </div>
        <div class="card">
          <div class="step"><div class="num">1</div><div><h3>Build</h3><p><code>npm ci && npm run build</code> in GitHub Actions</p></div></div>
          <div class="step"><div class="num">2</div><div><h3>OIDC</h3><p><code>aws-actions/configure-aws-credentials</code> übernimmt die Rolle ohne Access Keys</p></div></div>
          <div class="step"><div class="num">3</div><div><h3>Deploy</h3><p><code>aws s3 sync ./dist s3://BUCKET --delete</code></p></div></div>
        </div>
      </div>
      <div class="card" style="margin-top:32px">
        <h3>Verwendete AWS-Befehle</h3>
        <pre><code>aws sts get-caller-identity
aws s3 sync ./dist s3://BUCKET --delete
aws s3 website s3://BUCKET --index-document index.html</code></pre>
      </div>
      <p class="foot">Generiert durch setup-full-astro-aws-github.sh · Node 22 · Astro · GitHub Actions · AWS S3</p>
    </div>
  </body>
</html>
ASTRO
    success "Demo-UI in src/pages/index.astro geschrieben"

    info "Production Build erzeugen"
    (cd "${PROJECT_DIR_ABS}" && npm run build)
    [[ -d "${PROJECT_DIR_ABS}/dist" ]] || fail "npm run build war beendet, aber dist/ wurde nicht erzeugt."
    [[ -n "$(find "${PROJECT_DIR_ABS}/dist" -type f -print -quit)" ]] || fail "dist/ ist leer."
    success "Production Build und dist/ geprüft"
}

ensure_github_repo_and_ids() {
    info "GitHub-Repository sicherstellen und IDs ermitteln"
    if gh repo view "${REPO_SLUG}" >/dev/null 2>&1; then
        success "GitHub-Repository existiert bereits: ${REPO_SLUG}"
    else
        gh repo create "${REPO_SLUG}" "--${REPO_VISIBILITY}" --description "Astro website deployed to Amazon S3 with GitHub Actions OIDC"
        success "GitHub-Repository erstellt: ${REPO_SLUG}"
    fi

    GITHUB_OWNER_ID="$(gh api "users/${GITHUB_USERNAME}" --jq '.id')"
    GITHUB_REPO_ID="$(gh api "repos/${GITHUB_USERNAME}/${REPO_NAME}" --jq '.id')"
    OIDC_SUBJECT="repo:${GITHUB_USERNAME}@${GITHUB_OWNER_ID}/${REPO_NAME}@${GITHUB_REPO_ID}:ref:refs/heads/main"
    success "OIDC Subject ermittelt: ${OIDC_SUBJECT}"
}

find_free_port() {
    local port="${1:-4321}"
    local max_port=65535

    while (( port <= max_port )); do
        if python3 - "${port}" <<'PY'
import socket
import sys

port = int(sys.argv[1])

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

try:
    sock.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    sock.close()

sys.exit(0)
PY
        then
            printf '%s\n' "${port}"
            return 0
        fi

        ((port++))
    done

    return 1
}

smoke_test_server() {
    local npm_script="$1"
    local preferred_port="$2"
    local label="$3"
    local port
    local attempt
    local log_file

    port="$(
        find_free_port "${preferred_port}"
    )" || fail "Es konnte kein freier lokaler TCP-Port ab ${preferred_port} gefunden werden."

    log_file="${TEMP_DIR}/${npm_script}-${port}.log"

    info "${label} kurz lokal testen"

    if [[ "${port}" != "${preferred_port}" ]]; then
        echo "Port ${preferred_port} ist belegt."
        echo "Verwende stattdessen freien Port ${port}."
    else
        echo "Verwende freien Port ${port}."
    fi

    (
        cd "${PROJECT_DIR_ABS}"

        npm run "${npm_script}" -- \
            --host 127.0.0.1 \
            --port "${port}"

    ) >"${log_file}" 2>&1 &

    SERVER_PID=$!

    for attempt in $(seq 1 30); do
        if curl \
            --fail \
            --silent \
            --show-error \
            "http://127.0.0.1:${port}/" \
            >/dev/null 2>&1; then

            kill "${SERVER_PID}" >/dev/null 2>&1 || true
            wait "${SERVER_PID}" >/dev/null 2>&1 || true

            SERVER_PID=""

            success "${label} antwortet unter http://127.0.0.1:${port}/"

            return 0
        fi

        if ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
            echo
            echo "Server-Log:"
            cat "${log_file}" >&2

            SERVER_PID=""

            fail "${label} wurde unerwartet beendet."
        fi

        sleep 1
    done

    echo
    echo "Server-Log:"
    cat "${log_file}" >&2

    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true

    SERVER_PID=""

    fail "${label} war nach 30 Sekunden nicht erreichbar."
}

collect_aws_credentials() {
    info "Temporäre AWS-Sandbox-Credentials eingeben"
    echo "Die Werte werden nur als Umgebungsvariablen dieses Prozesses verwendet und nicht in Dateien geschrieben."
    prompt_required AWS_ACCESS_KEY_ID "AWS Access Key ID"
    read -r -s -p "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY; echo
    [[ -n "${AWS_SECRET_ACCESS_KEY}" ]] || fail "AWS Secret Access Key darf nicht leer sein."
    read -r -s -p "AWS Session Token (bei Sandbox meist erforderlich; sonst Enter): " AWS_SESSION_TOKEN; echo

    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    if [[ -n "${AWS_SESSION_TOKEN}" ]]; then export AWS_SESSION_TOKEN; else unset AWS_SESSION_TOKEN 2>/dev/null || true; fi
    export AWS_DEFAULT_REGION="${REGION}" AWS_REGION="${REGION}" AWS_PAGER=""

    info "AWS-Zugangsdaten validieren"
    local identity
    identity="$(run_aws sts get-caller-identity --output json)" || \
        fail "AWS-Anmeldung fehlgeschlagen. Prüfe Access Key, Secret Key und ggf. Session Token."
    ACCOUNT_ID="$(jq -r '.Account' <<<"${identity}")"
    CALLER_ARN="$(jq -r '.Arn' <<<"${identity}")"
    [[ "${ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || fail "AWS Account ID konnte nicht ermittelt werden."

    OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
    ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    MANAGED_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${MANAGED_POLICY_NAME}"
    if [[ "${REGION}" == "us-east-1" ]]; then
        WEBSITE_URL="http://${BUCKET_NAME}.s3-website-us-east-1.amazonaws.com"
    else
        WEBSITE_URL="http://${BUCKET_NAME}.s3-website.${REGION}.amazonaws.com"
    fi
    success "AWS-Anmeldung erfolgreich: ${CALLER_ARN}"
}

collect_bucket_name() {
    local suggested owner_part repo_part
    owner_part="$(slugify_bucket_part "${GITHUB_USERNAME}")"
    repo_part="$(slugify_bucket_part "${REPO_NAME}")"
    suggested="${owner_part}-${repo_part}-${ACCOUNT_ID}"
    suggested="${suggested:0:63}"
    suggested="${suggested%.}"
    suggested="${suggested%-}"
    prompt_default BUCKET_NAME "Global eindeutiger S3-Bucket-Name" "${suggested}"
    validate_bucket_name "${BUCKET_NAME}"

    if [[ "${REGION}" == "us-east-1" ]]; then
        WEBSITE_URL="http://${BUCKET_NAME}.s3-website-us-east-1.amazonaws.com"
    else
        WEBSITE_URL="http://${BUCKET_NAME}.s3-website.${REGION}.amazonaws.com"
    fi
}

write_policy_files() {
    MAIN_TRUST_POLICY_FILE="${TEMP_DIR}/trust-main.json"
    cat >"${MAIN_TRUST_POLICY_FILE}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "GitHubActionsOidcTrust",
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": "${OIDC_SUBJECT}"}
    }
  }]
}
JSON

    cat >"${TEMP_DIR}/permission-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListDeploymentBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Sid": "ManageDeploymentObjects",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
JSON

    cat >"${TEMP_DIR}/bucket-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadForStaticWebsite",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
  }]
}
JSON

    cat >"${TEMP_DIR}/website.json" <<'JSON'
{
  "IndexDocument": {"Suffix": "index.html"},
  "ErrorDocument": {"Key": "404.html"}
}
JSON
}

ensure_oidc_provider() {
    info "GitHub-OIDC-Provider sicherstellen"
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
        local clients
        clients="$(aws iam get-open-id-connect-provider \
            --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" \
            --query 'ClientIDList' --output json)"
        if ! jq -e --arg audience "${OIDC_AUDIENCE}" 'index($audience) != null' <<<"${clients}" >/dev/null; then
            run_aws iam add-client-id-to-open-id-connect-provider \
                --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" \
                --client-id "${OIDC_AUDIENCE}" >/dev/null || \
                fail "Audience ${OIDC_AUDIENCE} konnte nicht ergänzt werden."
        fi
        success "OIDC-Provider vorhanden und Audience geprüft"
    else
        OIDC_PROVIDER_ARN="$(run_aws iam create-open-id-connect-provider \
            --url "${OIDC_URL}" \
            --client-id-list "${OIDC_AUDIENCE}" \
            --thumbprint-list "${OIDC_THUMBPRINT}" \
            --query 'OpenIDConnectProviderArn' --output text)" || \
            fail "GitHub-OIDC-Provider konnte nicht erstellt werden."
        success "OIDC-Provider erstellt"
    fi
}

ensure_bucket() {
    info "S3-Website-Bucket sicherstellen"
    if aws s3api head-bucket --bucket "${BUCKET_NAME}" >/dev/null 2>&1; then
        local location
        location="$(aws s3api get-bucket-location --bucket "${BUCKET_NAME}" --query 'LocationConstraint' --output text)"
        [[ "${location}" != "None" && "${location}" != "null" ]] || location="us-east-1"
        [[ "${location}" == "${REGION}" ]] || fail "Bucket ${BUCKET_NAME} liegt in ${location}, erwartet wurde ${REGION}."
        success "Bucket existiert und liegt in ${REGION}"
    else
        if [[ "${REGION}" == "us-east-1" ]]; then
            run_aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" >/dev/null || \
                fail "Bucket konnte nicht erstellt werden. Möglicherweise ist der Name weltweit bereits vergeben."
        else
            run_aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
                --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null || \
                fail "Bucket konnte nicht erstellt werden. Möglicherweise ist der Name weltweit bereits vergeben."
        fi
        success "Bucket erstellt"
    fi

    run_aws s3api put-bucket-ownership-controls --bucket "${BUCKET_NAME}" \
        --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null || \
        fail "Bucket Ownership Controls konnten nicht gesetzt werden."
    run_aws s3api put-bucket-website --bucket "${BUCKET_NAME}" \
        --website-configuration "file://${TEMP_DIR}/website.json" >/dev/null || \
        fail "Static Website Hosting konnte nicht aktiviert werden."
    run_aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
        --public-access-block-configuration \
        'BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false' >/dev/null || \
        fail "Block Public Access konnte für den Bucket nicht deaktiviert werden."
    run_aws s3api put-bucket-policy --bucket "${BUCKET_NAME}" \
        --policy "file://${TEMP_DIR}/bucket-policy.json" >/dev/null || \
        fail "Öffentliche Bucket-Policy konnte nicht gesetzt werden. Eventuell blockiert eine kontoweite S3-Public-Access-Einstellung öffentliche Policies."
    success "Static Website Hosting und öffentlicher Lesezugriff konfiguriert"
}

canonical_policy_file() {
    python3 - "$1" <<'PY'
import json, sys, urllib.parse
with open(sys.argv[1], encoding="utf-8") as f:
    value = json.load(f)
if isinstance(value, str):
    value = json.loads(urllib.parse.unquote(value))
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

ensure_managed_policy() {
    info "Kundenverwaltete S3-Policy sicherstellen (kein iam:PutRolePolicy)"
    local policy_file="${TEMP_DIR}/permission-policy.json"
    if aws iam get-policy --policy-arn "${MANAGED_POLICY_ARN}" >/dev/null 2>&1; then
        local default_version desired current version_count oldest
        default_version="$(aws iam get-policy --policy-arn "${MANAGED_POLICY_ARN}" --query 'Policy.DefaultVersionId' --output text)"
        aws iam get-policy-version --policy-arn "${MANAGED_POLICY_ARN}" \
            --version-id "${default_version}" --query 'PolicyVersion.Document' --output json \
            >"${TEMP_DIR}/current-policy.json"
        desired="$(canonical_policy_file "${policy_file}")"
        current="$(canonical_policy_file "${TEMP_DIR}/current-policy.json")"
        if [[ "${desired}" == "${current}" ]]; then
            success "Managed Policy ist bereits aktuell"
            return
        fi

        version_count="$(aws iam list-policy-versions --policy-arn "${MANAGED_POLICY_ARN}" --query 'length(Versions)' --output text)"
        if (( version_count >= 5 )); then
            oldest="$(aws iam list-policy-versions --policy-arn "${MANAGED_POLICY_ARN}" \
                --query 'sort_by(Versions[?IsDefaultVersion==`false`],&CreateDate)[0].VersionId' --output text)"
            [[ -z "${oldest}" || "${oldest}" == "None" ]] || \
                run_aws iam delete-policy-version --policy-arn "${MANAGED_POLICY_ARN}" --version-id "${oldest}" >/dev/null
        fi
        run_aws iam create-policy-version --policy-arn "${MANAGED_POLICY_ARN}" \
            --policy-document "file://${policy_file}" --set-as-default >/dev/null || \
            fail "Managed Policy konnte nicht aktualisiert werden (benötigt iam:CreatePolicyVersion)."
        success "Managed Policy aktualisiert"
    else
        MANAGED_POLICY_ARN="$(run_aws iam create-policy \
            --policy-name "${MANAGED_POLICY_NAME}" \
            --description "S3 deployment permissions for ${REPO_SLUG}" \
            --policy-document "file://${policy_file}" \
            --query 'Policy.Arn' --output text)" || \
            fail "Managed Policy konnte nicht erstellt werden (benötigt iam:CreatePolicy)."
        success "Managed Policy erstellt"
    fi
}

ensure_role() {
    info "IAM-Rolle mit strikter main-Trust-Policy sicherstellen"
    if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
        success "IAM-Rolle existiert bereits"

        CURRENT_TRUST_SUB="$(
            aws iam get-role \
                --role-name "${ROLE_NAME}" \
                --query "Role.AssumeRolePolicyDocument.Statement[?Action=='sts:AssumeRoleWithWebIdentity'].Condition.StringLike.\"token.actions.githubusercontent.com:sub\" | [0]" \
                --output text
        )"

        EXPECTED_TRUST_SUB="repo:${GITHUB_USERNAME}/${REPO_NAME}:ref:refs/heads/main"

        if [[ "${CURRENT_TRUST_SUB}" == "${EXPECTED_TRUST_SUB}" ]]; then
            success "Vorhandene Trust Policy ist bereits korrekt auf main eingeschränkt"
        else
            fail "Die IAM-Rolle '${ROLE_NAME}' existiert bereits, aber ihre Trust Policy entspricht nicht der gewünschten Konfiguration.

Aktuell:
  ${CURRENT_TRUST_SUB}

Erwartet:
  ${EXPECTED_TRUST_SUB}

Die AWS-Sandbox erlaubt iam:UpdateAssumeRolePolicy nicht.

Verwende deshalb eine neue Sandbox oder lösche die vorhandene Rolle,
falls iam:DeleteRole erlaubt ist, und starte das Skript erneut."
        fi
    else
        info "IAM-Rolle mit strikter main-Trust-Policy erstellen"

        CREATED_ROLE_ARN="$(
            aws iam create-role \
                --role-name "${ROLE_NAME}" \
                --description "GitHub Actions deployment role for ${GITHUB_USERNAME}/${REPO_NAME} main branch" \
                --assume-role-policy-document "file://${MAIN_TRUST_POLICY_FILE}" \
                --query 'Role.Arn' \
                --output text
        )" || fail "Die IAM-Rolle konnte nicht erstellt werden."

        ROLE_ARN="${CREATED_ROLE_ARN}"

        success "IAM-Rolle mit strikter main-Trust-Policy erstellt"
    fi

    # Eine vorhandene Rolle kann einen IAM-Pfad besitzen. Deshalb wird die
    # tatsächliche ARN gelesen, statt eine Root-Pfad-ARN vorauszusetzen.
    ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

    if aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
        --query "AttachedPolicies[?PolicyArn=='${MANAGED_POLICY_ARN}'].PolicyArn" --output text | \
        grep -Fxq "${MANAGED_POLICY_ARN}"; then
        success "Managed Policy ist bereits an der Rolle angehängt"
    else
        local attempt
        for attempt in 1 2 3 4 5; do
            if aws iam attach-role-policy --role-name "${ROLE_NAME}" \
                --policy-arn "${MANAGED_POLICY_ARN}" >/dev/null 2>&1; then
                success "Managed Policy mit iam:AttachRolePolicy angehängt"
                return
            fi
            sleep $(( attempt * 2 ))
        done
        fail "Managed Policy konnte nicht angehängt werden. Die Sandbox benötigt iam:AttachRolePolicy; iam:PutRolePolicy wird absichtlich nicht verwendet."
    fi
}

bootstrap_upload() {
    info "Lokalen Astro-Build initial in S3 veröffentlichen"
    run_aws s3 sync "${PROJECT_DIR_ABS}/dist/" "s3://${BUCKET_NAME}/" --delete >/dev/null || \
        fail "Der lokale Bootstrap-Upload nach S3 ist fehlgeschlagen."
    success "dist/ wurde mit --delete in den Website-Bucket synchronisiert"
}

write_workflow() {
    info "GitHub-Actions-Workflow schreiben"
    mkdir -p "${PROJECT_DIR_ABS}/.github/workflows"
    cat >"${PROJECT_DIR_ABS}/.github/workflows/deploy.yml" <<YAML
name: Deploy Astro to S3

on:
  push:
    branches:
      - main

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ${REGION}
  S3_BUCKET: ${BUCKET_NAME}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version-file: '.nvmrc'
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Build Astro site
        run: npm run build

      - name: Configure temporary AWS credentials through OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${ROLE_ARN}
          aws-region: \${{ env.AWS_REGION }}

      - name: Verify assumed identity
        run: aws sts get-caller-identity

      - name: Deploy dist to S3
        if: github.ref == 'refs/heads/main'
        run: aws s3 sync ./dist "s3://\${S3_BUCKET}" --delete
YAML
    success "Workflow angelegt: .github/workflows/deploy.yml"
}

ensure_git_identity() {
    local git_name git_email
    git_name="$(git config --get user.name || true)"
    git_email="$(git config --get user.email || true)"
    if [[ -z "${git_name}" ]]; then
        prompt_default git_name "Git-Autorenname" "${GITHUB_USERNAME}"
        git config user.name "${git_name}"
    fi
    if [[ -z "${git_email}" ]]; then
        prompt_required git_email "Git-Autoren-E-Mail (z. B. GitHub-No-Reply-Adresse)"
        git config user.email "${git_email}"
    fi
}

ensure_git_and_repo() {
    info "Git-Repository und GitHub-Repository sicherstellen"
    cd "${PROJECT_DIR_ABS}"
    if [[ ! -d .git ]]; then
        git init -b main
    elif git show-ref --verify --quiet refs/heads/main; then
        git checkout main
    else
        git checkout -b main
    fi
    ensure_git_identity

    if gh repo view "${REPO_SLUG}" >/dev/null 2>&1; then
        success "GitHub-Repository existiert bereits: ${REPO_SLUG}"
    else
        gh repo create "${REPO_SLUG}" "--${REPO_VISIBILITY}" --description "Astro website deployed to Amazon S3 with GitHub Actions OIDC"
        success "GitHub-Repository erstellt: ${REPO_SLUG}"
    fi

    local expected_https expected_ssh origin_url=""
    expected_https="https://github.com/${REPO_SLUG}.git"
    expected_ssh="git@github.com:${REPO_SLUG}.git"
    if git remote get-url origin >/dev/null 2>&1; then
        origin_url="$(git remote get-url origin)"
        case "${origin_url}" in
            "${expected_https}"|"${expected_ssh}"|"${expected_https%.git}"|"ssh://git@github.com/${REPO_SLUG}.git") ;;
            *) fail "Remote 'origin' zeigt auf ${origin_url}, erwartet wurde ${REPO_SLUG}. Aus Sicherheitsgründen wird er nicht automatisch überschrieben." ;;
        esac
    else
        git remote add origin "${expected_https}"
    fi

    git add --all
    if git diff --cached --quiet; then
        git commit --allow-empty -m "chore: trigger Astro deployment"
    else
        git commit -m "feat: add Astro S3 deployment with GitHub OIDC"
    fi
    git push --set-upstream origin main
    success "main wurde gepusht; dadurch wurde Build und Deployment ausgelöst"
}

wait_for_workflow_run() {
    local sha="$1" expected_result="$2" label="$3" run_id="" run_url="" attempt exit_code
    info "${label}: GitHub-Actions-Lauf suchen"
    for attempt in $(seq 1 60); do
        run_id="$(gh run list --repo "${REPO_SLUG}" --workflow deploy.yml --commit "${sha}" \
            --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
        if [[ -n "${run_id}" ]]; then break; fi
        sleep 2
    done
    [[ -n "${run_id}" ]] || fail "Für Commit ${sha} wurde innerhalb von 120 Sekunden kein Workflow-Lauf gefunden. Prüfe den Actions-Tab und Repository-Einstellungen."

    run_url="$(gh run view "${run_id}" --repo "${REPO_SLUG}" --json url --jq .url 2>/dev/null || true)"
    [[ -z "${run_url}" ]] || echo "Workflow: ${run_url}"
    set +e
    gh run watch "${run_id}" --repo "${REPO_SLUG}" --exit-status
    exit_code=$?
    set -e

    case "${expected_result}" in
        success)
            (( exit_code == 0 )) || {
                gh run view "${run_id}" --repo "${REPO_SLUG}" --log-failed || true
                fail "${label} ist fehlgeschlagen."
            }
            success "${label} war erfolgreich"
            ;;
        failure)
            (( exit_code != 0 )) || fail "Der Sicherheitstest sollte mit strikter main-Trust-Policy fehlschlagen, war aber erfolgreich. Trust Policy unverzüglich prüfen."
            local failed_log
            failed_log="$(gh run view "${run_id}" --repo "${REPO_SLUG}" --log-failed 2>&1 || true)"
            printf '%s\n' "${failed_log}" | tail -n 80
            if grep -Eqi 'AssumeRoleWithWebIdentity|not authorized|Could not assume role|AccessDenied' <<<"${failed_log}"; then
                success "Erwarteter OIDC/AssumeRole-Fehler wurde beobachtet"
            else
                fail "Der Lauf ist fehlgeschlagen, aber nicht erkennbar am erwarteten OIDC/AssumeRole-Fehler. Logs prüfen: ${run_url}"
            fi
            ;;
    esac
}

verify_strict_trust() {
    local actual_sub
    actual_sub="$(aws iam get-role --role-name "${ROLE_NAME}" --output json | \
        jq -r '.Role.AssumeRolePolicyDocument.Statement[] | select(.Action == "sts:AssumeRoleWithWebIdentity") | .Condition.StringLike["token.actions.githubusercontent.com:sub"]')"
    [[ "${actual_sub}" == "${OIDC_SUBJECT}" ]] || \
        fail "Trust Policy ist nicht strikt. Gefunden: ${actual_sub}"
    success "Verifiziert: Trust Policy erlaubt ausschließlich ${OIDC_SUBJECT}"
}

run_security_test() {
    info "OPTIONALER OIDC-Branch-Sicherheitstest"
    cat <<'TEXT'
Der Test arbeitet in einem separaten Feature-Branch. Dort wird der Workflow
vorübergehend für alle Branches aktiviert. Der Deploy-Schritt hat zusätzlich
eine feste main-Bedingung und kann aus dem Feature-Branch niemals den
Produktions-Bucket verändern.

Phase 1: Strikte Trust Policy bleibt aktiv; OIDC-Rollenübernahme muss scheitern.
Phase 2 (optional): Trust Policy wird nur kurz auf repo:<owner>/<repo>:* erweitert;
                   OIDC muss funktionieren, aber das S3-Deployment wird übersprungen.
Danach setzt ein EXIT/SIGNAL-Schutz die Trust Policy wieder auf main zurück.
TEXT
    confirm "Sicherheitstest jetzt starten?" no || return 0

    cd "${PROJECT_DIR_ABS}"
    [[ -z "$(git status --porcelain)" ]] || fail "Für den Sicherheitstest muss der Git-Arbeitsbaum sauber sein."
    git checkout main
    git pull --ff-only origin main
    git branch -D "${SECURITY_TEST_BRANCH}" >/dev/null 2>&1 || true
    git checkout -b "${SECURITY_TEST_BRANCH}"

    python3 - "${PROJECT_DIR_ABS}/.github/workflows/deploy.yml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "    branches:\n      - main\n"
new = "    branches:\n      - \"**\"\n"
if old not in s:
    raise SystemExit("Erwarteter main-Trigger wurde im Workflow nicht gefunden")
p.write_text(s.replace(old, new, 1))
PY
    printf '\nOIDC security test marker: %s\n' "$(date -u +%FT%TZ)" >> SECURITY_TEST.md
    git add .github/workflows/deploy.yml SECURITY_TEST.md
    git commit -m "test: verify strict OIDC branch restriction"
    git push --set-upstream origin "${SECURITY_TEST_BRANCH}" --force-with-lease
    local strict_sha
    strict_sha="$(git rev-parse HEAD)"
    wait_for_workflow_run "${strict_sha}" failure "Branch-Test mit strikter Trust Policy"

    if confirm "Trust Policy für Phase 2 kurz auf repo:${REPO_SLUG}:* erweitern?" no; then
        local wildcard_policy="${TEMP_DIR}/trust-wildcard.json"
        cat >"${wildcard_policy}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "GitHubActionsOidcTrustTemporarySecurityTest",
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": "repo:${REPO_SLUG}:*"}
    }
  }]
}
JSON
        TRUST_POLICY_WIDENED=1
        run_aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
            --policy-document "file://${wildcard_policy}" >/dev/null || \
            fail "Temporäre Trust-Policy-Erweiterung ist fehlgeschlagen."
        warning "Trust Policy ist JETZT vorübergehend erweitert. Automatische Rücksetzung ist scharf."

        git commit --allow-empty -m "test: verify temporary wildcard OIDC trust"
        git push origin "${SECURITY_TEST_BRANCH}"
        local wildcard_sha
        wildcard_sha="$(git rev-parse HEAD)"
        wait_for_workflow_run "${wildcard_sha}" success "Branch-Test mit temporär erweiterter Trust Policy"

        run_aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
            --policy-document "file://${MAIN_TRUST_POLICY_FILE}" >/dev/null || \
            fail "Strikte Trust Policy konnte nach dem Test nicht wiederhergestellt werden."
        TRUST_POLICY_WIDENED=0
        verify_strict_trust
    fi

    git checkout main
    git branch -D "${SECURITY_TEST_BRANCH}" >/dev/null 2>&1 || true
    if confirm "Temporären Remote-Testbranch löschen?" yes; then
        git push origin --delete "${SECURITY_TEST_BRANCH}" >/dev/null 2>&1 || warning "Remote-Testbranch konnte nicht gelöscht werden. Er ist wegen der strikten main-Trust-Policy dennoch nicht deploy-berechtigt."
    fi
    verify_strict_trust
    success "Sicherheitstest abgeschlossen; Produktions-Trust ist strikt auf main gesetzt"
}

verify_aws_setup() {
    info "AWS-Konfiguration abschließend verifizieren"
    aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" \
        --query '{Audience:ClientIDList,Thumbprints:ThumbprintList}' --output json
    aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
        --query 'AttachedPolicies[*].{PolicyName:PolicyName,PolicyArn:PolicyArn}' --output table
    aws s3api get-bucket-website --bucket "${BUCKET_NAME}" --output json
    verify_strict_trust
}

verify_website_reachable() {
    info "Öffentliche S3-Website erreichen"
    local attempt
    for attempt in $(seq 1 30); do
        if curl --fail --silent --show-error --max-time 10 "${WEBSITE_URL}/" >/dev/null 2>&1; then
            success "Website ist öffentlich erreichbar: ${WEBSITE_URL}"
            return 0
        fi
        sleep 2
    done
    fail "Die Website war nach 60 Sekunden nicht erreichbar: ${WEBSITE_URL}. Prüfe Bucket Policy, kontoweites Block Public Access und den Regions-Endpunkt."
}

print_summary() {
    cat <<EOF

============================================================
 Einrichtung vollständig abgeschlossen
============================================================

Lokales Projekt:        ${PROJECT_DIR_ABS}
GitHub-Repository:      https://github.com/${REPO_SLUG}
GitHub Actions:         https://github.com/${REPO_SLUG}/actions
AWS Account ID:         ${ACCOUNT_ID}
AWS Region:             ${REGION}
OIDC Provider ARN:      ${OIDC_PROVIDER_ARN}
IAM Role ARN:           ${ROLE_ARN}
Managed Policy ARN:     ${MANAGED_POLICY_ARN}
S3 Bucket:              ${BUCKET_NAME}
S3 Website URL:         ${WEBSITE_URL}
Erlaubter OIDC-Branch:  main

Wichtige Eigenschaften:
- Keine dauerhaften AWS-Schlüssel in GitHub.
- Workflow: checkout@v4, setup-node@v4/Node 20, npm ci, Build,
  configure-aws-credentials@v4, get-caller-identity, S3 sync --delete.
- S3-Rechte: kundenverwaltete Policy + iam:AttachRolePolicy.
- iam:PutRolePolicy wird nicht verwendet.
- Ein Feature-Branch kann den S3-Deploy-Schritt nicht ausführen.

Nächste Tests:
1. Öffne die Actions-URL und prüfe den grünen Lauf auf main.
2. Öffne ${WEBSITE_URL} und prüfe die Astro-Seite.
3. Ändere src/pages/index.astro, committe und pushe nach main.
4. Beobachte: Push -> Build -> OIDC-Rollenübernahme -> S3-Synchronisierung.

Lokal entwickeln:
  cd ${PROJECT_DIR_ABS@Q}
  npm run dev

Hinweis: aws s3 sync gleicht dist/ mit dem Bucket ab. --delete entfernt
Objekte im Bucket, die im aktuellen dist/ nicht mehr existieren.

Einordnung der Astro-Kommandos:
- npm run dev startet einen Entwicklungsserver mit Live Reload und erzeugt
  kein deploybares Produktionsverzeichnis.
- npm run build erzeugt die optimierten statischen Dateien in dist/;
  npm run preview stellt genau diesen Build lokal zur Kontrolle bereit.
- S3 benötigt dist/, weil dort statische Dateien liegen. Ein kurzlebiger
  lokaler Dev-Server kann nicht in einen S3-Bucket hochgeladen werden.
EOF
}

detect_linux_distribution() {
    DISTRO_ID="unknown"
    DISTRO_FAMILY="unknown"
    if [[ ! -f /etc/os-release ]]; then return; fi
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    case "${DISTRO_ID}" in
        arch|cachyos|manjaro|endeavouros) DISTRO_FAMILY="arch" ;;
        debian) DISTRO_FAMILY="debian" ;;
        ubuntu|linuxmint|pop) DISTRO_FAMILY="ubuntu" ;;
        *)
            if [[ "${ID_LIKE:-}" == *"arch"* ]]; then DISTRO_FAMILY="arch"
            elif [[ "${ID_LIKE:-}" == *"ubuntu"* ]]; then DISTRO_FAMILY="ubuntu"
            elif [[ "${ID_LIKE:-}" == *"debian"* ]]; then DISTRO_FAMILY="debian"
            fi
            ;;
    esac
}

check_node_version() {
    if ! command -v node >/dev/null 2>&1; then return 1; fi
    local version major
    version="$(node --version)"
    major="${version#v}"; major="${major%%.*}"
    (( major >= 22 ))
}

preflight_check() {
    detect_linux_distribution
    info "Linux-Preflight-Check"
    echo "Distribution : ${DISTRO_ID}"
    echo "Familie      : ${DISTRO_FAMILY}"
    echo "Architektur  : $(uname -m)"
    echo
    printf '%-16s %-10s %s\n' "Tool" "Status" "Version"
    printf '%-16s %-10s %s\n' "----------------" "----------" "------------------------------"
    local errors=0
    check_one() {
        local cmd="$1" vcmd="$2"
        if command -v "${cmd}" >/dev/null 2>&1; then
            local v
            v="$(eval "${vcmd}" 2>/dev/null | head -n1 || true)"
            printf '%-16s %-10s %s\n' "${cmd}" "OK" "${v}"
        else
            printf '%-16s %-10s %s\n' "${cmd}" "FEHLT" "-"
            errors=$((errors+1))
        fi
    }
    check_one git "git --version"
    check_one node "node --version"
    check_one npm "npm --version"
    check_one gh "gh --version"
    check_one aws "aws --version"
    check_one jq "jq --version"
    check_one python3 "python3 --version"
    check_one curl "curl --version"
    check_one unzip "unzip -v"
    echo
    if ! check_node_version; then
        echo "FEHLER: Node.js >= 22 erforderlich (gefunden: $(node --version 2>/dev/null || echo 'nicht installiert'))."
        errors=$((errors+1))
    fi
    if [[ -z "$(git config --global user.name 2>/dev/null)" || -z "$(git config --global user.email 2>/dev/null)" ]]; then
        echo "Git-Konfiguration unvollständig (user.name/user.email)."
        errors=$((errors+1))
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "GitHub CLI nicht authentifiziert (gh auth login)."
        errors=$((errors+1))
    fi
    echo "AWS Credentials: werden später abgefragt (kein 'aws configure' nötig)."
    if (( errors > 0 )); then
        echo
        echo "Bitte fehlende Voraussetzungen installieren/konfigurieren und Skript erneut starten."
        fail "${errors} Preflight-Prüfung(en) fehlgeschlagen."
    fi
    success "Preflight OK"
}

main() {
    echo "Astro + AWS S3 + GitHub OIDC Setup v${SCRIPT_VERSION}"
    TEMP_DIR="$(mktemp -d)"

    preflight_check
    check_prerequisites
    check_github_auth
    collect_project_inputs
    ensure_local_project
    smoke_test_server dev 4321 "Astro-Dev-Server"
    smoke_test_server preview 4322 "Astro-Production-Preview"

    ensure_github_repo_and_ids

    collect_aws_credentials
    collect_bucket_name

    echo
    echo "Geplante Konfiguration:"
    echo "  Repository:      ${REPO_SLUG}"
    echo "  Lokales Projekt: ${PROJECT_DIR_ABS}"
    echo "  AWS-Konto:       ${ACCOUNT_ID}"
    echo "  Region:          ${REGION}"
    echo "  Bucket:          ${BUCKET_NAME}"
    echo "  Rolle:           ${ROLE_NAME}"
    echo "  Trust:           ${OIDC_SUBJECT}"
    echo "  IAM-Berechtigung: Managed Policy + AttachRolePolicy"
    confirm "Diese Konfiguration anwenden?" no || { echo "Abgebrochen."; return 0; }

    ensure_oidc_provider
    write_policy_files
    ensure_bucket
    ensure_managed_policy
    ensure_role
    verify_strict_trust
    bootstrap_upload

    write_workflow
    ensure_git_and_repo
    local main_sha
    main_sha="$(git -C "${PROJECT_DIR_ABS}" rev-parse HEAD)"
    wait_for_workflow_run "${main_sha}" success "Produktions-Deployment auf main"

    verify_aws_setup
    verify_website_reachable
    run_security_test
    print_summary
}

main "$@"
