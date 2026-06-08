#!/bin/bash
# DocCon Slack Messaging Script
# Supports bot tokens for @mentions and channel-specific posting
#
# Usage:
#   ./slack-message.sh --channel "#aultech-prj" "Hello team!"
#   ./slack-message.sh --channel "#aultech-prj" --mention "U0A6QAERSAH" "Hey, check this out"
#   ./slack-message.sh --channel "#aultech-prj" --type deploy "Deployment complete"
#
# Configuration:
#   Set SLACK_BOT_TOKEN in environment, .env.local, or ~/.doccon-slack
#   Bot needs: chat:write, chat:write.public scopes
#
# For user IDs, see .slack-users.json in project root

set -e

SCRIPT_DIR="$(dirname "$0")"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load configuration
load_config() {
    if [ -z "$SLACK_BOT_TOKEN" ]; then
        if [ -f "$PROJECT_ROOT/.env.local" ]; then
            source "$PROJECT_ROOT/.env.local"
        fi
        if [ -z "$SLACK_BOT_TOKEN" ] && [ -f "$HOME/.doccon-slack" ]; then
            source "$HOME/.doccon-slack"
        fi
    fi
}

load_config

# Parse arguments
CHANNEL=""
MENTIONS=()
TYPE="info"
MESSAGE=""
AS_ME=""  # empty = bot send; non-empty = user token context (default/aultech/bcc)

while [[ $# -gt 0 ]]; do
    case $1 in
        --channel|-c)
            CHANNEL="$2"
            shift 2
            ;;
        --mention|-m)
            MENTIONS+=("$2")
            shift 2
            ;;
        --type|-t)
            TYPE="$2"
            shift 2
            ;;
        --as-me|--as-me=*)
            # --as-me                  use SLACK_USER_TOKEN (mw-lab-bot, default for --as-me)
            # --as-me=aultech          use SLACK_USER_TOKEN_AULTECH
            # --as-me=bcc              use SLACK_USER_TOKEN_BCC
            # Sends AS the user (Dario), not as the bot. Drops the bot emoji prefix.
            if [[ "$1" == --as-me=* ]]; then
                AS_ME="${1#--as-me=}"
            else
                AS_ME="default"
            fi
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            echo "DocCon Slack Messaging"
            echo ""
            echo "Usage: $0 --channel \"#channel\" [options] \"message\""
            echo ""
            echo "Options:"
            echo "  --channel, -c       Channel to post to (required). #name, channel ID, or U-prefixed user ID for DM"
            echo "  --mention, -m       User ID to mention (can use multiple times)"
            echo "  --type, -t          Message type: info, deploy, alert, success"
            echo "  --as-me[=context]   Send AS the user (Dario), not the bot. Drops the bot emoji prefix."
            echo "                      context: default (mw-lab-bot, default for --as-me) | aultech | bcc"
            echo "  --dry-run           Show payload without sending"
            echo ""
            echo "Configuration:"
            echo "  Set SLACK_BOT_TOKEN in environment, .env.local, or ~/.doccon-slack"
            echo "  For --as-me: SLACK_USER_TOKEN / SLACK_USER_TOKEN_AULTECH / SLACK_USER_TOKEN_BCC"
            echo ""
            echo "User IDs are in .slack-users.json"
            echo ""
            echo "Examples:"
            echo "  $0 -c '#aultech-prj' 'Hello team!'                          # bot send"
            echo "  $0 -c '#aultech-prj' -m U0A6QAERSAH 'Hey, check this'       # bot send with mention"
            echo "  $0 --as-me -c U2B16UPUL 'hey nithia..'                      # personal DM as Dario"
            echo "  $0 --as-me=aultech -c '#aultech-prj' 'morning team'         # channel msg as Dario, aultech-context token"
            exit 0
            ;;
        *)
            MESSAGE="$*"
            break
            ;;
    esac
done

# Validate
if [ -z "$CHANNEL" ]; then
    echo "Error: --channel is required"
    echo "Usage: $0 --channel \"#channel\" \"message\""
    exit 1
