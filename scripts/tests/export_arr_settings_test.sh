#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/export_arr_settings.sh against a fake Sonarr/Radarr (`curl` stubbed with
# fixture JSON shaped like the real API) and `docker` stubbed for the final preview.
#
# Usage: bash scripts/tests/export_arr_settings_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    recyclarr_dir="$repo_dir/config/recyclarr"
    export FIXTURES_DIR="$sandbox/fixtures"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/media" "$recyclarr_dir/configs" \
        "$recyclarr_dir/custom-formats/sonarr" "$recyclarr_dir/custom-formats/radarr" "$sandbox/bin" "$FIXTURES_DIR"
    cp "$SCRIPTS_DIR/export_arr_settings.sh" "$SCRIPTS_DIR/preview_recyclarr.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'services:\n  recyclarr:\n    image: ghcr.io/recyclarr/recyclarr:9.9.9\n' > "$repo_dir/stacks/media/compose.yml"
    printf 'previous content\n' > "$recyclarr_dir/configs/instances.yml"

    # Sonarr: two formats whose names collide once lowercased, one French language format,
    # one profile with a disallowed quality and a group as cutoff. The API lists qualities lowest first.
    cat > "$FIXTURES_DIR/sonarr-customformat.json" <<'JSON'
[
  {"id": 1, "name": "x264", "includeCustomFormatWhenRenaming": false, "specifications": [
    {"name": "x264", "implementation": "ReleaseTitleSpecification", "implementationName": "Release Title", "negate": false, "required": true,
     "fields": [{"order": 0, "name": "value", "label": "Regular Expression", "value": "[xh][ ._-]?264", "type": "textbox", "advanced": false}]}]},
  {"id": 2, "name": "X264", "includeCustomFormatWhenRenaming": false, "specifications": []},
  {"id": 3, "name": "VOSTFR", "includeCustomFormatWhenRenaming": true, "specifications": [
    {"name": "French", "implementation": "LanguageSpecification", "negate": false, "required": true,
     "fields": [{"name": "value", "value": 2}, {"name": "exceptLanguage", "value": false}]}]}
]
JSON
    cat > "$FIXTURES_DIR/sonarr-qualityprofile.json" <<'JSON'
[{"id": 1, "name": "HD-1080p", "upgradeAllowed": true, "cutoff": 1001,
  "minFormatScore": 0, "cutoffFormatScore": 10000, "minUpgradeFormatScore": 1,
  "items": [
    {"quality": {"id": 1, "name": "SDTV"}, "items": [], "allowed": false},
    {"quality": {"id": 7, "name": "Bluray-1080p"}, "items": [], "allowed": true},
    {"id": 1001, "name": "WEB 1080p", "allowed": true, "items": [
      {"quality": {"id": 3, "name": "WEBDL-1080p"}, "items": [], "allowed": true},
      {"quality": {"id": 15, "name": "WEBRip-1080p"}, "items": [], "allowed": true}]}
  ],
  "formatItems": [{"format": 1, "name": "x264", "score": 0}, {"format": 2, "name": "X264", "score": 5},
                  {"format": 3, "name": "VOSTFR", "score": -10000}]}]
JSON
    printf '[]\n' > "$FIXTURES_DIR/radarr-customformat.json"
    printf '[]\n' > "$FIXTURES_DIR/radarr-qualityprofile.json"

    export STUB_FAILING_PORT=none DOCKER_CALLS_LOG="$sandbox/docker-calls.log"
    touch "$DOCKER_CALLS_LOG"
    cat > "$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in *":$STUB_FAILING_PORT/"*) exit 22 ;; esac
case "$url" in
    *:8989/api/v3/customformat) cat "$FIXTURES_DIR/sonarr-customformat.json" ;;
    *:8989/api/v3/qualityprofile) cat "$FIXTURES_DIR/sonarr-qualityprofile.json" ;;
    *:7878/api/v3/customformat) cat "$FIXTURES_DIR/radarr-customformat.json" ;;
    *:7878/api/v3/qualityprofile) cat "$FIXTURES_DIR/radarr-qualityprofile.json" ;;
    *) exit 22 ;;
esac
STUB
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
STUB
    chmod +x "$sandbox/bin/curl" "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"
    export SONARR_API_KEY=test RADARR_API_KEY=test SONARR_URL=http://nas:8989 RADARR_URL=http://nas:7878
}

in_sandbox() {
    create_sandbox
    "$@"
}

run_export() {
    bash "$repo_dir/scripts/export_arr_settings.sh" < /dev/null > "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      export_arr_settings.sh | /' "$sandbox/output" 2>/dev/null || true
    return 1
}

# $1 = file, then the expected content on stdin
assert_content() {
    local expected
    expected=$(cat)
    if [ "$(cat "$1")" != "$expected" ]; then
        echo "      unexpected $(basename "$1"):"
        diff <(printf '%s\n' "$expected") "$1" | sed 's/^/      /'
        return 1
    fi
}

test_writes_each_custom_format_as_an_exact_copy() {
    run_export || fail_with "expected success"
    assert_content "$recyclarr_dir/custom-formats/sonarr/homelab-sonarr-x264-1.json" <<'JSON'
{
  "trash_id": "homelab-sonarr-x264-1",
  "name": "x264",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "x264",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": true,
      "fields": {
        "value": "[xh][ ._-]?264"
      }
    }
  ]
}
JSON
}

