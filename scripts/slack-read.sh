#!/bin/bash
# DocCon Slack Reading Script
# Fetches recent messages from a channel or DM conversation.
#
# Usage:
#   ./slack-read.sh --channel "#aultech-prj"             # last 20 messages
#   ./slack-read.sh --channel "#doccon-dev" --limit 50   # last 50
#   ./slack-read.sh --channel C0A6QPGRTV                 # by channel ID
#   ./slack-read.sh --user U2B16UPUL                     # DM with this user (needs im:history)
#   ./slack-read.sh --user nithia                        # DM with a known user (resolves via .slack-users.json)
#   ./slack-read.sh --since 30m --channel "#aultech-prj" # since 30 min ago
#   ./slack-read.sh --raw --channel "#aultech-prj"       # raw JSON
#
# Scopes required:
#   channels:history + channels:read   for public channels
#   im:history + im:read               for DMs (NOT currently granted)
#   users:read                         for resolving names
#
# Configuration:
#   SLACK_BOT_TOKEN from environment, .env.local, or ~/.doccon-slack
set -e

SCRIPT_DIR="$(dirname "$0")"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USERS_FILE="$PROJECT_ROOT/.slack-users.json"

# Load token file (bot + user tokens both come from here)
if [ -z "$SLACK_BOT_TOKEN" ]; then
    if [ -f "$PROJECT_ROOT/.env.local" ]; then source "$PROJECT_ROOT/.env.local"; fi
    if [ -z "$SLACK_BOT_TOKEN" ] && [ -f "$HOME/.doccon-slack" ]; then source "$HOME/.doccon-slack"; fi
fi
# Note: SLACK_BOT_TOKEN may be unset if user is going to use --as-me; that's checked below.

CHANNEL=""
USER_TARGET=""
LIMIT=20
SINCE=""
RAW=0
AS_ME=""  # empty=use bot token; non-empty=user token context (default/aultech/bcc)

while [[ $# -gt 0 ]]; do
    case $1 in
        --channel|-c) CHANNEL="$2"; shift 2 ;;
        --user|-u)    USER_TARGET="$2"; shift 2 ;;
        --limit|-l)   LIMIT="$2"; shift 2 ;;
        --since|-s)   SINCE="$2"; shift 2 ;;
        --raw)        RAW=1; shift ;;
        --as-me|--as-me=*)
            # --as-me              use SLACK_USER_TOKEN (mw-lab-bot, default for --as-me)
            # --as-me=aultech      use SLACK_USER_TOKEN_AULTECH
            # --as-me=bcc          use SLACK_USER_TOKEN_BCC
            # Reading as the user gives access to ALL the user's DMs and any channels
            # they're in, bypassing the bot's narrower scope set.
            if [[ "$1" == --as-me=* ]]; then
                AS_ME="${1#--as-me=}"
            else
                AS_ME="default"
            fi
            shift
            ;;
        --help|-h)    sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Resolve which token to use
if [ -n "$AS_ME" ]; then
    case "$AS_ME" in
        default|"") TOKEN="$SLACK_USER_TOKEN";          TOKEN_DESC="SLACK_USER_TOKEN (mw-lab-bot)" ;;
        aultech)    TOKEN="$SLACK_USER_TOKEN_AULTECH";  TOKEN_DESC="SLACK_USER_TOKEN_AULTECH" ;;
        bcc)        TOKEN="$SLACK_USER_TOKEN_BCC";      TOKEN_DESC="SLACK_USER_TOKEN_BCC" ;;
        *) echo "Error: --as-me=$AS_ME unknown (default|aultech|bcc)" >&2; exit 1 ;;
    esac
    if [ -z "$TOKEN" ]; then
        echo "Error: user token for --as-me=$AS_ME not set in environment ($TOKEN_DESC)" >&2
        exit 1
    fi
else
    TOKEN="$SLACK_BOT_TOKEN"
fi
[ -z "$TOKEN" ] && { echo "Error: no token resolved (SLACK_BOT_TOKEN unset and --as-me not used)" >&2; exit 1; }

# When --as-me, capture our own Slack user ID so we can render our own messages as "you"
ME_USER_ID=""
if [ -n "$AS_ME" ]; then
    ME_USER_ID=$(curl -s "https://slack.com/api/auth.test" -H "Authorization: Bearer $TOKEN" | jq -r '.user_id // ""')
fi

if [ -z "$CHANNEL" ] && [ -z "$USER_TARGET" ]; then
    echo "Error: provide --channel or --user" >&2; exit 1
fi

