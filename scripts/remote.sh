#!/bin/bash
# Usage: ./remote.sh db "SELECT count(*) FROM traces"

# Load N8N_API_KEY from .env
if [ -f .env ]; then
  API_KEY=$(grep N8N_API_KEY .env | cut -d '=' -f2)
else
  echo ".env file not found"
  exit 1
fi

case $1 in
  db) ssh DigitalOcean "source ~/kairon/.env && docker exec postgres-db psql -U \$DB_USER -d \$DB_NAME -c '$2'" ;;
  api) ssh DigitalOcean "curl -s -H 'X-N8N-API-KEY: $API_KEY' 'http://localhost:5678/api/v1/$2'" ;;
esac