test_gives_colliding_names_distinct_ids() {
    run_export || fail_with "expected success"
    for file in homelab-sonarr-x264-1.json homelab-sonarr-x264-2.json homelab-sonarr-vostfr.json; do
        [ -f "$recyclarr_dir/custom-formats/sonarr/$file" ] || fail_with "missing custom-formats/sonarr/$file"
    done
}

test_writes_profiles_in_screen_order_with_their_scores() {
    run_export || fail_with "expected success"
    assert_content "$recyclarr_dir/configs/instances.yml" <<'YAML'
# Sonarr/Radarr quality profiles and custom formats, synced both ways by scripts/sync_arr_settings.sh
# on the NAS: changes made here are applied to the apps, changes made in the apps come back as a pull
# request. Check a change before pushing it: scripts/preview_recyclarr.sh.

sonarr:
  series:
    base_url: !env_var SONARR_BASE_URL
    api_key: !env_var SONARR_API_KEY
    delete_old_custom_formats: true
    quality_profiles:
      - name: "HD-1080p"
        upgrade:
          allowed: true
          until_quality: "WEB 1080p"
          until_score: 10000
        min_format_score: 0
        min_upgrade_format_score: 1
        reset_unmatched_scores:
          enabled: true
        quality_sort: top
        qualities:
          - name: "WEB 1080p"
            qualities:
              - "WEBRip-1080p"
              - "WEBDL-1080p"
          - name: "Bluray-1080p"
          - name: "SDTV"
            enabled: false
    custom_formats:
      - trash_ids:
          - homelab-sonarr-vostfr
        assign_scores_to:
          - name: "HD-1080p"
            score: -10000
      - trash_ids:
          - homelab-sonarr-x264-1
      - trash_ids:
          - homelab-sonarr-x264-2
        assign_scores_to:
          - name: "HD-1080p"
            score: 5

radarr:
  movies:
    base_url: !env_var RADARR_BASE_URL
    api_key: !env_var RADARR_API_KEY
    delete_old_custom_formats: true
YAML
}

test_removes_custom_formats_deleted_in_the_app() {
    printf '{}\n' > "$recyclarr_dir/custom-formats/sonarr/homelab-sonarr-deleted.json"
    run_export || fail_with "expected success"
    [ ! -e "$recyclarr_dir/custom-formats/sonarr/homelab-sonarr-deleted.json" ] || fail_with "the stale custom format file must be removed"
}

test_writes_nothing_when_an_app_does_not_answer() {
    export STUB_FAILING_PORT=7878
    printf '{}\n' > "$recyclarr_dir/custom-formats/sonarr/homelab-sonarr-existing.json"
    if run_export; then
        fail_with "expected a failure"
    fi
    grep -q 'Could not read http://nas:7878' "$sandbox/output" || fail_with "expected the failing URL in the error"
    assert_content "$recyclarr_dir/configs/instances.yml" <<<'previous content'
    [ -e "$recyclarr_dir/custom-formats/sonarr/homelab-sonarr-existing.json" ] || fail_with "existing files must be left alone"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "no preview must run"
}

test_handles_apps_bigger_than_the_argument_limit() {
    # 600 formats of ~500 bytes: well past the kernel's 128 KB limit for a single argument.
    jq -n '[range(0; 600) | {id: (. + 100), name: "Format \(.)", includeCustomFormatWhenRenaming: false,
        specifications: [{name: "spec", implementation: "ReleaseTitleSpecification", negate: false, required: true,
                          fields: [{name: "value", value: ("x" * 400)}]}]}]' > "$FIXTURES_DIR/sonarr-customformat.json"
    run_export || fail_with "expected success"
    [ "$(find "$recyclarr_dir/custom-formats/sonarr" -name '*.json' | wc -l)" -eq 600 ] || fail_with "expected 600 custom format files"
    grep -q 'homelab-sonarr-format-599' "$recyclarr_dir/configs/instances.yml" || fail_with "expected every format in instances.yml"
}

test_runs_the_preview_at_the_end() {
    run_export || fail_with "expected success"
    grep -q 'sync --preview$' "$DOCKER_CALLS_LOG" || fail_with "expected the preview to run"
}

run_test "it writes each custom format as an exact copy, with a stable trash_id" in_sandbox test_writes_each_custom_format_as_an_exact_copy
run_test "it gives custom formats whose names collide distinct ids" in_sandbox test_gives_colliding_names_distinct_ids
run_test "it writes the profiles in screen order, with their cutoff, upgrade rules and scores" in_sandbox test_writes_profiles_in_screen_order_with_their_scores
run_test "it removes the files of custom formats deleted in the app" in_sandbox test_removes_custom_formats_deleted_in_the_app
run_test "it writes nothing when an app doesn't answer" in_sandbox test_writes_nothing_when_an_app_does_not_answer
run_test "it handles apps whose settings are bigger than the kernel's argument limit" in_sandbox test_handles_apps_bigger_than_the_argument_limit
run_test "it runs the preview at the end" in_sandbox test_runs_the_preview_at_the_end

finish_tests
