# BluebirdService

A Swift service that periodically syncs Spotify listening history to a database.

## Overview

BluebirdService runs as a scheduled job to:
- Fetch user Spotify refresh tokens from the database
- Generate new access tokens for each user
- Retrieve recently played tracks from Spotify API
- Insert new tracks and listening history into the database
- Update last sync timestamps

Designed to run **once per hour** via a cron job.

## Requirements

- Swift 6.1+
- macOS 10.15+

## Environment Variables

Create a `.env` file with:

```bash
SUPABASE_URL=your_supabase_url
SUPABASE_SERVICE_ROLE=your_service_role_key
SPOTIFY_CLIENT_ID=your_spotify_client_id
SPOTIFY_CLIENT_SECRET=your_spotify_client_secret
```

## Usage

```bash
# Build and run
./scripts/run.sh your_api_key
```


