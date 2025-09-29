#!/bin/bash
echo "Loading .env"
export $(cat .env | xargs)

COMMAND=${1:-tracks}
APIKEY=${2:-$SUPABASE_SERVICE_ROLE_KEY}

echo "Running command: $COMMAND"
swift run BluebirdService "$COMMAND" --apikey "$APIKEY"
