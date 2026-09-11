# Sends changes made on the NAS to GitHub as a pull request, merged once CI passes. Source it
# after lib.sh, don't run it.
#
# The caller sets REPO_DIR, REPO_SLUG (github_repo_slug) and work_dir (a private scratch
# folder, deleted on exit). The token comes from .github-token (fine-grained, this repository
# only: Contents and Pull requests, read and write) and stays in root-only files under
# work_dir, never on a command line.

GITHUB_TOKEN_FILE="$REPO_DIR/.github-token"

# Prints owner/name of the repository behind the origin remote.
github_repo_slug() {
    local slug
    slug="${GITHUB_REPOSITORY:-$(git -C "$REPO_DIR" remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"
    if [[ ! "$slug" =~ ^[^/]+/[^/]+$ ]]; then
        log "ERROR: can't tell the GitHub repository from the origin remote ($slug)." >&2
        return 1
    fi
    printf '%s\n' "$slug"
}

use_github_token() {
    if [ ! -s "$GITHUB_TOKEN_FILE" ]; then
        log "ERROR: $GITHUB_TOKEN_FILE is missing: the NAS can't send changes to GitHub without it."
        exit 1
    fi
    (
        umask 077
        printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
            "$(tr -d '[:space:]' < "$GITHUB_TOKEN_FILE")" > "$work_dir/github-headers"
        printf '#!/usr/bin/env bash\ncase "$1" in Username*) echo %q ;; *) tr -d "[:space:]" < %q ;; esac\n' \
            "${REPO_SLUG%%/*}" "$GITHUB_TOKEN_FILE" > "$work_dir/askpass"
    )
    chmod 700 "$work_dir/askpass"
    export GIT_ASKPASS="$work_dir/askpass" GIT_TERMINAL_PROMPT=0
}

# $1 = directory: receives a fresh clone of main to prepare the changes in.
clone_main() {
    use_github_token
    git clone --quiet --depth 1 --branch main "$(git -C "$REPO_DIR" remote get-url origin)" "$1"
}

# $1 = method, $2 = API path, $3 = JSON body (optional). Leaves the response in response.json and
# prints the HTTP status.
github_api() {
    local data_args=()
    if [ -n "${3:-}" ]; then
        data_args=(--data "$3")
    fi
    curl -sS -o "$work_dir/response.json" -w '%{http_code}' -X "$1" -H @"$work_dir/github-headers" \
        "${data_args[@]}" "https://api.github.com$2"
}

# $1 = what failed
github_error() {
    log "ERROR: could not $1: $(jq -r '.errors[0].message // .message // "no details"' "$work_dir/response.json" 2>/dev/null)"
    exit 1
}

# $1 = branch, $2 = title, $3 = description
open_or_update_pull_request() {
    local branch="$1" title="$2" description="$3" status number node_id request
    status=$(github_api GET "/repos/$REPO_SLUG/pulls?head=${REPO_SLUG%%/*}:$branch&state=open")
    [ "$status" = 200 ] || github_error "list the pull requests"
    number=$(jq -r '.[0].number // empty' "$work_dir/response.json")
    if [ -n "$number" ]; then
        log "Pull request #$number holds the latest changes."
        return 0
    fi

    request=$(jq -nc --arg head "$branch" --arg title "$title" --arg body "$description" \
        '{title: $title, head: $head, base: "main", body: $body}')
    status=$(github_api POST "/repos/$REPO_SLUG/pulls" "$request")
    [ "$status" = 201 ] || github_error "open the pull request"
    number=$(jq -r .number "$work_dir/response.json")
    node_id=$(jq -r .node_id "$work_dir/response.json")

    status=$(github_api PUT "/repos/$REPO_SLUG/pulls/$number/merge" '{"merge_method": "squash"}')
    if [ "$status" = 200 ]; then
        log "Pull request #$number opened and merged."
        return 0
    fi
    # Required checks still running: GitHub merges it by itself once they pass.
    request=$(jq -nc --arg id "$node_id" '{
        query: "mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { clientMutationId } }",
        variables: {id: $id}
    }')
    status=$(github_api POST /graphql "$request")
    if [ "$status" != 200 ] || jq -e '.errors' "$work_dir/response.json" > /dev/null; then
        github_error "turn on auto-merge for pull request #$number (is \"Allow auto-merge\" on in the repository settings?)"
    fi
    log "Pull request #$number opened: it merges once CI passes."
}

# Commits what changed in a clone_main clone onto <branch>, pushes it and opens a pull request
# that merges once CI passes, or leaves the open one, now updated.
# $1 = clone, $2 = branch, $3 = title, $4 = description
send_as_pull_request() {
    local clone="$1" branch="$2" title="$3" description="$4"
    git -C "$clone" checkout --quiet -B "$branch"
    git -C "$clone" add -A
    if git -C "$clone" diff --cached --quiet; then
        log "main already has these changes: nothing to send."
        return 0
    fi
    git -C "$clone" -c user.name="homelab NAS" -c user.email="nas@homelab.invalid" commit --quiet -m "$title"

    # Don't rewrite the pull request's branch when it already holds exactly these files.
    if git -C "$clone" fetch --quiet --depth 1 origin "$branch" 2>/dev/null \
        && [ "$(git -C "$clone" rev-parse 'FETCH_HEAD^{tree}')" = "$(git -C "$clone" rev-parse 'HEAD^{tree}')" ]; then
        log "Branch $branch already holds these changes."
    else
        git -C "$clone" push --quiet --force origin "$branch"
    fi
    open_or_update_pull_request "$branch" "$title" "$description"
}