# Resolve user → DM channel ID via conversations.open
if [ -n "$USER_TARGET" ]; then
    # If not a U-prefixed Slack ID, try to resolve via .slack-users.json (case-insensitive)
    if ! [[ "$USER_TARGET" =~ ^U[A-Z0-9]+$ ]] && [ -f "$USERS_FILE" ]; then
        RESOLVED=$(jq -r --arg q "$USER_TARGET" '
            .users | to_entries[] |
            select((.key | ascii_downcase) == ($q | ascii_downcase)
                or ((.value.alias // "") | ascii_downcase) == ($q | ascii_downcase)
                or (.value.slack_id // "") == $q) |
            .value.slack_id' "$USERS_FILE" | head -1)
        if [ -n "$RESOLVED" ]; then USER_TARGET="$RESOLVED"; fi
    fi
    # Open (or get) the DM channel ID with that user
    OPEN=$(curl -s -X POST "https://slack.com/api/conversations.open" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-type: application/json" \
        --data "{\"users\":\"$USER_TARGET\"}")
    if [ "$(echo "$OPEN" | jq -r .ok)" != "true" ]; then
        echo "Error opening DM channel: $(echo "$OPEN" | jq -r .error)" >&2
        echo "(if 'missing_scope': bot needs im:write to open the DM and im:history to read it)" >&2
        exit 2
    fi
    CHANNEL=$(echo "$OPEN" | jq -r '.channel.id')
fi

# Compute --oldest from --since (e.g. 30m, 2h, 1d)
OLDEST=""
if [ -n "$SINCE" ]; then
    NUM=$(echo "$SINCE" | sed 's/[^0-9]//g')
    UNIT=$(echo "$SINCE" | sed 's/[0-9]//g')
    case "$UNIT" in
        m|min) SECS=$((NUM*60)) ;;
        h|hr|hour) SECS=$((NUM*3600)) ;;
        d|day) SECS=$((NUM*86400)) ;;
        *) echo "Error: bad --since '$SINCE' (use e.g. 30m, 2h, 1d)" >&2; exit 1 ;;
    esac
    OLDEST=$(($(date +%s) - SECS))
fi

# Fetch messages
URL="https://slack.com/api/conversations.history?channel=${CHANNEL}&limit=${LIMIT}"
[ -n "$OLDEST" ] && URL="${URL}&oldest=${OLDEST}"

RESPONSE=$(curl -s -X GET "$URL" -H "Authorization: Bearer $TOKEN")
OK=$(echo "$RESPONSE" | jq -r .ok)

if [ "$OK" != "true" ]; then
    ERR=$(echo "$RESPONSE" | jq -r .error)
    echo "Slack API error: $ERR" >&2
    if [ "$ERR" = "missing_scope" ]; then
        NEEDED=$(echo "$RESPONSE" | jq -r '.needed // ""')
        echo "Needed scope: $NEEDED" >&2
        echo "Add it at https://api.slack.com/apps -> aultech_bot -> OAuth & Permissions, then reinstall." >&2
    fi
    exit 3
fi

if [ "$RAW" = "1" ]; then
    echo "$RESPONSE" | jq .
    exit 0
fi

# Pretty-print: reverse to chronological, resolve user IDs lazily
USERS_CACHE_FILE=$(mktemp)
echo '{}' > "$USERS_CACHE_FILE"

resolve_user() {
    local uid="$1"
    [ -z "$uid" ] || [ "$uid" = "null" ] && { echo "(unknown)"; return; }
    # When reading --as-me, the user's own messages have their own ID — render as "you"
    if [ -n "$AS_ME" ] && [ -n "$ME_USER_ID" ] && [ "$uid" = "$ME_USER_ID" ]; then
        echo "you"; return
    fi
    local cached=$(jq -r --arg k "$uid" '.[$k] // ""' "$USERS_CACHE_FILE")
    if [ -n "$cached" ]; then echo "$cached"; return; fi
    # First try local registry
    if [ -f "$USERS_FILE" ]; then
        local local_name=$(jq -r --arg id "$uid" '
            .users | to_entries[] |
            select(.value.slack_id == $id) | .key' "$USERS_FILE" | head -1)
        if [ -n "$local_name" ]; then
            jq --arg k "$uid" --arg v "$local_name" '. + {($k): $v}' "$USERS_CACHE_FILE" > "${USERS_CACHE_FILE}.tmp" && mv "${USERS_CACHE_FILE}.tmp" "$USERS_CACHE_FILE"
            echo "$local_name"; return
        fi
    fi
    # Fall back to Slack API
    local info=$(curl -s "https://slack.com/api/users.info?user=$uid" -H "Authorization: Bearer $TOKEN")
    local name=$(echo "$info" | jq -r '.user.profile.display_name // .user.real_name // "(unresolved)"')
    [ "$name" = "" ] && name="(unresolved)"
    jq --arg k "$uid" --arg v "$name" '. + {($k): $v}' "$USERS_CACHE_FILE" > "${USERS_CACHE_FILE}.tmp" && mv "${USERS_CACHE_FILE}.tmp" "$USERS_CACHE_FILE"
    echo "$name"
}

echo "$RESPONSE" | jq -r '.messages | reverse | .[] | "\(.ts)|\(.user // .bot_id // "?")|\(.text // "" | gsub("\n"; " · "))"' | while IFS='|' read -r ts uid text; do
    when=$(date -r "${ts%.*}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
    who=$(resolve_user "$uid")
    printf '[%s] %-18s %s\n' "$when" "$who" "$text"
done

rm -f "$USERS_CACHE_FILE"