fi

if [ -z "$MESSAGE" ]; then
    echo "Error: Message is required"
    exit 1
fi

# Set emoji based on type (bot sends only — --as-me skips this)
case $TYPE in
    deploy)  EMOJI=":rocket:" ;;
    alert|error) EMOJI=":warning:" ;;
    success) EMOJI=":white_check_mark:" ;;
    *)       EMOJI=":information_source:" ;;
esac

# Build mention prefix
MENTION_PREFIX=""
for user_id in "${MENTIONS[@]}"; do
    MENTION_PREFIX+="<@$user_id> "
done

# Resolve which token + sender identity to use
TOKEN=""
TOKEN_DESC=""
if [ -n "$AS_ME" ]; then
    case "$AS_ME" in
        default|"") TOKEN="$SLACK_USER_TOKEN";          TOKEN_DESC="SLACK_USER_TOKEN (mw-lab-bot)" ;;
        aultech)    TOKEN="$SLACK_USER_TOKEN_AULTECH";  TOKEN_DESC="SLACK_USER_TOKEN_AULTECH" ;;
        bcc)        TOKEN="$SLACK_USER_TOKEN_BCC";      TOKEN_DESC="SLACK_USER_TOKEN_BCC" ;;
        *) echo "Error: --as-me=$AS_ME unknown (default|aultech|bcc)" >&2; exit 1 ;;
    esac
    if [ -z "$TOKEN" ]; then
        echo "Error: user token for --as-me=$AS_ME not set in environment" >&2
        echo "Expected: $TOKEN_DESC" >&2
        exit 1
    fi
    # --as-me sends as the user; no bot emoji prefix, mentions still allowed
    FULL_MESSAGE="${MENTION_PREFIX}${MESSAGE}"
else
    TOKEN="$SLACK_BOT_TOKEN"
    TOKEN_DESC="SLACK_BOT_TOKEN (aultech_bot)"
    FULL_MESSAGE="$EMOJI ${MENTION_PREFIX}${MESSAGE}"
fi

# Build payload
PAYLOAD=$(jq -n \
    --arg channel "$CHANNEL" \
    --arg text "$FULL_MESSAGE" \
    '{
        channel: $channel,
        text: $text,
        unfurl_links: false,
        unfurl_media: false
    }')

if [ "$DRY_RUN" = "1" ]; then
    echo "=== DRY RUN ==="
    echo "Token:   $TOKEN_DESC"
    echo "Channel: $CHANNEL"
    echo "Message: $FULL_MESSAGE"
    echo ""
    echo "Payload:"
    echo "$PAYLOAD" | jq .
    exit 0
fi

# Validate token for actual send
if [ -z "$TOKEN" ]; then
    if [ -n "$AS_ME" ]; then
        echo "Error: user token for --as-me=$AS_ME not set ($TOKEN_DESC)" >&2
        echo "Set it in ~/.doccon-slack" >&2
    else
        echo "Error: SLACK_BOT_TOKEN not set" >&2
        echo ""
        echo "To set up:"
        echo "1. Go to https://api.slack.com/apps"
        echo "2. Create app or select existing DocCon app"
        echo "3. OAuth & Permissions -> Add scopes: chat:write, chat:write.public"
        echo "4. Install to workspace"
        echo "5. Copy Bot User OAuth Token"
        echo "6. Add to ~/.doccon-slack:"
        echo "   SLACK_BOT_TOKEN='xoxb-...'"
    fi
    exit 1
fi

# Send via Slack API
RESPONSE=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-type: application/json" \
    --data "$PAYLOAD")

# Check response
if echo "$RESPONSE" | jq -e '.ok == true' > /dev/null 2>&1; then
    TIMESTAMP=$(echo "$RESPONSE" | jq -r '.ts')
    echo "Message sent to $CHANNEL (ts: $TIMESTAMP)"
else
    ERROR=$(echo "$RESPONSE" | jq -r '.error // "Unknown error"')
    echo "Failed to send message: $ERROR"
    echo "Full response: $RESPONSE"
    exit 1
fi
